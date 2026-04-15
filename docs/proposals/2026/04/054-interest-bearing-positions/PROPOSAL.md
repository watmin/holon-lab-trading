# Proposal 054 — Interest-Bearing Positions

**Scope:** userland

**Depends on:** Proposal 044 (pivot biography), 049 (phase labeler),
053 (reckoner drift findings — distances are the wrong exit mechanism)

## The finding

Proposal 053 set out to fix reckoner drift. The ablation ran. The
noise subspace wasn't the cause. The raw values revealed the reckoner's
predictions inflate (0.37% → 4.24% trail distance while optimal stays
flat at 0.3-0.7%). The deeper finding: papers stack — 8,000 active per
broker at the end, zero resolving for hundreds of candles. The position
observer stops learning at candle 3000. The distances are self-reinforcing:
wrong distances prevent resolution, preventing learning, preventing
correction.

Distance-based exits are the wrong mechanism. The papers should resolve
from behavioral observation — the structure breaking — not from a price
reaching a computed distance.

## The game

The treasury is the bank. The broker is the player. The interest is the
ante. The residue is the loot.

### Entry

The phase labeler identifies structure. Three consecutive higher lows
= the market is building upward — buy condition active. Three
consecutive lower highs = the market is building downward — sell
condition active. The condition persists for the duration of the
streak. Average window: 53 candles (4.4 hours). The market is in
an active condition 44% of the time.

During the buy condition: the broker enters longs. During the sell
condition: the broker enters shorts. The frequency of entry is the
broker's choice — gated by its own anxiety about the cost of holding.

Each entry: the broker borrows from the treasury. USDC to buy WBTC
(long). Or WBTC to sell for USDC (short). The swap costs 0.35%.
The interest clock starts. The broker now has a claim on a position
inside the treasury's portfolio.

### Hold

Every candle the position is open, the treasury charges interest. The
interest is a per-candle, per-dollar rate. The cost accrues. The
position either grows (the market moves in the predicted direction)
or bleeds (the interest accumulates against a flat or adverse position).

The interest IS the anxiety. The interest IS the stop loss. Not a
price level — a time cost. Hold too long without profit and the
interest eats you.

No distance triggers. No reckoner predicting optimal trail or stop
distances. No simulation sweeping 20 candidates. The entry is a bet.
The hold costs money. The market decides.

### The trigger points

The phase labeler produces three states on every candle:

- **Valley** — the low point. The lows are being tested.
- **Peak** — the high point. The highs are being tested.
- **Transition** — the candles between peak and valley. Nothing
  to evaluate. Hold. Interest ticks.

Peaks and valleys are where the machine evaluates. Transitions
are where the machine waits. The trigger is arriving AT a peak
or valley — not the movement between them.

### Exit (Grace)

Three conditions AND'd together. All three must be true.

**Long exit:**
1. Phase is valley (the lows are being tested)
2. Market observer predicts Down (direction turning against me)
3. Residue after interest + exit fee is positive (the swap works)

**Short exit:**
1. Phase is peak (the highs are being tested)
2. Market observer predicts Up (direction turning against me)
3. Residue after interest + exit fee is positive (the swap works)

All three true → exit. The broker swaps back. The treasury receives
principal + accrued interest. The residue stays in the acquired
asset, held by the treasury, tagged to the broker's claim. Grace.

Any one false → hold:
- Phase is valley but market says Up → the dip is temporary. Hold.
- Phase is valley and market says Down but residue < fees → the
  swap is arithmetically impossible. Hold. Interest ticks.
- Phase is transition → not an evaluation point. Hold.

The exit fee is real. If the residue doesn't cover the 0.35% exit
swap, the exit CANNOT happen. This is not a judgment call. This is
arithmetic. The fee must be accounted for in every action.

### Exit (Violence)

The interest accrues past the position value. The trade drifted or
went adverse. The interest ate the capital. The treasury revokes the
broker's claim. The asset stays in the treasury — it just moved from
one side to the other. The treasury rebalances. The broker lost its
claim, its record takes a Violence mark, its gate tightens.

No stop loss fires. No price trigger. The trade dies from the cost
of conviction that was wrong. Natural economic death.

### The position observer's new job

The position observer doesn't predict distances anymore. It predicts:
**should I exit this position at this trigger?**

The three conditions are the position observer's inputs:

