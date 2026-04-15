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
    side: Side,                       // Buy or Sell
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

### 2. Grace evaluation (at trigger candles only)

A trigger is a valley or peak from the phase labeler. At each
trigger, the treasury evaluates all active papers whose exit
conditions may be met.

For a long paper at a valley (the lows are being tested):

```rust
fn evaluate_grace_long(paper: &Paper, current_price: f64,
                        market_prediction: Direction) -> Option<f64> {
    // Condition 1: phase is valley — checked by caller
    // Condition 2: market predicts Down (against the long)
    if market_prediction != Direction::Down { return None; }

    // Condition 3: residue after exit fee is positive
    let current_value = paper.units_acquired * current_price;
    let exit_fee = current_value * self.exit_fee;
    let residue = current_value - paper.amount - exit_fee;

    if residue > 0.0 {
        Some(residue)
    } else {
        None
    }
}
```

If Grace → the treasury:
- Recovers `paper.amount` of from_asset (the principal)
- Deducts exit fee
- The residue stays in to_asset, credited to the broker
- Notifies the broker: Grace, paper_id, residue amount
- Updates proposer record: `papers_survived += 1`,
  `total_grace_residue += residue`

If not Grace → hold. The paper lives. The deadline ticks.

For shorts: same logic at peaks, market predicts Up.

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
2. Treasury: is this candle a trigger? (phase labeler)
3. If trigger:
   a. Brokers evaluate active papers (compose anxiety + market)
   b. Position observer predicts Exit/Hold per paper
   c. Brokers propose Grace exits to treasury
   d. Treasury validates: does the math work? → resolve Grace → notify
4. During active phase:
   a. Brokers propose new entries to treasury
   b. Treasury issues papers (real if record passes, paper always)
5. Brokers propagate verdicts to observers (learn signals)
```

Step 1 runs every candle. Steps 2-4 are conditional. Step 5
runs whenever verdicts arrive.

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

## Open — for debate

4. **The position observer at triggers.** The position observer
   measures active papers during peaks and valleys. The anxiety
   atoms (candles-remaining, time-pressure, unrealized-residue)
   factor in. But is the position observer PREDICTING Exit/Hold?
   Or is it just reporting facts that the three-condition check
   consumes? The three-condition check is arithmetic. Does the
   position observer add signal beyond the arithmetic? Or is
   the arithmetic sufficient?

5. **Propagation labels.** What does the position observer learn
   from? Grace verdicts → "exit was right at this trigger."
   Violence verdicts → "you should have exited earlier." How
   does "hold was right" get labeled? The paper that held through
   a trigger and later exited Grace — that hold was correct.
   The paper that held through and later hit the deadline — that
   hold was wrong. The label arrives later, not at the trigger.
   Should there be a third label (Hold) alongside Exit and
   Violence? The builder carried three labels (Buy, Sell, Hold)
   in an earlier neural network attempt three years ago. Parked
   for now — needs thinking.
