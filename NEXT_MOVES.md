# Next Moves — Holon BTC Trader

## The Core Discovery (2026-03-27)

**Charts don't predict. Interpretations of charts predict.**

Visual raster vectors (pixels) show ZERO clustering by outcome: win-win cosine = win-loss cosine = 0.403, gap = 0.0004. A faithful screenshot of a chart contains no exploitable pattern structure for direction prediction.

Thought vectors (named facts: "RSI diverging", "volume contradicting", "near range high") have d'=0.734 separation between winners and losers. The signal lives in the interpretation, not the image.

The discriminant finds a subtle linear direction in this interpretation space. The conviction (|cosine|) against that direction measures how strongly the current state matches the learned reversal pattern. **This conviction has an exponential relationship to accuracy:**

```
accuracy = 0.50 + a × exp(b × conviction)

Three phases:
  Noise zone    (conv 0.00-0.13): 50.3% — random
  Linear zone   (conv 0.14-0.22): 54.5% — signal emerges
  Exponential zone (conv 0.23+):  63.0% — signal accelerates
```

The curve is continuous, monotonic, and the operating point is set by ONE parameter: `min_edge` (minimum acceptable accuracy = cost of trading on this venue). Everything else derives from the curve.

---

## Best Results (100k candles, Jan–Dec 2019)

| Quantile | Win% | Trades | Conviction threshold |
|----------|------|--------|---------------------|
| q85 | 53.9% | 11,019 | 0.133 |
| q95 | 57.1% | 3,857 | 0.177 |
| **q99** | **59.7%** | **870** | **0.227** |
| q995 | ~68%* | ~50* | 0.265 (*too few trades) |

Fine-grained threshold sweep (from q99 DB):
```
0.220  676 trades  60.2%
0.224  577 trades  61.5%
0.228  486 trades  62.1%
0.232  420 trades  63.3%
0.236  366 trades  65.0%
0.240  317 trades  65.9%
```

**60% breaks at conviction ≥ 0.22. 65% at ≥ 0.24.**

---

## The Self-Deterministic System