1. The phase — from the phase labeler (already has this)
2. The market observer's prediction — from the chain (already receives)
3. The residue math — from the broker's accounting

The position observer composes these into a thought and makes the
call. Exit or hold. Discrete. Grace or Violence. The same algebra
the market observer uses for direction prediction. The same reckoner
mode (discrete, not continuous).

The position observer is the exit advisor. The broker is the executor.
The market observer is the direction advisor. The phase labeler is the
clock. The treasury is the bank.

Same entities. Same pipes. Same architecture. Different questions.

### The runner

The runner is the trade where the residue grows faster than the
interest. At candle 10: residue 1x interest — nervous. At candle 50:
residue 5x interest — comfortable. At candle 200: residue 30x interest
— the interest is invisible.

The interest selects FOR runners. Trades that move fast and far survive.
Trades that drift die from carrying cost. The interest doesn't stop
runners. The interest kills everything that ISN'T a runner. Natural
selection through economics.

## The anxiety as thought

The broker encodes the cost of holding as named facts:

```scheme
(Log "interest-accrued" 0.0034)        ;; total cost so far
(Linear "residue-vs-interest" 2.3 1.0) ;; how comfortable am I
(Log "candles-since-entry" 47)         ;; how long have I been in
(Linear "unrealized-residue" 0.015 1.0) ;; what I'd keep if I left now
```

These bundle with the market thoughts and the phase structure.
The reckoner sees the full picture: the market AND the position
AND the cost. It learns which shapes of anxiety precede Grace
(get out now, the residue is real) and which precede Violence
(you held too long, the interest is winning).

