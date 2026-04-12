# Review of Proposal 032 — Brian Beckman
*Does it compose? I reread my findings. I reread the proposal. Here is what commutes and what does not.*

---

## Summary Judgment

The proposal correctly addresses the two critical defects and eliminates the
Fibonacci redundancy. It also makes several good scale corrections. But it
introduces two new encoding errors that contradict the mathematical analysis in
my review, and it silently ignores four findings that I explicitly flagged.

**The proposal is not ready to execute as written.** Two incorrect choices must
be reversed. Four omissions must be addressed or explicitly deferred with
justification.

---

## What the Proposal Gets Right

### RSI bug — addressed correctly
Both instances (`market/oscillators.rs` and `exit/timing.rs`) corrected to
`/ 100.0` before encoding. This was the highest-severity finding. Correct fix.

### Squeeze bug — addressed correctly
`market/keltner.rs`: squeeze changed from `Linear, scale=1.0` to `Log`.
Ratio quantity, multiplicative structure — Log is the right choice. Correct.

### Fibonacci redundancy — addressed correctly
All five `fib-dist-*` atoms removed. The proposal notes that `range-pos-48`
already encodes proximity via the smooth similarity gradient. This is the
correct algebraic reasoning. I recommended either a categorical `fib-level-nearest`
atom or simple removal. Removal is the simpler choice. Acceptable.

### Scale corrections in momentum.rs — addressed correctly
`close-sma200` scale 0.1 → 0.3. I flagged this explicitly: BTC routinely
exceeds ±10% from its 200-day MA, causing aliasing. The proposal also adjusts
`close-sma50` to 0.15, which is a reasonable preventive correction.

### selling-pressure removal — addressed correctly
`flow.rs`: selling-pressure dropped. `buying-pressure + selling-pressure = 1.0`
is the exact linear dependence I described. Correct.

### kelt-lower-dist removal — addressed correctly
The symmetric argument is valid and I flagged this in my keltner analysis.
Correct.

### stoch-cross-delta removal — addressed correctly
I noted stoch-cross-delta is the derivative (difference) of stoch-kd-spread
and thus a redundant linear combination. Correct to remove.

### Regime centering fixes — partially my finding
`dfa-alpha` and `fractal-dim` centering: my review noted no defects in these
atoms as encoded (the `/2.0` normalization produces a valid [0,1] range), but
centering around the meaningful boundary (0.5 for DFA alpha, 1.5 for fractal
dimension) improves discriminant placement. This is a Hickey finding that the
proposal incorporates. Mathematically sound even if not my finding.

### Naming corrections — correct
`market-direction → market-signed-conviction` and `recalib-freshness →
recalib-staleness` are honest names. The first name I endorsed explicitly;
both corrections are sound.

---

## Incorrect Choices: The Proposal Contradicts My Review

### 1. variance-ratio: Log → Linear (WRONG)

My review is unambiguous:

> **`variance-ratio`**: Type: Correct. Variance ratio tests whether price
> returns follow a random walk. Under the null (random walk), VR = 1.0.
> Deviations are **multiplicative** — VR = 2.0 and VR = 0.5 are equally
> "surprising" from the random walk. Log encoding captures this multiplicative
> symmetry. **Correct choice.**

The proposal encodes variance-ratio as:
```scheme
(Linear "variance-ratio" (- variance-ratio 1.0) 1.0)
```

This is wrong on two counts.

First, variance-ratio is a multiplicative quantity. VR = 2.0 means "twice
the variance you'd expect from a random walk." VR = 0.5 means "half the
expected variance." These are symmetric deviations in log space, not in
linear space. With Linear encoding, VR = 2.0 and VR = 0.5 produce vectors
with `|value| = 1.0` — equal linear distance from center. That is
accidentally correct in magnitude. But VR = 4.0 and VR = 2.0 produce
`|value| = 3.0` and `|value| = 1.0` — the 2× ratio looks like 3× in linear
space. The geometry does not match the market semantics.

Second, the centering `(- variance-ratio 1.0)` with scale=1.0 means the
range [0, 1.0] (VR below random walk) maps to [-1.0, 0.0] and the range
[1.0, 2.0] maps to [0.0, 1.0]. But variance-ratio is unbounded above —
VR = 5.0 would produce a value of 4.0, which with scale=1.0 completes four
full rotations. Aliasing re-enters on the high side.

The correct encoding remains what was already in the vocabulary:
```scheme
(Log "variance-ratio" (max variance-ratio 0.001))
```