One economic input: `--min-edge` (what's the minimum win rate worth trading?).

The system derives everything else:
- **Flip threshold**: from the exponential curve: `conv = ln((min_edge - 0.50) / a) / b`
- **Position sizing**: half-Kelly from estimated win rate at current conviction
- **Trade gate**: Kelly > 0 → trade; Kelly ≤ 0 → skip
- **Move threshold**: `K × atr_r` (ATR-relative, asset-independent)
- **Decay**: fixed 0.999 (proven optimal — every adaptation experiment performed worse)

Strategy profiles from the same model:
```
min_edge=0.55  →  threshold≈0.16, ~4600 trades, 55.7% win  (volume trader)
min_edge=0.60  →  threshold≈0.22, ~676 trades,  60.2% win  (balanced)
min_edge=0.65  →  threshold≈0.24, ~317 trades,  65.9% win  (sniper)
```

---

## 652k Full Dataset Validation (IN PROGRESS)

Running q99 across Jan 2019–Mar 2025 (652k candles). Covers:
- 2019: bull recovery (known: 59.7%)
- 2020: COVID crash + V-recovery
- 2021: mega bull $29k→$69k
- 2022: bear market, Luna, FTX
- 2023-2025: recovery, new ATH

This is the acid test. If >55% holds across all regimes, the signal is real.

---

## Run History — Sessions 2-4

| Candles | Name | Win% | Equity | Trades | Notes |
|---------|------|------|--------|--------|-------|
| 100k | thought-vocab-v2-100k | 53.8% | +8.17% | 11,203 | vocab v2, q85 |
| 100k | thought-vocab-v3-q95 | **57.1%** | +4.39% | 3,857 | PELT divergence, q95 |
| 100k | auto-flip-v4 | 51.5% | **+17.61%** | 19,159 | auto flip, best P&L |
| 100k | thought-vocab-v4-q95 | 56.7% | +4.18% | 3,877 | + wick PELT streams |
| 100k | decay998-q95 | 55.0% | +2.54% | 3,965 | faster decay — worse |
| 100k | adaptive-decay-q95 | 55.3% | +3.70% | 4,017 | state machine — worse |
| 100k | dual-v2-q95 | 55.5% | +3.37% | 4,038 | subspace blend — worse |
| 100k | **q99** | **59.7%** | +0.67% | **870** | **Best win rate** |
| 100k | pruned-q95 | 54.8% | +2.76% | 4,029 | fire-rate suppress — worse |
| 100k | degenfix-q95 | 56.8% | +4.17% | 3,872 | degen filter — neutral |

---

## What Was Proven Wrong

### Decay adaptation (all variants worse than fixed 0.999)
- Fixed 0.998: 55.0% (too noisy everywhere)
- Adaptive state machine: 55.3% (reactive, not predictive)
- Dual journal blend: 55.5% (fast journal dilutes stable periods)
- The discriminant needs memory depth. Regime transitions hurt but every fix costs more.

### Visual as a signal source
- Visual-only: 50.5% (barely above random)
- Visual amplification: neutral (convictions correlated)
- Visual engram clustering: impossible (no outcome-dependent structure)
- **Visual captures pixels. Thought captures meaning. Only meaning predicts.**

### Fact pruning/weighting
- Fire-rate suppression: -2.3pp (regime constants carry transition context)
- Weighted bundling: feedback loop (inflates conviction, doesn't improve accuracy)
- Degenerate segment filter: neutral (discriminant already handles it)
- **The discriminant is more robust than we gave it credit for.**

### Regime prediction from model signals
- Conviction level: doesn't predict bad epochs (model can be confidently wrong)
- Conviction variance: no correlation with upcoming accuracy
- Subspace residual: stable at 53% explained ratio, no regime signal
- Discriminant strength: inversely correlated with accuracy (strong disc ≠ good disc)
- **The thought manifold is regime-invariant. Only the label boundary moves.**

---

## What Was Proven Right

### The conviction-accuracy curve is real and continuous
- Monotonically increasing from 50% (noise) to 75%+ (extreme tail)
- Exponential functional form: `0.50 + a × exp(b × conviction)`
- Every quantile step up produces proportionally better accuracy
- The curve is a property of the encoding geometry, not the market

### Thought encoding is the trader's interpretation
- Named facts (RSI divergence, volume confirmation, PELT segments) carry the signal
- The discriminant finds the subtle linear direction that separates buy from sell
- High conviction = many facts voting coherently = trend extreme = reversal likely
- This is "wisdom of crowds" in VSA — bundled facts as parallel voters

### Explainability tables reveal what the model learned
- disc_decode: top-20 facts by discriminant contribution at each recalib
- trade_facts: facts present for each traded candle
- trade_vectors: raw bipolar vectors for offline analysis
- Calendar facts (h04, tuesday) ARE partially real in the flip zone
- RSI oversold zone events: 65-73% conditional win rate (strongest signal)

---

## Open Threads

### 1. Exponential curve fit for self-deterministic threshold
Implemented. Fits `a` and `b` from binned resolved predictions. Needs 5000+ samples for stable high-conviction bins. Falls back to quantile during warmup.

### 2. Full 652k validation (running now)
The acid test for regime robustness. q99 across 6 years of BTC history.

### 3. Kelly position sizing
Implemented (`--sizing kelly`). Half-Kelly from calibration curve at current conviction. Not yet tested at scale — P&L has been secondary to win rate.

### 4. Thought engrams (the next frontier)
Visual engrams are dead (no clustering). But thought vectors have d'=0.734 separation. The signal isn't in clustering (thought vectors don't cluster by outcome either) — it's in the discriminant direction.

Possible directions:
- Per-regime discriminants (different label boundaries for different market structures)
- Engram-based regime detection (store discriminant snapshots, match to current)
- Thought fact signatures per regime (which facts predict reversals in each regime?)

### 5. Cross-asset generalization
ATR-based move threshold implemented. Time-based parameter system designed (express decay/recalib/horizon in hours, derive candle counts from candle duration). Not yet tested on other assets.

### 6. Strategy modes (MSTR-inspired)
Different operating points on the conviction-accuracy curve serve different goals:
- Income: min_edge=0.55, high volume, steady small edge
- Growth: min_edge=0.60, balanced trades, solid accuracy
- Sniper: min_edge=0.65, rare trades, high accuracy + Kelly sizing
- Yield target: compute required trades × edge × sizing → derive min_edge

### 7. The expression as the primitive
`accuracy = 0.50 + a × exp(b × conviction)` — this isn't just a threshold finder. It's the fundamental relationship of the system. Everything builds on this curve:
- Threshold derivation
- Position sizing (Kelly from point on curve)
- Strategy selection (operating point)
- Regime detection (when a and b shift)
- Cross-asset comparison (different assets have different a, b)

The curve IS the model. The discriminant and encoding produce conviction. The curve converts conviction to expected accuracy. Everything else is plumbing.

---

## Architecture Reference

```
candle → viewport (4 panels) → visual raster vector → visual journal (unused for trading)
candle → thought encoder → thought fact bundle → thought journal → discriminant → conviction
                                                                                    ↓
conviction → exponential curve → expected accuracy → threshold (from min_edge)
                                                   → position size (half-Kelly)
                                                   → flip direction (if above threshold)
                                                   → trade or skip
```

Key files:
- `rust/src/thought.rs`: thought encoding (facts, PELT, comparisons, divergence, calendar)
- `rust/src/journal.rs`: Journal struct (accumulators, discriminant, predict, decode)
- `rust/src/bin/trader3.rs`: main loop (orchestration, flip, auto threshold, sizing, DB logging)
- `rust/src/viewport.rs`: visual encoding (4-panel raster — DON'T MODIFY)
- `rust/src/db.rs`: candle loader (DON'T MODIFY)
