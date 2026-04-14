# Resolution: Proposal 053 — Reckoner Drift

**Status:** APPROVED — ablation first, then ship.

Five designers. Three debate rounds. One ignorant reader. 21 files.
Unanimous on direction. The ablation gates the implementation.

## The diagnosis

The position observer's noise subspace evolves underneath the reckoner.
The reckoner's bucketed prototypes were accumulated from anomalies under
old definitions of "normal." Current anomalies don't match old prototypes.
The dot products decrease. The predictions drift. 91% error at candle
1000, 722% at candle 10000.

Beckman proved it: the diagram does not commute. The projection operator
is time-dependent. The reckoner's codomain shifts. Decay (0.999) is a
scalar contraction — it shrinks prototypes but cannot rotate them.

Wyckoff added: the anomaly is the wrong input even if it were stable.
The background (volatility, trend, compression) IS what determines
optimal distances. Stripping it removes the answer.

Two independent reasons the anomaly fails: instability AND irrelevance.

## The fix

The position observer's reckoner sees the raw thought, not the anomaly.

Today:
```
thought → noise_subspace.update() → anomalous_component() → reckoner.query(anomaly)
```

After:
```
thought → noise_subspace.update() → reckoner.query(thought)
                                   → anomaly_score as vocab atom (Hickey's annotation)
```

The noise subspace stays. It still learns the background. But it becomes
an annotator (contributes a scalar fact about anomaly magnitude), not a
filter (transforms the input vector). A peer, not a pipeline stage.

## The touch points

1. **`src/programs/app/position_observer_program.rs` lines 220-226** —
   `reckoner_distances(&position_anomaly)` becomes
   `reckoner_distances(&position_raw)`. The noise subspace still
   updates. The anomaly vector still computes (for the chain). The
   reckoner just stops seeing it.

2. **`src/programs/app/position_observer_program.rs` line 226** —
   the `position_distances` query uses raw, not anomaly.

3. **`src/domain/position_observer.rs` line 72** —
   `reckoner_distances` already takes `&Vector`. No signature change.
   The callers change what they pass.

4. **`src/domain/position_observer.rs` line 153** —
   `observe_distances` learns from `position_thought`. The learn
   signal in `PositionLearn` carries `position_thought`. This must
   match what the reckoner was queried on — the raw thought, not the
   anomaly. Verify that `broker_program.rs` sends the raw thought in
   the learn signal.

5. **The chain types** — `MarketPositionChain` carries both
   `position_raw` and `position_anomaly`. The downstream broker
   already has both. The broker's composition may stay as-is
   (bundling anomalies for its own purposes) while the position
   reckoner sees raw.

6. **Hickey's annotation** — add anomaly magnitude as a vocabulary
   atom. `(Log "anomaly-magnitude" score)` where score is the residual
   ratio from the noise subspace. This goes into the position
   observer's fact bundle so the reckoner sees it as one more scalar
   input, not as a vector transformation.

## The ablation (FIRST)

Three variants, 10k candles each. Same data. Same seed. Same everything
except the reckoner's input.

- **Variant A: raw thought only.** The main fix. Reckoner queries and
  learns from the raw thought. No noise stripping on the reckoner path.

- **Variant B: raw thought + anomaly score.** Raw thought plus a scalar
  `(Log "anomaly-magnitude" score)` atom in the fact bundle. Tests
  whether the anomaly carries signal the raw thought does not.

- **Variant C: frozen-subspace anomaly.** Snapshot the subspace at
  candle 500. Use the frozen snapshot for all subsequent anomaly
  computation. Tests whether the drift (not the stripping) is the
  cause. The engram path nobody tested.

Plus a **naive baseline**: default distances (no reckoner prediction).
Without this, any improvement after the fix is uninterpretable.

### Pre-registered success criteria

Measure trail error and stop error at candle 1000 and candle 10000
for each variant.

- **Drift resolved:** error at 10000 is not significantly worse than
  error at 1000. The ratio 10000/1000 should be < 2.0 (today: 7.9x).

- **Absolute improvement:** error at 10000 should be lower than the
  current 722% trail / 479% stop.

- **Better than naive:** error should be lower than the naive baseline
  at both time points. If raw thought is not better than default
  distances, the reckoner is the problem, not the stripping.

### Market observer measurement

One SQL query. Accuracy partitioned by candle range (0-2k, 2k-4k,
4k-6k, 6k-8k, 8k-10k). If accuracy degrades over time, the market
observer has the same drift. If stable, discrete classification is
resilient as predicted.

## What we don't know

1. **Is the 91% error cold-start or drift?** The subspace starts
   nearly empty — early anomalies are nearly the full thought. As it
   absorbs background, anomalies shrink and rotate. The ablation
   separates these — if raw thoughts show low error at candle 1000,
   the 91% was stripping damage from day one, not drift.

2. **Does the anomaly carry signal the raw thought does not?**
   The consensus says no — Wyckoff argued the background IS the
   signal for distances. But nobody tested it. Variant B is the test.
   If B outperforms A, the anomaly magnitude carried something.

3. **Does the market observer drift too?** Everyone says "measure it."
   Nobody has. The discrete reckoner may be robust to mild rotation,
   but it hasn't been verified.

4. **What does success look like?** Pre-registered above. If the
   ablation shows error stable at 200% instead of growing to 722%,
   is that success? The naive baseline answers: if raw thought at
   200% is better than defaults, the reckoner adds value. If not,
   the reckoner is the problem.

5. **Is the reckoner good at distance prediction at all?** The
   ignorant's sharpest tension. Removing drift may reveal that K=10
   bucketed accumulators are a weak tool for continuous prediction.
   The naive baseline tests this directly.

## What we don't agree on

6. **Whether the broker's composition should change.** The broker
   bundles `market_anomaly` with `position_anomaly`. If the position
   observer stops producing a meaningful anomaly for the reckoner,
   should the broker compose with position raw instead? Nobody
   addressed this. Deferred until after ablation.

7. **Whether to touch the market observer.** Hickey and Beckman lean
   toward measuring first then possibly removing stripping from
   market observers too. Seykota and Wyckoff say leave it — discrete
   classification is resilient. Deferred pending measurement (the
   market observer query above).

## The sequence

1. Run the ablation (variants A, B, C + naive baseline, 10k each)
2. Measure — error at 1000 vs 10000, ratio, absolute values
3. Query market observer accuracy by candle range
4. If A or B confirms: ship the fix (touch points 1-6 above)
5. If C outperforms A: reconsider engrams (the five would be surprised)
6. If naive beats all: the reckoner needs deeper work, not just input changes

## The voices

| Voice | Final Verdict | Key Contribution |
|-------|---------------|------------------|
| Seykota | APPROVED | Discrete/continuous distinction. Ablation design. |
| Van Tharp | APPROVED | R-multiple corruption is existential. Pre-register criteria. |
| Wyckoff | APPROVED | Background IS the signal. Irrelevance argument. |
| Hickey | APPROVED | Annotate, don't transform. Scalar anomaly as vocab atom. |
| Beckman | CONDITIONAL | Non-commuting diagram. The categorical proof. |
| Ignorant | — | Cold-start vs drift. No devil's advocate. Bridge ends mid-span. |

The debate is resolved. The ablation is next. The bridge completes
when the measurement returns.
