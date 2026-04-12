# Review: Brian Beckman

**Verdict: APPROVE**

The arithmetic is right. The simplification is real. The questions deserve direct answers before implementation begins. I have one structural concern about the EMA and one precision issue in the gate formula. Neither blocks approval.

---

## 1. The core claim: does the expected value formula close?

The gate computes:

```
EV = grace_rate * avg_grace_net + (1 - grace_rate) * avg_violence_net
```

This is a weighted average of two EMAs under a Bernoulli partition. Let me verify it closes.

Let `p` be the empirical grace rate (fraction of papers that resolve as Grace). Let `mu_g` be the EMA of net dollar P&L over Grace papers. Let `mu_v` be the EMA of net dollar P&L over Violence papers (negative by construction). Then:

```
EV = p * mu_g + (1 - p) * mu_v
```

This IS the expected value of the dollar outcome per paper, provided `p`, `mu_g`, and `mu_v` are consistent estimates — i.e., drawn from the same underlying joint distribution of (outcome, net P&L). They are: all three quantities are computed from the same sequence of resolved papers. The formula closes. The gate is `EV > 0`, which is the break-even condition after fees. One comparison. Correct.

The subtlety: `mu_g` and `mu_v` are separate EMAs, not a single EMA partitioned by outcome. This means they track the moving average of net P&L conditioned on outcome. The formula then weights by the unconditional outcome probability. This is a valid factoring of the joint expectation:

```
E[net] = E[net | Grace] * P(Grace) + E[net | Violence] * P(Violence)
```

The three EMAs are consistent estimators of the three quantities on the right. The gate is a consistent estimator of `E[net]`. This is what you want.

**Assessment: The formula is algebraically clean and statistically sound.**

---

## 2. The fee arithmetic

From the proposal, for a Grace resolution:

```
residue-usd  = residue-pct * reference-usd
exit-fee     = (reference-usd + residue-usd) * 0.0035
net-grace    = residue-usd - entry-fee - exit-fee
```

Expanding:

```
net-grace = residue-usd - 35.00 - (10000 + residue-usd) * 0.0035
          = residue-usd - 35.00 - 35.00 - residue-usd * 0.0035
          = residue-usd * (1 - 0.0035) - 70.00
          = residue-usd * 0.9965 - 70.00
```

Break-even for a single Grace paper: `residue-usd = 70.00 / 0.9965 ≈ $70.25`. As a fraction of the reference position: `70.25 / 10000 = 0.7025%`. This is correct — you need approximately 0.7% excursion to cover the round-trip 0.7% fee load, plus a small second-order term from the exit fee applying to the gross position.

For Violence:

```
net-violence = -(loss-usd + entry-fee + exit-fee)
             = -(loss-usd + 35.00 + (10000 - loss-usd) * 0.0035)
             = -(loss-usd + 35.00 + 35.00 - loss-usd * 0.0035)
             = -(loss-usd * 0.9965 + 70.00)
```

The exit fee on Violence applies to the *reduced* position value `(reference-usd - loss-usd)`, which is correct — you pay exit fees on what you actually receive. The arithmetic is right.

**Assessment: Fee arithmetic is exact. No corrections needed.**

---

## 3. Structural concern: three EMAs or one?

The proposal tracks `avg-net-residue`, `avg-grace-net`, and `avg-violence-net` as separate EMAs. The gate uses only `avg-grace-net` and `avg-violence-net`. `avg-net-residue` appears only in diagnostics.

The concern: `avg-net-residue` updated on every paper is NOT equal to `p * avg-grace-net + (1-p) * avg-violence-net` unless the EMA decay rate is identical and the partition is stable over time. In a non-stationary environment (changing grace rates), the two estimates drift apart.

More precisely: `avg-net-residue` is an EMA over the full sequence of net outcomes regardless of outcome type. The gate formula reconstructs the expected value by combining the partitioned EMAs with the current `grace_rate`. If the regime has been predominantly violent recently, `grace_rate` falls, but `avg-grace-net` may reflect a grace period from many candles ago. The gate formula is NOT the EMA of the gate formula's output — it is a pointwise combination of three EMAs at the moment of evaluation.

