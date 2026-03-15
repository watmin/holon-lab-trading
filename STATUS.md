# Holon Lab: Trading — Status

> Single source of truth for what's done, what's blocked, and what's next.
> Update this on every meaningful commit.

---

## Current State

**Git:** `main`  
**Tests:** 155 passing (last clean run: 2026-03-15)  
**Blocker:** none — ready to pull real BTC data and run geometry validation.

---

## Module Status

| Module | Status | Tests | Notes |
|--------|--------|-------|-------|
| `features.py` | ✅ complete | 35 | `compute_indicators()` + `compute_candle_row()` added; DMI div-by-zero fixed |
| `encoder.py` | ✅ complete | 30 | Window-snapshot; `encode_walkable_striped`; stripe-aware `build_surprise_profile` |
| `tracker.py` | ✅ complete | 26 | BUY/SELL/HOLD math, SQLite, Sharpe/drawdown |
| `darwinism.py` | ✅ complete | 22 | EMA reward/punish, pruning, save/load |
| `feed.py` | ✅ complete | 10 | Window math, episode logic, replay, next_close |
| `harness.py` | ✅ complete | 9 | StripedSubspace; score-first; stripe attribution; save_dir |
| `system.py` | ✅ complete | 0 | Two-phase orchestrator; StripedSubspace wired |
| `scripts/validate_geometry.py` | ✅ complete | 0 | Striped encoder; 4 gate experiments; passes on synthetic |
| `scripts/report.py` | ✅ complete | 0 | Read-only CLI: equity, Sharpe, feature rankings |

---

## Architecture: Window Snapshot + StripedSubspace

The encoder produces a **deeply nested per-candle walkable dict** (t0...t11 + time block),
encoded via `client.encoder.encode_walkable_striped(walkable, n_stripes=8)` into 8 stripe
vectors of dim=1024 each (8192 effective dim).

**244 total leaf bindings** — 20 fields/candle × 12 candles + 4 time leaves.  
~30 bindings/stripe (measured: min=26, max=34).

`StripedSubspace.residual_profile()` tells you *which candle slot + indicator group* drove
the anomaly. `anomalous_component(stripe_vecs, hot_stripe)` gives the out-of-subspace
vector for per-field cosine attribution.

See `HOLON_CONTEXT.md` for full rationale and API gotchas.

---

## Known Holon API Facts

| Thing | Correct |
|-------|---------|
| HolonClient constructor | `HolonClient(dimensions=4096)` |
| `encode_walkable_striped` location | `client.encoder.encode_walkable_striped(walkable, n_stripes=N)` — NOT `client.` |
| StripedSubspace constructor | `StripedSubspace(dim=1024, k=16, n_stripes=8)` |
| StripedSubspace update | `subspace.update(stripe_vecs)` — returns scalar RSS residual |
| StripedSubspace residual | `subspace.residual(stripe_vecs)` — non-updating |
| Residual profile | `subspace.residual_profile(stripe_vecs)` — array of per-stripe residuals |
| Anomalous component | `subspace.anomalous_component(stripe_vecs, hot_stripe_idx)` |
| Stripe assignment | `client.encoder.field_stripe(fqdn_path, n_stripes)` — FNV-1a, deterministic |
| Encoder dimensions | `client.encoder.vector_manager.dimensions` |
| Bipolar cosine identity | `np.array_equal(v, v)` — cosine ≠ 1.0 in bipolar {-1,0,1} space |
| Feed sizing rule | Provide `LOOKBACK_CANDLES + WINDOW_CANDLES` rows to encoder |

---

## Next Steps (in order)

### Step 1 — Download historical BTC data (one-time, ~10 min)
```bash
cd holon-lab-trading
../scripts/run_with_venv.sh python -c "
from trading.feed import HistoricalFeed
HistoricalFeed().ensure_data()
print('Done')
"
```
Produces `data/btc_5m.parquet` (~2 years, ~210k candles). Verify >50MB.

### Step 2 — Run geometry validation gate on real data
```bash
../scripts/run_with_venv.sh python scripts/validate_geometry.py \
    --parquet data/btc_5m.parquet --dim 1024 --stripes 8 --window 12
```
**Gate criteria — all must pass before running discovery harness:**
- Identity: same window → identical stripe vectors
- Proximity: adjacent windows closer than distant windows
- Regime separation: t-test p < 0.05 (within > cross)
- Subspace surprise: `StripedSubspace` flags volatile period as anomalous

If subspace surprise is INFO (familiar ok, novel doesn't cross), sweep `--window 6 12 24`
to find the configuration where novel does cross threshold.

### Step 3 — Run discovery harness (~30 min on 2 years of data)
```bash
../scripts/run_with_venv.sh python -c "
from trading.harness import DiscoveryHarness
h = DiscoveryHarness()
h.run(num_episodes=100, episode_length=500)
"
```
Produces:
- `data/seed_engrams.json` — seed memory bank for live system
- `data/feature_weights.json` — initial Darwinism weights
- `data/discovery_log.csv` — full decision log

Inspect feature ranking:
```bash
../scripts/run_with_venv.sh python scripts/report.py
```

### Step 4 — Start live system (24/7)
```bash
../scripts/run_with_venv.sh python trading/system.py
```
Let it run for 48h minimum before drawing conclusions.
First 6h is warm-up — `StripedSubspace` threshold still calibrating.

---

## Open Questions / Experiments to Run

- **Optimal window?** Default is 12 candles (60 min). The geometry validation gate's
  `--window 6 12 24` sweep will answer this empirically via engram quality metrics.
- **k selection:** Default k=16 per stripe (128 total). Plot per-stripe residual variance
  vs k on real data to find the knee.
- **Engram action label:** All minted engrams start as "HOLD". Should we label based on
  next-candle direction at mint time? Would seed the system with directional signal earlier.
- **Library matching on stripe[0]:** Currently uses first stripe vec as the match key.
  Better approach: store all stripe vecs in engram and match on RSS across stripes.
- **Darwinism with nested paths:** `update_weights()` now takes flat keys but the encoder
  uses nested field paths (e.g. `t0.macd.hist`). The Darwinism→weight gating bridge needs
  a redesign once we have real data to know which fields actually matter.

---

## Lessons Captured

See `HOLON_CONTEXT.md` for the full list. Key ones:

1. `encode_walkable_striped` is on `client.encoder`, NOT `client` — AttributeError otherwise
2. `LOOKBACK_CANDLES + WINDOW_CANDLES` rows required — not just `LOOKBACK_CANDLES`
3. DMI/ADX division-by-zero on flat price series — guard `tr_smooth=0` with `.replace(0, nan)`
4. Score before update — `residual()` THEN `update()`, never reversed
5. Bipolar MAP cosine — use `np.array_equal` for identity, cosine only for relative comparison
6. `StripedSubspace.threshold` is inf until all stripes have enough observations (k+1 each)
7. Grok Code (the wrong model) partially implemented this plan and left things broken —
   always verify test suite passes before treating work as done
