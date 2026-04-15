# Proposal 055 — Treasury-Driven Resolution

**Scope:** userland (implementation of Proposal 054's design)

**Depends on:** Proposal 054 (interest-bearing positions — the game)

## What 054 decided

The treasury is the bank. The broker borrows. The deadline is the
clock. Phase transitions are the triggers. The exit is three
booleans AND'd. The treasury is headless — blind to strategy,
judges outcomes. Favor is earned through paper. Unanimous after
two rounds.

This proposal implements it.

## The paper struct

Issued by the treasury. Held by both treasury and broker.
The treasury's copy is the source of truth.

```rust
struct Paper {
    paper_id: u64,
    owner: BrokerSlot,                // (market_idx, position_idx)
    from_asset: Asset,                // what was borrowed (e.g. USDC)
    to_asset: Asset,                  // what was acquired (e.g. WBTC)
    amount: f64,                      // units of from_asset borrowed
    units_acquired: f64,              // units of to_asset after entry fee
    entry_price: f64,                 // exchange rate at entry
    entry_candle: usize,
    deadline: usize,                  // entry_candle + N
    resolved: bool,
    outcome: Option<Outcome>,         // Grace or Violence
}
```

The `deadline` is computed at entry: `entry_candle + deadline_candles`.
The `deadline_candles` comes from the treasury's configuration,
derived from ATR at entry time. Volatile market → shorter deadline
(things move fast, prove it fast). Calm market → longer deadline.

The `units_acquired`: the broker borrowed `amount` of `from_asset`,
paid the 0.35% entry fee, and acquired this many units of `to_asset`.
For a $50 USDC → WBTC swap at $90,000/BTC with 0.35% fee:
`units_acquired = (50.0 * (1.0 - 0.0035)) / 90000.0 = 0.000554`

## The treasury's ledger

```rust
struct Treasury {
    // Asset balances
    balances: HashMap<Asset, f64>,

    // All papers — the source of truth
    papers: HashMap<u64, Paper>,
    next_paper_id: u64,

    // Papers indexed by owner for fast lookup
    papers_by_owner: HashMap<BrokerSlot, Vec<u64>>,

    // Proposer records — the gate
    proposer_records: HashMap<BrokerSlot, ProposerRecord>,

    // Configuration
    entry_fee: f64,                   // 0.0035 (0.35%)
    exit_fee: f64,                    // 0.0035 (0.35%)
    deadline_candles: usize,          // base deadline, ATR-adjusted
}

struct ProposerRecord {
    papers_submitted: usize,
    papers_survived: usize,          // Grace count
    papers_failed: usize,            // Violence count
    total_grace_residue: f64,        // sum of all Grace residues
    // Derived at query time:
    // survival_rate = survived / submitted
    // mean_residue = total_grace_residue / survived
}
```

The `ProposerRecord` is the struct from Proposal 054's "Earning
favor." The treasury applies a predicate: `survival_rate > threshold
AND papers_submitted > minimum`. Same for everyone.

## The treasury's jobs — per candle

The treasury drives resolution. Not the broker. Every candle:

### 1. Deadline check (Violence)

Every paper. Every real position. Every candle.

```rust
for paper in all_active_papers() {
    if current_candle >= paper.deadline {
        // Reclaim. The deadline expired.
        resolve_violence(paper);
        notify_broker(paper.owner, Violence, paper.paper_id);
    }
}
```

The asset stays in the treasury. The broker's claim is revoked.
The proposer record is updated: `papers_failed += 1`.

### 2. Grace exit (broker proposes, treasury validates)

The broker makes the exit decision. Not the treasury. The treasury
is headless — it does not know what a valley is, what the market
observer thinks, or what the position observer recommends. The
treasury knows arithmetic.

The broker runs the four gates:
1. Phase trigger (valley/peak) — the broker sees the phase
2. Market direction — the broker reads its market observer
3. Residue math — the broker estimates from its copy of the paper
4. Position observer — the broker consults its exit advisor

If all four gates say exit, the broker PROPOSES the exit:

```rust
// Broker → Treasury
struct ExitProposal {
    paper_id: u64,
    current_price: f64,  // the broker's observed price
}
```

The treasury validates. It checks ITS OWN copy of the paper:

```rust
fn validate_exit(&self, proposal: &ExitProposal) -> Option<f64> {
    let paper = self.papers.get(&proposal.paper_id)?;
    if paper.resolved { return None; }

    let current_value = paper.units_acquired * proposal.current_price;
    let exit_fee = current_value * self.exit_fee;
    let residue = current_value - paper.amount - exit_fee;

    if residue > 0.0 {
        Some(residue)
    } else {
        None  // deny — the math doesn't work
    }
}
```

The treasury does not know WHY the broker wants to exit. The
treasury checks: is there positive residue after recovering
principal and paying the exit fee? Yes → approve. No → deny.

The broker could propose exits for any reason — phase, sentiment,
wind speed, a coin flip. The treasury doesn't care. The treasury
validates the arithmetic. The record tracks the outcome.

If approved:
- Treasury recovers `paper.amount` of from_asset (the principal)
- Treasury deducts exit fee
- Residue is split: half to the proposer, half to the treasury
  - Proposer's half: credited to the proposer's deposit in to_asset.
    This is the honest reward. The proposer earned it through
    good thoughts.
  - Treasury's half: stays in the pool's to_asset balance. The
    pool grows. All depositors benefit proportionally.
- Broker's proposer record updated: `papers_survived += 1`,
  `total_grace_residue += residue`
- Treasury notifies broker: Grace, paper_id, residue amount

The incentive aligns. The proposer wants Grace because they
earn half the residue. The treasury wants Grace because it keeps
half. The passive depositors want Grace because the pool grows.
Everyone benefits from the same outcome. Nobody benefits from
Violence.

The proposer with $100 and the proposer with $10,000,000 play
the same game. Same deadlines (adjusted by record, not deposit).
Same four gates. The game rewards the THOUGHT, not the capital.
A small proposer with good thoughts earns the same percentage
as a whale with good thoughts. The edge is in the thinking.

If denied:
- The paper lives. The deadline ticks. The broker holds.

### 3. Issue new papers

The broker proposes an entry. The treasury evaluates:
- Does the broker have a record? (proposer record exists)
- Does the record pass the predicate? (for real capital)
- For papers: always issue. Papers are how you build the record.
- For real: check the predicate. Deny if unproven.

```rust
fn issue_paper(&mut self, owner: BrokerSlot, from: Asset,
               to: Asset, amount: f64, price: f64,
               candle: usize, is_real: bool) -> Option<u64> {
    if is_real {
        let record = self.proposer_records.get(&owner)?;
        if !self.gate_predicate(record) { return None; }
        // Check balance
        if self.balances[&from] < amount { return None; }
    }

    let fee = amount * self.entry_fee;
    let net_amount = amount - fee;
    let units = net_amount / price;

    let id = self.next_paper_id;
    self.next_paper_id += 1;

    let paper = Paper {
        paper_id: id,
        owner,
        from_asset: from,
        to_asset: to,
        amount,
        units_acquired: units,
        entry_price: price,
        entry_candle: candle,
        deadline: candle + self.deadline_candles,
        side: if from == Asset::USDC { Side::Buy } else { Side::Sell },
        resolved: false,
        outcome: None,
    };

    self.papers.insert(id, paper);
    self.papers_by_owner.entry(owner).or_default().push(id);
    self.proposer_records.entry(owner).or_default()
        .papers_submitted += 1;

    // Move balance for real positions
    if is_real {
        *self.balances.get_mut(&from).unwrap() -= amount;
    }

    Some(id)
}
```

### 4. Notify brokers

The treasury pushes outcomes down. The broker receives:

```rust
enum TreasuryVerdict {
    Grace { paper_id: u64, residue: f64 },
    Violence { paper_id: u64 },
}
```

The broker receives the verdict through its pipe. The broker:
- Updates its own copy of the paper
- Propagates learn signals to its market and position observers
- Grace → the observers learn "this entry was good"
- Violence → the observers learn "this entry was bad"

The broker doesn't decide. The broker is told.

## The broker's new role

The broker thinks. The treasury judges.

The broker's per-candle work:
1. Receive verdicts from treasury (drain verdict pipe)
2. Propagate learns to observers
3. Encode the market (via market observer chain)
4. Compose anxiety atoms for active papers
5. At trigger candles: propose Grace exits to treasury
6. During active phase: propose new entries to treasury

The broker NO LONGER:
- Ticks papers against price
- Computes distances
- Decides resolution outcomes
- Owns the paper lifecycle

The broker's anxiety atoms (per active paper):

```scheme
(Log "candles-remaining" (- deadline current-candle))
(Linear "time-pressure" (/ candles-elapsed (- deadline entry-candle)) 1.0)
(Linear "unrealized-residue" (/ (- current-value amount) amount) 1.0)
(Log "paper-age" candles-elapsed)
```

These bundle with the market thoughts. The position observer
sees them and predicts: exit or hold at this trigger.

## The position observer's new job

Two position observers remain (Core, Full). Both become discrete.

Was: continuous reckoner predicting trail and stop distances.
Now: discrete reckoner predicting Exit or Hold.

The position observer receives:
- The market chain (market observer's prediction and anomaly)
- The anxiety atoms (from the broker, per active paper)
- The phase state (valley, peak, transition)

The position observer predicts: at this trigger, with this
anxiety, with this market state — Exit or Hold?

Labels:
- Exit: the broker proposed Grace at this trigger and the
  treasury confirmed it. The exit was right.
- Hold: the broker held through this trigger and the paper
  later resolved Grace. Holding was right.
- (Violence papers teach both: "you should have exited earlier"
  for the triggers you held through before the deadline hit.)

The lenses still matter. Core sees regime + time. Full sees
regime + time + phase. Different lenses may produce different
exit/hold opinions at the same trigger. The broker that pairs
a specific market observer with a specific position observer
gets a specific exit strategy. The N×M grid still produces
diverse behaviors.

## The flow — per candle

```
1. Treasury: deadline check → resolve Violence → notify brokers
2. Brokers: receive verdicts (Violence notifications from step 1)
3. Brokers: evaluate active papers (four gates: phase, market,
   math, position observer). Propose exits to treasury.
4. Treasury: validate exit proposals → resolve Grace → notify
5. Brokers: receive Grace verdicts
6. Brokers: during active phase, propose new entries to treasury
7. Treasury: issue papers (real if record passes, paper always)
8. Brokers: propagate all verdicts to observers (learn signals)
```

Step 1 runs every candle — the treasury checks deadlines. This
is the ONLY thing the treasury does autonomously. Everything
else is in response to broker proposals.

Steps 3-4 are broker-driven. The broker decides when to propose
exits. The treasury validates arithmetic. The broker could
propose exits every candle or never. The treasury doesn't care
when — it validates when asked.

Step 6-7: the broker proposes entries. The treasury issues. The
treasury checks the proposer record for real capital. Papers
are always issued (that's how you build the record).

The treasury is reactive except for step 1 (deadline enforcement).
The broker is active — it thinks, evaluates, proposes. The
treasury validates, records, notifies.

## The pipe changes

```
Before:
  candle → market obs → position obs → broker → (broker ticks papers)

After:
  candle → market obs → position obs → broker → treasury
                                                    ↓
                                              broker (verdicts)
                                                    ↓
                                              observer learns
```

New pipes:
- Broker → Treasury: entry proposals, exit proposals
- Treasury → Broker: verdicts (Grace/Violence per paper)

The treasury becomes a program on the wat-vm. Its own thread.
Its own pipes. The brokers send proposals. The treasury sends
verdicts. The treasury has a pipe from the phase labeler (or
reads it from the candle) to know when triggers occur.

## The deadline calculation

ATR-proportional. At entry time:

```rust
deadline_candles = base_deadline * (median_atr / current_atr)
```

High ATR (volatile) → shorter deadline. The market moves fast.
Prove it fast. Low ATR (calm) → longer deadline. The market
moves slow. More patience.

`base_deadline` is the treasury's ONE parameter. The ATR
adjusts it to the regime. The proposer doesn't choose their
deadline. The market does.

## Settled

1. **Base deadline.** Configurable. Starts at a reasonable value
   (to be discovered through simulation). Proven winners earn
   longer deadlines — the favor. The number will change as
   winners self-elect and earn more confidence. The deadline is
   not a magic number. It is the treasury's expression of trust.

2. **Paper vs real.** Identical treatment from the treasury.
   Same deadlines. Same exit conditions. Same resolution logic.
   Papers use a reference amount for percentage calculation
   ($10,000 or $100 — the amount doesn't matter, only the
   percentages). Reals use real capital. The treasury doesn't
   distinguish in its logic — only in whether balances move.

3. **Multiple exits per candle.** If the exit conditions are met,
   you exit. All of them. For optimization: flatten into a single
   swap to avoid compounding fees. But if the conditions are met,
   you get out. No ranking. No selectivity. The math decides.

## Settled — the fourth gate

4. **The position observer at triggers — the fourth gate.**

   Four gates, evaluated in order:

   1. **Phase trigger** (valley/peak) — are we at an evaluation point?
   2. **Market direction** — does the market predict against my position?
   3. **Residue math** — can I exit profitably after fees?
   4. **Position observer** — should I? Experience says Exit or Hold.

   Gates 1-3 are arithmetic. They determine whether exit is
   POSSIBLE. Gate 4 is learned. It determines whether exit is
   WISE. Gate 4 can override gate 2 — the market observer says
   Down, but the position observer says "I've seen this shape
   before — hold, this is a dip, not the end."

   Experience trumps simple conditions. The market observer sees
   now. The position observer remembers.

5. **Two labels: Exit and Hold.**

   The position observer's discrete reckoner. Two labels. Learned
   from outcomes. Applied at exit time to decide whether to
   actually get out or not.

   The labels arrive when the paper resolves — retroactively
   applied to EVERY trigger the paper passed through:

   - Paper exited Grace at trigger T → trigger T labeled **Exit**
     (the exit was right)
   - Paper held through trigger T, later exited Grace at trigger
     T+3 → trigger T labeled **Hold** (holding was right)
   - Paper held through trigger T, hit deadline → trigger T
     labeled **Exit** (you should have left — holding was wrong)

   The position observer learns from the full history of
   decisions. Every trigger a paper passed through is a training
   example. The label says: at THIS trigger, with THIS anxiety,
   with THIS market state — was exiting or holding the right
   call? The answer comes later. The reckoner accumulates.

   The position observer's thought at each trigger:

   ```scheme
   (Bundle
     ;; Anxiety atoms — the position's state
     (Log "candles-remaining" 234)
     (Linear "time-pressure" 0.35 1.0)
     (Linear "unrealized-residue" 0.024 1.0)
     (Log "paper-age" 147)

     ;; Market atoms — what the market observer says
     ;; (extracted from the chain, same as before)

     ;; Phase atoms — what the structure looks like
     ;; (from the phase labeler)
   )
   ```

   The reckoner sees anxiety + market + structure. It predicts
   Exit or Hold. The prediction is the fourth gate. If the first
   three gates say "you can exit" and the fourth says Hold —
   you hold. The position observer's experience overrides the
   arithmetic. The arithmetic says possible. The experience says
   not yet.
