# Holon Lab: Trading — Status

> Single source of truth for what's done, what's blocked, and what's next.
> Update this on every meaningful commit.

---

## Current State

**Git:** `main` — 4 commits  
**Tests:** 143 passing (last clean run: 2026-03-15)  
**Blocker:** none.

---

## Module Status

| Module | Status | Tests | Notes |
|--------|--------|-------|-------|
| `features.py` | ✅ complete | 27 | All indicators, NaN-safe, deterministic |
| `encoder.py` | ✅ complete | 16 | LinearScale/LogScale routing, weight gating |
| `tracker.py` | ✅ complete | 26 | BUY/SELL/HOLD math, SQLite, Sharpe/drawdown |
| `darwinism.py` | ✅ complete | 22 | EMA reward/punish, pruning, save/load |
| `feed.py` | ✅ complete | 10 | Window math, episode logic, replay, next_close |
| `harness.py` | ✅ complete | 9 | Score-first, engram minting, EMA scoring |
| `system.py` | ✅ complete | 0 | Two-phase orchestrator (live system, not unit-testable) |
| `encoder.py` `build_surprise_profile()` | ✅ complete | 8 | Field attribution via leaf_binding + anomalous_component |
| Darwinism wiring | ✅ complete | 10 | update() called in harness loop and RealTimeConsumer |
| `scripts/report.py` | ✅ complete | 0 | Read-only status CLI: equity, Sharpe, feature rankings |
| `scripts/validate_geometry.py` | ✅ complete | 0 | 5 geometry experiments, all passing on synthetic data |

---

## Known Holon API Facts (learned from real calls)

| Thing | Correct | Wrong (skeleton had) |
|-------|---------|----------------------|
| HolonClient constructor | `HolonClient(dimensions=4096)` | `HolonClient(dim=4096)` |
| EngramLibrary constructor | `EngramLibrary(dim=4096)` | same — correct |
| OnlineSubspace constructor | `OnlineSubspace(dim=4096, k=64)` | same — correct |
| EngramLibrary.add metadata | `library.add(name, sub, None, action="BUY", score=0.0)` | passed as dict |
| Engram.metadata access | `eng.metadata["action"]` — plain dict | same |
| Encoder dimensions | `client.encoder.vector_manager.dimensions` | `client.encoder.dimensions` |
| Bipolar cosine identity | `np.array_equal(v, v)` not `cosine == 1.0` | assumed cosine=1 |
| RSI all-gains | returns `100.0` (fixed in features.py) | returned `50.0` |
| score-first pattern | `residual()` THEN `update()` | `update()` then threshold check |

---

## Next Steps (in order)

### Step 1 — Unblock tests after holon port lands
```bash
cd holon-lab-trading
.venv/bin/pytest tests/ -q
```
Expected: 124 pass. If new API changes broke anything, fix and commit.

### Step 2 — Download historical data (one-time)
```bash
./scripts/run_with_venv.sh python -c "
from trading.feed import HistoricalFeed
HistoricalFeed().ensure_data()
"
```
Produces `data/btc_5m.parquet` (~2 years, ~210k candles). Takes ~10 min.
Verify: `data/btc_5m.parquet` exists and is >50MB.

### Step 3 — Validate structural similarity empirically ✅ DONE
`scripts/validate_geometry.py` — passes on synthetic data, designed to run on real parquet too.

Key findings from building this:
- **Identity:** same window → identical vector ✓ (cosine ≠ 1.0 in bipolar space — use array_equal)
- **Proximity:** adjacent windows are statistically more similar than distant windows ✓
- **Regime separation:** within-regime cosine > cross-regime at p<0.0001 ✓
- **Weight gating:** zeroing MACD fields changes encoding ✓
- **Subspace surprise:** familiar < threshold (always ✓); novel *directionally* higher
  but `sigma_mult=3.5` needs real BTC variance to fully calibrate (runs with `--parquet`)

Critical insight captured: **LogScale compresses absolute price differences — it's volatility
regime shift, not price level, that drives indicator shape and thus subspace residual.**