This is fine as long as all three EMAs use the same decay constant `alpha`. If they do, the three EMAs are consistent estimators of the conditional and marginal expectations under a time-weighted distribution with the same half-life. The gate formula is then computing the *current* expected value under that shared time-weighting. This is the correct behavior: recent papers dominate, old papers decay away.

The question (Question 2 in the proposal) is: what alpha? The answer is not the recalib interval. The recalib interval is about when to retrain the reckoner. The EMA half-life should be about *how many papers constitute a stable estimate of the expected value*. If the broker resolves papers at roughly 1 per 2 candles (bootstrap: fast papers, fast resolution), then 100 papers is approximately 200 candles = roughly 17 hours of 5-minute BTC data. A half-life of 50 papers means the EMA forgets the regime from 100 papers ago at the 1/e^2 level. This seems reasonable — it responds to regime shifts within days, not hours, and does not overreact to single outliers.

My recommendation: use `alpha = 2 / (N_halflife + 1)` where `N_halflife` is 50 papers. This gives `alpha ≈ 0.038`. Let this be independent of the recalib interval. The recalib interval governs reckoner retraining; the EMA governs the profitability gate. These are different timescales and should breathe independently.

**Assessment: Three EMAs are correct. Tie them to paper count, not candle count. Independent of recalib interval.**

---

## 4. The grace_rate in the gate formula

The proposal writes:

```scheme
(define (broker-gate broker)
  (let ((ev (+ (* (:grace-rate broker) (:avg-grace-net broker))
               (* (- 1 (:grace-rate broker)) (:avg-violence-net broker)))))
    (> ev 0.0)))
```

`grace_rate` is not shown as a field on `broker-accounting`. The proposal adds `grace-count` and `violence-count` (both labeled "already exists") but not `grace-rate` explicitly. The gate formula needs `grace_rate = grace_count / (grace_count + violence_count)`. This is a derived quantity, not a stored field, which is correct. But the implementation must guard against `grace_count + violence_count = 0` (the cold start case where the rate is undefined). The proposal handles this via the cold-start bypass (< 100 papers), so the gate formula is only evaluated when at least 100 papers have resolved. At that point the denominator is 100, guaranteed nonzero.

One additional guard: if `avg-grace-net` is zero (no Grace papers in the EMA window) or `avg-violence-net` is zero (no Violence papers), the formula degrades gracefully — it returns the contribution from the populated side only, weighted by the rate. This is correct behavior.

**Assessment: The formula is safe given the cold-start bypass. Document the derived nature of grace_rate explicitly in the struct comment.**

---

## 5. The cold start question

The proposal asks: is 100 papers too many or too few? The bootstrap produces near-zero-distance papers that resolve fast. 100 papers might be 10 candles.

Let me reason about it differently. The question is: when does the EMA contain enough resolved papers to be a meaningful estimator of the expected value? An EMA with decay constant `alpha = 0.038` has an effective window of approximately `2/alpha - 1 = 52` papers. So after 100 papers, the EMA has seen roughly two full effective windows. The estimator is past its initialization phase. This is the right condition for opening the gate: not "we have enough data for statistical significance" but "the EMA is past its warm-up period."

52 papers as a warm-up minimum, 100 as the gate threshold — this is a 2x safety margin over the EMA's effective window. Reasonable.

If the bootstrap resolves papers in ~10 candles, 100 papers in ~1000 candles = 83 hours of 5-minute data = 3.5 days. This is the cold start cost. Acceptable for a system trained on years of data.

**Assessment: 100 papers is well-reasoned. Document the relationship to the EMA half-life so future changes to alpha also update the cold-start threshold proportionally: cold_start_papers = 2 * (2/alpha - 1).**

---

## 6. The proposal's own question about entry_price vs. close

The proposal answers its own question (Question 1): use `entry_price`. This is correct. The reference position is entered at `entry_price`, not at the candle close when the broker evaluates the gate. The P&L is computed against the actual entry. The close at evaluation time is irrelevant to the accounting of a trade that has already been entered.