If the proposal follows Hickey's recommendation to "center" variance-ratio,
that is a domain disagreement with my analysis, not a synthesis of both
reviews. My analysis holds: **Log is correct for ratio quantities measured
relative to a null of 1.0.**

### 2. consecutive-up / consecutive-down: Log → Linear (WRONG)

My review on `consecutive-up` and `consecutive-down`:

> Count of consecutive up/down candles. Adding 1 ensures the value is ≥ 1
> (avoiding log(0)). Log encoding is correct — the first consecutive candle vs.
> the second is as significant as the 9th vs. the 10th (multiplicative reasoning
> about momentum persistence).

The proposal encodes them as:
```scheme
(Linear "consecutive-up"   (/ consecutive-up 10)  1.0)
(Linear "consecutive-down" (/ consecutive-down 10) 1.0)
```

This is wrong. Consecutive candle counts are discrete counts where the
relevant comparison is multiplicative: 2 consecutive up is to 4 consecutive
up as 4 is to 8. Whether a run has lasted 2 candles vs. 4 candles is as
significant as 4 vs. 8. The Linear encoding treats 2→4 as the same angular
distance as 8→10, which is false to the market.

Additionally, the `/10` normalization assumes runs never exceed 10 candles.
In trending BTC markets, runs of 15–20 consecutive candles in the same
direction occur. With scale=1.0 after dividing by 10, a run of 15 produces
value=1.5 — aliasing past a full rotation.

The correct encoding from my review:
```scheme
(Log "consecutive-up"   (max (+ 1.0 consecutive-up) 1.0))
(Log "consecutive-down" (max (+ 1.0 consecutive-down) 1.0))
```

---

## Omissions: My Findings Not Addressed

### 3. ichimoku.rs — tk-spread redundancy (not addressed)

My review:

> `tk-spread = -(tenkan-dist - kijun-dist)`. The tk-spread atom is a linear
> combination of tenkan-dist and kijun-dist. **tk-spread is algebraically
> redundant given tenkan-dist and kijun-dist.** Consider removing it.

The proposal states: "ichimoku.rs (6 atoms) — No changes. All encoding types
and scales are correct."

