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
= the market is building upward. Three consecutive lower highs = the
market is building downward. During these conditions, the broker enters
positions.

Each entry: the broker borrows capital from the treasury. $50 USDC to
buy WBTC (long). Or $50 of WBTC to buy USDC (short). The swap costs
0.35%. The clock starts.

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

### Exit (Grace)

The structure breaks — lower low after higher lows (long), higher
high after lower highs (short). The broker evaluates:

1. Current position value in the asset
2. Minus principal recovery ($50)
3. Minus accrued interest
4. Minus exit swap fee (0.35%)
5. = residue

If residue is positive AND substantial: exit. The broker performs the
swap — recovers the principal, pays the interest, pays the exit fee,
keeps the residue in the asset. The $50 returns to the treasury. The
interest returns to the treasury. The residue is permanent. Grace.

If the swap math doesn't work — the residue minus exit fee is negative
or zero — the exit is arithmetically impossible. Hold. The interest
keeps ticking. Wait for the next structure break.

If the swap math works but the residue is thin — the reckoner decides.
Is this worth leaving? Or will holding longer produce more? The
reckoner learns what "worth it" looks like from the shape of the
anxiety: residue-vs-interest ratio, candles held, market structure.

### Exit (Violence)

The interest accrues past the position value. The trade drifted or
went adverse. The interest ate the capital. The treasury reclaims what
remains. The broker lost. The position size ($50) bounded the loss.
The broker learned from the loss — the thought that entered was wrong.

No stop loss fires. No price trigger. The trade dies from the cost
of conviction that was wrong. Natural economic death.

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
  simulation. Gone. The structure break is the exit signal.
- **Continuous reckoner on position observer** — predicting optimal
  distances. Gone. The reckoner becomes discrete: exit or hold.
- **Simulation sweep** — computing hindsight-optimal distances from
  paper price histories. Gone. The residue-vs-interest is the measure.
- **Paper stacking** — 8,000 papers that never resolve. Gone. Positions
  resolve when the structure breaks (or the interest kills them).
- **The noise subspace debate** — whether the reckoner should see raw
  thoughts or anomalies. Irrelevant. The reckoner is discrete now.

## What this keeps

- **Phase labeler** — 2.0 ATR smoothing. Rising/Falling. The structure
  detection. This is the foundation.
- **Market observer** — predicts direction. The direction determines
  which side the broker enters. Unchanged.
- **Broker as accountability unit** — the broker borrows, holds, returns.
  The broker tracks its own Grace/Violence. The gate controls whether
  the broker proposes funded trades.
- **The accumulation model** — deploy capital, recover principal, keep
  residue. Both directions. Constant accumulation.
- **ThoughtAST** — the anxiety atoms are just more facts in the bundle.
  No new encoding mechanism.

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