The gate evaluates the broker's *historical* accounting — what has it earned after fees across past papers. The current candle's close is not part of that calculation. The proposal correctly identifies this and resolves it.

**Assessment: Correct.**

---

## 7. What this replaces, and what is lost

The old gate: `cached_edge > 0.0 || !curve_valid()`. This is a reckoner-derived gate. It asks: "does the reckoner's curve show positive edge at the current conviction level?" The reckoner curve is a function of accumulated (conviction, correctness) pairs — a learned mapping from how confident the broker is to how often it is right.

The new gate: `EV > 0.0 || cold_start`. This asks: "is the broker making money after fees, on average?" No reckoner involvement. No curve. Just arithmetic over resolved papers.

What is lost: the reckoner curve contains *selectivity* information — the broker may earn positive EV only when it is highly convicted, and lose EV at low conviction. The arithmetic gate averages across all conviction levels. If the broker's EV is driven by high-conviction winners and the gate opens on positive average EV, it will also register papers during low-conviction periods that are individually EV-negative.

The proposal acknowledges this: "If the curve ever validates, the curve adds selectivity on top of the arithmetic gate." This is the right layering. The arithmetic gate is necessary (is the broker profitable at all?). The curve is sufficient (is it profitable *now*, at *this* conviction level?). The proposal installs the necessary condition and defers the sufficient condition. The ordering is correct.

The reckoner's accumulated history is not wasted — it continues to build. When the curve eventually validates, it can gate on top of the arithmetic. The architecture remains composable.

**Assessment: The loss of selectivity is a known trade-off and is correctly sequenced. The arithmetic gate is the prerequisite. Document the intended layering explicitly in the gate's comment.**

---

## 8. Wat changes

The proposal requires additions to `broker.wat`:

- Four new fields on `broker-accounting` (or folded into the `broker` struct directly, since the proposal shows them as a separate struct but the existing `broker` struct has no accounting sub-struct).
- A new function `compute-net-residue` that takes outcome, excursion/loss fraction, and entry-close and returns dollar net.
- Updated `propagate` to call `compute-net-residue` and update the four accounting fields.
- Updated gate logic (currently implicit in the register-paper call site — the proposal should locate where the gate check lives in the existing wat).

Looking at the existing `broker.wat`: the `register-paper` function is called by the post (or the broker's propose/dispatch path). The gate check belongs at the `register-paper` call site. The proposal should specify whether the gate lives inside `register-paper` (the broker self-gates) or at the call site in the post (the post consults the broker's gate). For composability and testability, the gate should be a pure function on the broker state, called at the register site:

```scheme
(define (gate-open? [broker : Broker])
  : bool
  (if (< (:trade-count broker) 100)
      true
      (let ((rate (/ (as-f64 (:grace-count broker))
                     (as-f64 (+ (:grace-count broker) (:violence-count broker))))))
        (> (+ (* rate (:avg-grace-net broker))
              (* (- 1.0 rate) (:avg-violence-net broker)))
           0.0))))
```

And the existing `cached_edge > 0.0 || !curve_valid()` logic is replaced with `gate-open?`.

**Assessment: Specifying `gate-open?` as a pure function with this signature would complete the wat changeset. Add it.**

---

## Summary

The proposal is correct. The fee arithmetic closes. The EMA factoring is statistically sound. The cold start threshold is well-reasoned. The layering (arithmetic gate first, curve selectivity later) is the right ordering.

Two things to add before implementation:

1. Document `cold_start_papers = 2 * (2/alpha - 1)` so the cold-start threshold is derived from, not decoupled from, the EMA decay constant.

2. Add `gate-open?` as an explicit pure function to `broker.wat` with the signature above. The gate should be inspectable and testable in isolation.

The proposal correctly identifies that the reckoner's accumulated prototypes are diagnostic artifacts — ten runs of convergence proved there is no candle-state signal that predicts future excursion at per-candle resolution. The arithmetic gate does not pretend otherwise. It asks only: "net positive after fees?" This is the honest question. The simplicity is the point.

One multiplication. One comparison. The geometry of the reckoner cannot answer this question. The arithmetic can.

APPROVE.

--- Brian Beckman