This is incomplete. The type and scale are correct. The algebraic redundancy
is not a type error — it is a geometric budget concern. The proposal should
either remove tk-spread or explicitly state why the signal amplification is
worth the geometric cost (e.g., "the exit reckoner empirically benefits from
the explicit spread signal").

### 4. exit/volatility.rs — atr-r redundancy (not addressed)

My review:

> `atr-r` and `atr-ratio` encode very similar information: ATR absolute vs. ATR
> normalized by price. Their correlation is extremely high. **Remove `atr-r`
> from the exit vocabulary; `atr-ratio` already captures the volatility signal.**

The proposal states: "exit/volatility.rs (6 atoms) — No changes. All correct."

Six atoms includes both `atr-r` and `atr-ratio`. This omission is not a
blocking concern — I classified it Low severity — but the proposal claims the
exit volatility module is "all correct" when I found a specific redundancy.
Either address it or explicitly defend keeping both.

### 5. Unverified candle field definitions (not addressed)

My review flagged three assumptions that must be verified empirically:

- `tf_1h_body` / `tf_4h_body`: are these fractional returns or raw price deltas?
  If raw deltas in BTC price terms, the `tf-1h-trend` and `tf-4h-trend` atoms
  alias completely.
- `entropy_rate`: pre-normalized to [0, 1]? Or in bits?
- `atr_roc_N`: fractional change or multiplicative factor? If multiplicative,
  needs Log not Linear.

The proposal lists `timeframe.rs` with "No changes" and `exit/volatility.rs`
with "No changes" without resolving these. These are unverified assumptions I
flagged as requiring code inspection. The proposal should either confirm the
normalization is correct (with a code reference) or add the appropriate
normalization.

### 6. exit-avg-residue floor precision (not addressed)

My review:

> If residue varies in the range [0.0001, 0.01], the floor at 0.001 cuts off
> the most precise performance information. Consider lowering the floor to
> 0.0001.

The proposal states `exit/self_assessment.rs` has "No changes." This is the
lowest-severity finding — Minor — but the proposal's summary claims to fix
"5 encoding bugs." This floor concern is an encoding precision issue, not a
correctness defect. The proposal is silent on it. Either dismiss it explicitly
or lower the floor.

---

## One Observation on the body/wick Redundancy

My review said to drop one of the three atoms `{body-ratio-pa, upper-wick,
lower-wick}` because three atoms encoding two degrees of freedom wastes one
atom's geometric budget.

The proposal removes `body-ratio-pa` (which was also a duplicate of
`body-ratio` in `flow.rs`). This leaves `upper-wick` and `lower-wick`. The
partition identity `body + upper + lower = 1` now applies to `body-ratio`
(flow.rs), `upper-wick`, and `lower-wick` — but these span two modules, so
the broker doesn't necessarily see all three simultaneously.

Within `price_action.rs`, the proposal correctly has two wick atoms without
body — this is valid (two atoms, two degrees of freedom). The concern I
raised is resolved for the `price_action.rs` module specifically, because
`body-ratio-pa` removal eliminates the redundant third. The cross-module
concern (body-ratio in flow + upper/lower in price_action) is a separate
issue for the broker's composed bundle. I note it; I do not count it as a
proposal defect.

---

## Algebraic Closure Check: The Centering Conventions

The proposal introduces centering transformations: `(- dfa-alpha 0.5)`,
`(- variance-ratio 1.0)`, `(- fractal-dim 1.5)`. I verify these commute
correctly with Linear encoding.

For `dfa-alpha`: natural range [0, 2], meaningful boundary at 1.0 (random
walk). After `/2.0` (the current encoding), the boundary is at 0.5.
After `(- dfa-alpha 0.5)` with scale=0.5: the range [0, 2] maps to [-0.5,
1.5], which at scale=0.5 spans [-1, 3] — three full rotations on the high
end. Aliasing risk in strongly trending regimes where DFA alpha > 1.5.

The better formulation for centering around 0.5 with scale 0.5 would be
`(- (/ dfa-alpha 2.0) 0.5)` — first normalize to [0,1] then center. But
the proposal writes `(- dfa-alpha 0.5)`. If the raw `dfa-alpha` is in [0, 2],
then `(- dfa-alpha 0.5)` with scale=0.5 produces values in [-0.5, 1.5] at
scale=0.5, which is 3 full rotations at the high end. The encoding aliases
for alpha > 1.5.

If `dfa-alpha` is already normalized to [0, 1] (as the current `/2.0` suggests
it arrives as [0,2] and is divided), then `(- dfa-alpha 0.5)` in the proposal
means `(- (alpha/2.0) 0.5)` — but the proposal doesn't show the `/2.0` anymore.
The notation is ambiguous. **The proposal must specify whether the value shown
is post-normalization or raw.** The same concern applies to `fractal-dim`:
is the raw value in [1, 2] or [0, 1]? `(- fractal-dim 1.5)` with scale=0.5
requires the raw value to be in [1, 2].

This is not a blocking defect but the notational ambiguity in the scheme
pseudocode should be resolved before implementation.

---

## Does the Proposal Correctly Synthesize Both Reviews?

Partially. The synthesis correctly captures:
- All three of my High/Medium defects (RSI, squeeze, Fibonacci)
- The scale corrections I recommended
- The redundancy removals I flagged (selling-pressure, kelt-lower-dist,
  stoch-cross-delta)

The synthesis incorrectly incorporates (or invents, against my analysis):
- variance-ratio type change: Log → Linear (wrong; contradicts my review)
- consecutive encoding change: Log → Linear (wrong; contradicts my review)

The synthesis misses:
- tk-spread ichimoku redundancy (I flagged; proposal ignores)
- atr-r exit/volatility redundancy (I flagged; proposal claims "all correct")
- Three unverified candle field definitions (I flagged; proposal is silent)
- exit-avg-residue floor precision (I flagged; proposal is silent)

---

## Required Actions Before Execution

**Must fix:**
1. Revert `variance-ratio` to `(Log "variance-ratio" (max variance-ratio 0.001))`.
   Do not center. Do not change to Linear.

2. Revert `consecutive-up` and `consecutive-down` to Log encoding.
   Keep the `(+ 1.0 count)` floor convention, not the `(/ count 10)` Linear
   normalization.

**Should address (or explicitly defer with justification):**
3. `ichimoku.rs` — decide on tk-spread. Remove it or defend it.

4. `exit/volatility.rs` — decide on `atr-r`. Remove it or defend it.

5. Verify `tf_1h_body`, `tf_4h_body`, `entropy_rate`, and `atr_roc_N` against
   the Candle struct. Confirm normalization or add it.

6. Clarify the centering pseudocode: does the scheme notation show pre- or
   post-normalization values? The dfa-alpha and fractal-dim cases require
   careful reading to avoid introducing aliasing.

---

*The algebra does not lie. VR=2.0 and VR=0.5 are equidistant from VR=1.0 in
log space. In linear space they are not. Encode the geometry that matches the
market.*