### Step 3b — Wire Darwinism + field attribution ✅ DONE
- `OHLCVEncoder.build_surprise_profile(anomalous)` — `leaf_binding + abs(cosine)` per field
- Harness scoring loop calls `darwinism.update()` with surprise profile on every step
- `RealTimeConsumer` does the same with the realized return from the previous candle
- `scripts/report.py` — read-only CLI showing equity, Sharpe, drawdown, feature rankings

### Step 4 — Run geometry validation on real data
```bash
./scripts/run_with_venv.sh python scripts/validate_geometry.py --parquet data/btc_5m.parquet --dim 4096
```
Expect: subspace surprise experiment to fully pass (threshold calibrates from real BTC variance).

### Step 5 — Wire Darwinism into harness scoring
Currently `FeatureDarwinism` is instantiated in the harness but `update()` is never
called during discovery. The `anomalous_component` from `OnlineSubspace` gives
per-field surprise; that needs to flow into `darwinism.update()`.

Changes needed in `harness.py`:
- After `subspace.update(vec)`, compute `anomalous = subspace.anomalous_component(vec)`.
- Build a `surprise_profile: dict[str, float]` by unbinding field roles from `anomalous`.
- Pass to `darwinism.update(surprise_profile, realized_return, action)`.

This requires understanding how `anomalous_component` relates to field roles —
read `HOLON_CONTEXT.md` section "Field Attribution" before touching this.

### Step 5 — Run discovery harness (offline, ~10-30 min)
```bash
./scripts/discover.sh
```
Produces:
- `data/seed_engrams.json` — seed memory bank for live system
- `data/feature_weights.json` — initial Darwinism weights
- `data/discovery_log.csv` — full decision log

Inspect results:
```bash
./scripts/run_with_venv.sh python -c "
from trading.darwinism import FeatureDarwinism
d = FeatureDarwinism.load('data/feature_weights.json')
print(d.report())
"
```
Expected: non-trivial ranking (not all weights equal).

### Step 6 — Build `scripts/report.py`
Quick read-only CLI to inspect a running (or stopped) system:
```
=== Holon Lab Trading Report ===
Uptime          : 14.2 hours
Equity          : $10,847 (+8.5%)
Sharpe          : 1.23
Max Drawdown    : 4.1%
Win Rate        : 52%
Trades          : 41
Decisions       : 168
Engrams         : 23

=== Feature Importance (Algebraic Darwinism) ===
  macd_hist          importance=0.712  weight=1.82  [active]
  rsi                importance=0.634  weight=1.41  [active]
  adx                importance=0.201  weight=0.34  [active]
  bb_width           importance=0.118  weight=0.12  [PRUNED]
  ...
```

### Step 7 — Start live system (24/7)
```bash
./scripts/run_live.sh
```
Let it run for 48h minimum before drawing conclusions.
The first 6h is "warm-up" — subspace is still calibrating threshold.

---

## Open Questions / Experiments to Run

- **Does window size matter?** 12 candles (60 min) vs 40 candles (200 min) — 
  do larger windows produce more stable regime detection?
- **k selection:** default k=32 in harness. Plot residual vs k on real data to
  find the knee empirically.
- **Engram action label:** currently all minted engrams start as "HOLD". 
  Should we label based on next-candle direction at mint time?
- **Regime-aware minting:** only mint during high-volatility windows (ATR > threshold)?
  Might reduce noise engrams.

---

## Lessons Captured

See `HOLON_CONTEXT.md` for the full list. Key ones that bit us:

1. `HolonClient(dimensions=...)` — not `dim=`
2. Score before update — `residual()` THEN `update()`, never reversed
3. Bipolar MAP cosine — use `np.array_equal` for identity, cosine only for relative comparison
4. RSI with all-gains returns 100 (fixed); was returning 50 (divide-by-zero guard was wrong)
5. `EngramLibrary.add()` takes metadata as `**kwargs`, not a positional dict