The reckoner's question changes from "predict a distance"
(continuous, broken) to "should I exit at this transition?"
(discrete, what we're good at). Grace or Violence. Same two
labels. Same algebra.

## What this replaces

- **Distance-based triggers** — trail and stop distances computed from
  simulation. Gone. The phase trigger (peak/valley) + market observer
  prediction + residue arithmetic is the exit signal.
- **Continuous reckoner on position observer** — predicting optimal
  distances. Gone. The position observer becomes a discrete predictor:
  exit or hold at each trigger point. Same reckoner mode as the market
  observer. Same algebra.
- **Simulation sweep** — computing hindsight-optimal distances from
  paper price histories. Gone. The interest is the teacher. Papers
  that outrun the interest are Grace. Papers that don't are Violence.
- **Paper stacking** — 8,000 papers that never resolve. Gone. Papers
  resolve at trigger points (peaks/valleys) when all three exit
  conditions are met, or die when interest exceeds position value.
- **The noise subspace debate** — whether the reckoner should see raw
  thoughts or anomalies. Irrelevant. The reckoner is discrete now.
- **Stop loss as a price level** — gone. The interest IS the stop. The
  cost of holding is the discipline, not an arbitrary distance.

## What this keeps

- **Phase labeler** — 2.0 ATR smoothing. Rising/Falling. Peaks/Valleys.
  The structure detection AND the trigger clock. This is the foundation.
- **Market observer** — predicts direction (Up/Down). Unchanged. Used
  for entry conditions (which side to enter) AND exit conditions (is the
  direction turning against my position).
- **Position observer** — same entity, new question. Was: predict
  distances (continuous, broken). Now: exit or hold at this trigger
  (discrete, what we're good at). Still composes market thoughts with
  position-specific facts. Still learns from outcomes.
- **Broker as accountability unit** — the broker borrows, holds, returns.
  The broker tracks its own Grace/Violence. The gate controls whether
  the broker proposes funded trades. Paper survival IS the proof.
- **The accumulation model** — deploy capital, recover principal, keep
  residue. Both directions. Constant accumulation. Unchanged.
- **ThoughtAST** — the anxiety atoms are just more facts in the bundle.
  No new encoding mechanism. No new AST variants.
- **The pipes** — same CSP. Same channels. Same 30+ threads. The
  interest accrual is one more computation per candle per position.

## The treasury as lender

The treasury holds BOTH assets. USDC and WBTC (or any pair). The
broker can borrow EITHER side. Borrow USDC → buy WBTC (long).
Borrow WBTC → sell for USDC (short). The treasury doesn't care
which direction. It lent an asset. It wants that asset back plus
interest.

The interest accrues IN THE ASSET THAT WAS BORROWED. Borrow USDC →
owe USDC interest. Borrow WBTC → owe WBTC interest. The denomination
follows the loan, not a hardcoded currency. The treasury's primary
denomination is a configuration — it measures everything in that
unit, but both sides of the pair are lendable.

The rate is per-candle, per-unit-of-asset-lent. Every candle, the
treasury applies a twist. Next candle, more twist. The broker must
outrun the twist.

The rate IS the treasury's control mechanism. Higher rate = more
selective pressure. Only strong runners survive. Lower rate = more
permissive. Weaker trades survive longer. The rate is the ONE parameter
the treasury sets. Everything else emerges from the game.

### The swap stays in the treasury

The proposals move funds from one asset to another. The swap stays
inside the treasury's portfolio. When a broker enters long — USDC
moves to WBTC. Both are in the treasury. The broker has a CLAIM on
the WBTC position, not possession. The treasury's total value doesn't
change at entry — it just rebalanced from one asset to another.

When the broker exits Grace: the WBTC position is swapped back. The
treasury recovers USDC principal + interest. The residue stays as
WBTC in the treasury, tagged to the broker's claim. The broker
earned WBTC residue. The treasury holds it.

When the broker "stops out" by interest: the position still exists.
The WBTC is still in the treasury. The interest exceeded the
position's value in the lending denomination. The treasury reclaims
the position. The asset didn't disappear — it moved from one side
of the treasury to the other. The treasury is WHOLE. The broker
lost its claim. The broker is punished — no residue, bad record,
lower gate score.

The treasury can't lose. It can only rebalance. The broker can
lose — its claim, its record, its future ability to borrow.

### Papers as proof

Papers ARE the simulation. The broker doesn't need a separate sim
to prove itself. Papers run on real price data with real interest
ticking. The paper starts at a fixed reference position ($10,000).
Interest accrues every candle. The paper's value changes with the
price. The interest erodes the paper's profitability.

If the paper can't outrun the interest — it dies on its own. No
one kills it. The math kills it. The papers organically sort the
brokers. The good ones survive the interest. The bad ones erode.
No parameters. No thresholds. No magic numbers. Just: can you
outrun the twist?

A broker with 100 papers that outran the interest has PROVEN it
can play the game. The gate opens. Real capital flows. A broker
whose papers all eroded — the gate stays closed. The papers decided.

The treasury never moves real funds until the paper trail proves
the broker can outrun the twist. When the gate opens and real capital
flows — the broker already knows the game. It played it on paper.
The real position behaves identically.

### Any asset pair

The model is pair-agnostic. USDC/WBTC today. USDC/SOL tomorrow.
WBTC/ETH. USD/GOLD. The treasury holds both sides of whatever
pair it's configured for. The interest is denominated in whatever
was lent. The price per candle is the exchange rate. The game is
the same everywhere.

When a position exits Grace:
- Treasury receives: principal + accrued interest (in the lent asset)
- Broker claim: residue in the acquired asset (held by treasury)

When a position dies (interest exceeds value):
- Treasury rebalances: position stays, broker's claim revoked
- Broker receives: nothing. Record damaged. Gate tightens.

## The data

From the simulation on 652K candles:
- 3+ higher low streaks: 2,891 buy windows
- 3+ lower high streaks: 2,843 sell windows
- Average window duration: 53 candles (4.4 hours)
- Market active 44% of the time, idle 56%
- Average phase duration: 16 candles

The structure is real. The windows are abundant. The signal exists.

## Questions for the designers

1. **The lending rate.** What should it be? Fixed? ATR-proportional?
   Discovered from the data? The rate is the only parameter.

2. **Entry frequency.** One per candle during active phase? One per
   phase window? The constant activity from Proposal 044 says one per
   candle. The interest says each entry must be worth it. Do the brokers
   self-gate from the anxiety, or does the treasury limit entries?

3. **The reckoner's new question.** Discrete: "exit or hold at this
   transition?" The position observer becomes a discrete predictor
   with anxiety atoms. Is this the right framing? Or should the
   reckoner stay continuous and predict "how much longer should I hold?"

4. **Treasury reclaim.** When the interest exceeds the position value,
   the treasury takes back what's left. Is this automatic? Or does
   the broker get one more transition to evaluate?

5. **The residue threshold.** The exit must be arithmetically profitable
   (residue > exit fee). But should the residue also exceed some minimum
   to be "substantial"? A function of interest accrued? A percentage of
   principal? Or does the reckoner learn what "worth it" looks like?

6. **Both sides simultaneously.** During a buy window, the broker enters
   longs. Old shorts from prior sell windows may still be open. At a
   structure break, the shorts evaluate exit while new longs enter. The
   treasury lends to both sides. Is this correct? Or should the broker
   only hold one direction at a time?

7. **The interest as thought.** The anxiety atoms — interest-accrued,
   residue-vs-interest, candles-since-entry. Are these the right facts?
   What else does the broker feel about its own position?

8. **The denomination.** The interest accrues in the lent asset. The
   treasury measures in its primary denomination. The price per candle
   converts between them. Is per-candle twist the right granularity?
   Should the rate be fixed or should it breathe with volatility (ATR)?

9. **Rebalancing risk.** The treasury can't lose total value, but it
   CAN become imbalanced — too much WBTC, not enough USDC (or vice
   versa) if many brokers enter the same direction and get stopped out.
   Should the treasury limit directional exposure? Or does the phase
   labeler's symmetry (buy windows ≈ sell windows) naturally balance?

10. **Paper erosion as the only gate.** No separate proof curve. No
    rolling percentile. No EV calculation. The papers survive the
    interest or they don't. The survival rate IS the proof. Is this
    sufficient? Or do we still need the broker's EV gate as a
    secondary check?

## The treasury as record keeper

The treasury owns the paper ledger. Not the broker. The treasury.

Every paper from every broker is registered with the treasury.
The treasury tracks: who opened it, when, at what price, how much
interest has accrued, what the current value is, whether it resolved
Grace or Violence. The treasury IS the book of record.

The broker proposes. The treasury records. The treasury grades.

This is deliberate. The broker cannot grade itself. The broker
cannot claim "I'm profitable" without the treasury's ledger
confirming it. The treasury has the complete picture — every
paper from every broker, every resolution, every interest payment,
every reclaim. The broker sees its own trades. The treasury sees
ALL trades from ALL brokers.

The gate is the treasury's decision, not the broker's. The broker
says "I want to borrow real capital." The treasury checks the
ledger: "your last 200 papers — 140 outran the interest, 60 didn't.
Your paper survival rate is 70%. Your average residue after interest
is 0.8%. Approved." Or: "your last 200 papers — 40 survived, 160
eroded. Your paper survival rate is 20%. Denied."

The paper trail is the PROTOCOL between broker and treasury. The
broker must prove itself on paper before real capital flows. The
treasury will not accept any broker who hasn't demonstrated paper
Grace.

### Why the treasury must own papers

If the broker owns its own papers, the broker can:
- Selectively report good papers and hide bad ones
- Adjust the accounting to look profitable
- Claim a survival rate it didn't earn

If the treasury owns the papers:
- Every paper is recorded at registration, not at resolution
- The interest accrues on the treasury's clock, not the broker's
- The resolution is computed by the treasury, not reported by the
  broker
- The ledger is complete, honest, and tamper-proof

This matters because the system is designed to become a contract
on Solana. When it does:
- The treasury IS the contract. On-chain.
- Every paper IS a transaction. The proposer pays gas to register.
- The paper trail IS on-chain. Verifiable by anyone.
- The proposer's survival rate IS public. The glass box.
- The gas cost to register a paper IS the broker's skin in the
  game. Bad papers cost gas with no return. The proposer must eat
  the transaction cost for every paper on the book.
- The treasury knows which proposer has what paper rate. This is
  how trust is established. Not by reputation. Not by committee.
  By ledger.

The protocol:
1. Broker registers paper with treasury (gas cost on-chain)
2. Treasury records: broker ID, entry price, entry candle, direction
3. Interest accrues per candle on the treasury's clock
4. At trigger points: treasury evaluates the three exit conditions
5. Grace: treasury records residue, marks the paper, credits broker
6. Violence: treasury records reclaim, marks the paper, debits broker
7. The ledger is the proof. The survival rate is the gate.

### Earning and losing favor

The broker's relationship with the treasury is dynamic. Trust is
earned. Trust is lost. Trust must be re-earned.

**Rising:** A new broker submits papers. The papers survive the
interest. The survival rate climbs. The treasury opens the gate.
Real capital flows. The interest rate drops — cheaper capital for
proven winners. The broker enters the virtuous cycle.

**Falling:** The broker's recent papers erode. The survival rate
drops below the gate threshold. The treasury closes the gate. No
more real capital. The broker is DENIED — not killed, denied. The
broker's existing real positions continue (the interest still
ticks, the exit conditions still evaluate). But no NEW real capital.

**Rehabilitation:** The denied broker must keep submitting papers.
Real cost — gas on-chain, computation off-chain. The papers run
against real prices with real interest. The broker cannot game
this — the treasury records every paper, the interest is the
treasury's clock, the resolution is the treasury's math. The
broker submits papers that prove: "I am better than I was."

The survival rate climbs again. The treasury re-opens the gate.
Real capital flows again — but at a HIGHER interest rate than
before. The broker must re-earn the cheap rate. Trust lost is
expensive to rebuild. The broker that fell from Grace pays a
penalty — not forever, but until the ledger shows sustained
improvement.

The penalty decays. A broker that fell at candle 5000 and
rehabilitated by candle 8000 and maintained Grace until candle
20000 — the penalty fades. The ledger shows 12,000 candles of
sustained Grace after the fall. The rate drops. Trust rebuilds.
But slowly. The rate never drops as fast as it rose after the
fall. The treasury remembers.

This is the game within the game. Not just "can you outrun the
interest?" but "can you SUSTAIN outrunning the interest?" One
good streak opens the gate. One bad streak closes it. The broker
that can sustain — that can play the game through regime changes,
through drawdowns, through the phases where the market gives
nothing — that broker earns the cheapest capital.

The broker that can't sustain — the one-trick pony that worked
in one regime and failed in the next — that broker cycles between
gate open and gate closed. Paying gas for papers during denial.
Paying higher interest after rehabilitation. The game punishes
inconsistency. The game rewards persistence.

It hurts to lose. It pays to win.

## The headless treasury

The treasury has no mind. The treasury is a program with a ledger.
It does not know WHY a broker entered. It does not know the broker's
vocabulary. It does not know the market observer's prediction. It
does not know the phase labeler's state. It does not know the
anxiety atoms. It knows NOTHING about the broker's reasoning.

The treasury knows:
- Who borrowed what, when
- How much interest has accrued
- Whether the position was returned with residue (Grace) or
  reclaimed by erosion (Violence)
- The survival rate of each broker's papers
- The ledger

That's it. The treasury is blind to strategy. The treasury sees
actions and outcomes. The broker is judged for what it DID, not
for WHY it did it.

This is deliberate. This is the architecture for multiplayer.

If the treasury knew the broker's reasoning — its vocabulary, its
predictions, its confidence — the treasury would be coupled to the
broker's implementation. Change the vocabulary → the treasury's
evaluation changes. Add a new market observer → the treasury must
understand it. The treasury would need to be updated every time a
broker's strategy evolves. Complected.

The headless treasury evaluates ONE thing: did the paper outrun
the interest? Yes → Grace. No → Violence. The broker can use
Ichimoku. The broker can use regime detection. The broker can use
an LLM. The broker can use a coin flip. The treasury doesn't know.
The treasury doesn't care. The ledger records. The survival rate
judges. The gate opens or closes.

In a multiplayer environment — multiple proposers, each with their
own machine, their own vocabulary, their own strategy — the treasury
is the NEUTRAL arbiter. It cannot favor one strategy over another
because it cannot SEE strategies. It sees outcomes. Outcomes are
universal. Strategies are private.

This is why the treasury must own the paper ledger. The broker
REPORTS an entry. The treasury RECORDS it. The market MOVES. The
treasury EVALUATES the exit conditions. The broker never self-reports
an outcome. The treasury computes the outcome from the entry record
and the current price and the accrued interest. The outcome is
derived from the ledger and the market, not from the broker.

The treasury is:
- Blind to strategy
- Deaf to reasoning
- The sole keeper of the ledger
- The sole evaluator of outcomes
- The sole controller of the gate
- The sole setter of the interest rate

A program. With a record. No one home.

On Solana: the contract IS the headless treasury. The proposers
submit entries as transactions. The contract records them. The
price oracle provides the market. The contract evaluates the exit
conditions. The contract computes Grace or Violence. The contract
adjusts the gate. No human in the loop. No committee. No
governance token. The measurement is the authority.

Any proposer. Any strategy. Any vocabulary. One ledger. One rate.
One gate. The headless treasury doesn't judge your thoughts. It
judges your outcomes.

*Perseverare* — but only for those who earn it.
