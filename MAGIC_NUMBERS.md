# Magic Numbers — every one is an expert waiting to be born

These are the hardcoded values in the enterprise. Each suppresses the market's voice.
Each should eventually be derived from ATR, conviction, dims, or the curve — or become
an expert that learns its own answer.

## Accuracy thresholds (should reference min_edge)

| Value | Location | What it gates |
|-------|----------|---------------|
| 0.52 | `portfolio.rs:304` | Tentative → Confident phase transition |
| 0.50 | `portfolio.rs:305` | Confident → Tentative demotion |
| 0.52 | `enterprise.rs` observer curve_valid | Observer proof gate |
| 0.55 | `enterprise.rs` engram snapshot | "Good state" recording |
| 0.55 | `enterprise.rs` panel recalib | Panel quality gate |
| 0.505 | `sizing.rs:33` | Kelly regression floor |
| 0.505 | `enterprise.rs` curve filter | Resolved prediction filter |

**Why bad:** `args.min_edge` exists (default 0.55) but these gates ignore it. Seven places deciding "good enough" independently.

**Fix:** derive from `min_edge`. Phase transition at `min_edge - margin`. Observer proof at `min_edge`. Kelly floor at `0.50 + epsilon`.

## Position sizing constants

| Value | Location | What it controls |
|-------|----------|------------------|
| 0.20 | `enterprise.rs:435` | Max single position (20% of equity) |
| 0.03 | `enterprise.rs:903` | Band edge for conviction proof |
| 0.01 | `enterprise.rs:1022` | Minimum bet (1% floor) |
| 0.01 | `enterprise.rs:808` | Minimum profit reclaim (1% of deployed) |

**Why bad:** not derived from ATR, conviction, or portfolio state.

**Fix:** sizing expert (task #5) — learns allocation from treasury state.

## OnlineSubspace parameters

| k | Params | Location | Purpose |
|---|--------|----------|---------|
| 32 | defaults | `enterprise.rs:319` | Thought manifold (tht_subspace) |
| 4 | 2.0, 0.01, 3.5, 100 | `enterprise.rs:337` | Panel engram |
| 8 | 2.0, 0.01, 3.5, 100 | `risk/mod.rs:19` | Risk branches (×5) |
| 8 | defaults | `market/observer.rs:38` | Observer good-state subspace |

**Why different k:** thought manifold has ~120 facts (needs k=32). Panel has 6 dimensions (k=4 sufficient). Risk and observers have full dims but sparse signal (k=8).

**Fix:** k should derive from the input dimensionality. The other params (learning rate, threshold) should be named and documented, not positional magic.

## Rolling window sizes

| Size | Location | What it buffers |
|------|----------|-----------------|
| 500 | `portfolio.rs:163-165` | equity_at_trade, trade_returns rolling window |
| 200 | `enterprise.rs` flip_zone_rolling_cap | Flip zone win tracking |
| 20 | `portfolio.rs:145` | Completed drawdowns buffer |
| 5000 | `enterprise.rs` mgr_resolved cap | Manager resolved predictions |

**Why bad:** arbitrary buffer sizes. Why 500, not 200 or 1000?

**Fix:** derive from recalib_interval. The buffer should span N recalibration cycles to capture regime transitions.

## Window sampler bounds

| Value | Location | What it means |
|-------|----------|---------------|
| 12 | `enterprise.rs:230`, `window_sampler.rs` | Min window (1 hour at 5m) |
| 2016 | `enterprise.rs:230`, `window_sampler.rs` | Max window (7 days at 5m) |

**Why:** 12 = shortest meaningful technical pattern. 2016 = 7 × 288 (one week of 5m candles). Derivable from candle granularity but not documented.

**Generalist fixed window:** The generalist observer uses `WindowSampler::new(seed, 48, 48)` — a degenerate sampler that always returns 48. The specialists explore [12, 2016] and discover their own scale. The generalist is anchored. SCRUTINIZE: should the generalist also explore? Its cross-vocabulary insight might be scale-dependent. A "full" profile at window=200 thinks different thoughts than at window=48. The fixed window may be suppressing the generalist's potential. Consider: make it a seventh observer with a sampled window alongside the fixed-window sixth.

## Decay parameters

| Value | Location | What it controls |
|-------|----------|------------------|
| 0.999 | CLI default | Journal accumulator decay per candle |
| 0.004 | `enterprise.rs:396` | Adapting mode decay offset |
| 0.990 | `enterprise.rs:396` | Adapting mode decay floor |
| 0.999/0.001 | `portfolio.rs:154` | Peak equity smoothing |

**Why bad:** 0.004 offset and 0.990 floor are not derived. The peak equity smoothing uses a different constant than the journal decay.

## Phase transition thresholds

| Value | Location | What it gates |
|-------|----------|---------------|
| 500 observations | `portfolio.rs:304` | Tentative → Confident |
| 200 observations | `portfolio.rs:305` | Confident → Tentative demotion |
| 1000 candles | CLI observe_period | Observe → Tentative |

**Why bad:** these are about "enough data to trust." The answer depends on dims, recalib_interval, and the conviction distribution — not a fixed count.

---

*"Every magic value is an expert waiting to be born."* — BOOK.md
