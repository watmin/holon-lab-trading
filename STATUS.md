# Holon Lab: Trading — Status

> Single source of truth for what's done, what's blocked, and what's next.
> Update this on every meaningful commit.

---

## Current State

**Git:** `main`  
**Tests:** 164 passing (last clean run: 2026-03-15)  
**Data:** `data/btc_5m_raw.parquet` — 652,608 candles, Jan 2019 – Mar 2025 ($3,366–$108,987)  
**Geometry gate:** ✅ PASSED — BUY t=8.39 p≈0, SELL t=4.91 p≈0  
**Seed engrams:** `data/seed_engrams.json` — 50 minted (25 BUY + 25 SELL), thin/individual  
**Full loop:** ✅ PROVEN — 500-step replay (17ms/decision), critic fires + ships, BUY/SELL decisions post-calibration  
**Blocker:** none — ready to wire LiveFeed to OKX and deploy

---

## Module Status

| Module | Status | Tests | Notes |
|--------|--------|-------|-------|
| `features.py` | ✅ complete | 35 | `compute_indicators()` + `compute_candle_row()`; DMI div-by-zero fixed |
| `encoder.py` | ✅ complete | 30 | Window-snapshot; `encode_walkable_striped`; `encode_from_precomputed()`; `build_surprise_profile` |
| `tracker.py` | ✅ complete | 26 | BUY/SELL/HOLD math, SQLite, Sharpe/drawdown |
| `darwinism.py` | ✅ complete | 22 | EMA reward/punish, pruning, save/load |
| `feed.py` | ✅ complete | 13 | ReplayFeed (full-speed historical, no sleep); LiveFeed → OKX |
| `harness.py` | ✅ complete | 9 | StripedSubspace; score-first; stripe attribution; save_dir |
| `system.py` | ✅ complete | 9 | Two-phase orchestrator; auto-calibrating match_threshold; full loop proven |
| `scripts/fetch_btc.py` | ✅ complete | 0 | OKX fetch, checkpoint every 30k candles, resume on crash |
| `scripts/label_reversals.py` | ✅ complete | 0 | find_peaks labeling + correct subspace-residual geometry gate |
| `scripts/validate_geometry.py` | ✅ complete | 0 | Striped encoder; 4 gate experiments |
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
| StripedSubspace constructor | `StripedSubspace(dim=1024, k=32, n_stripes=8)` — K=32 is quality lever, not DIM |
| StripedSubspace update | `subspace.update(stripe_vecs)` — returns scalar RSS residual |
| StripedSubspace residual | `subspace.residual(stripe_vecs)` — non-updating |
| Residual profile | `subspace.residual_profile(stripe_vecs)` — array of per-stripe residuals |
| Anomalous component | `subspace.anomalous_component(stripe_vecs, hot_stripe_idx)` |
| Stripe assignment | `client.encoder.field_stripe(fqdn_path, n_stripes)` — FNV-1a, deterministic |
| Encoder dimensions | `client.encoder.vector_manager.dimensions` |
| Bipolar cosine identity | `np.array_equal(v, v)` — cosine ≠ 1.0 in bipolar {-1,0,1} space |
| Feed sizing rule | Provide `LOOKBACK_CANDLES + WINDOW_CANDLES` rows to encoder |
| Fast batch encoding | `encoder.encode_from_precomputed(df_ind_slice)` — skips indicator recomputation |

---

## Engram Strategy: Thin → Regime → Federated

The key architectural decision, informed by Holon geometry and the DDoS lab's federated
learning design. Three layers, each building on the last:

### Layer 1 — Thin seed engrams (current: 50)
Each trained on one reversal event ±3 bars (7 samples). CCIPCA hasn't stabilized — `threshold`
is unreliable at this count. These are starting points, not final memories. The geometry gate
proved the *class* is separable (t≈8 on 75 samples); individual 7-sample engrams are much
noisier but provide a starting seed for the live system.

### Layer 2 — Regime engrams (AsyncCritic's job)
The live system mints new thin engrams continuously. The AsyncCritic periodically:
1. **Clusters** thin engrams by mutual residual — `engram_A.residual_striped(mean_of_engram_B)`
   low → they've learned the same manifold → redundant
2. **Consolidates** each cluster: re-train one `StripedSubspace` on the union of all windows
   from that cluster's engrams → one thick regime engram (50–200 samples → stable threshold)
3. **Prunes** the thin originals, keeps the consolidated one
4. **Labels** consolidated engrams by the plurality action (BUY/SELL/HOLD) of their cluster

K regime engrams emerge from data, not from a hardcoded count. K will differ for BUY vs SELL
and will drift as market conditions change — that's the self-tuning behavior.

### Layer 3 — Federated consolidation (future: N instances → HQ → fleet)
Because every Holon node shares the same vector space (hash-function codebook, no
distribution required), regime engrams from N independent trading instances are directly
comparable at HQ:

```
Instance A  ──engrams──▶  HQ Critic
Instance B  ──engrams──▶  HQ Critic  →  merged library  →  all instances
Instance C  ──engrams──▶  HQ Critic
```

HQ runs the same clustering algorithm across all incoming engrams regardless of source.
`residual_striped` is the merge criterion: if instance A's regime engram already explains
instance B's reversal pattern (low residual), B's engram adds nothing — prune it. If B's
engram has high residual against all of A's engrams, it represents a genuinely new regime
the fleet hasn't seen — keep it and distribute.

No gradient averaging (FedAvg). No model retraining. Subspace snapshots ship as JSON,
load on any node, operate immediately. The coordination-free property means HQ never needs
to know what data each instance saw — the geometry is self-describing.

**Open question:** Should HQ also run a meta-subspace over the residual profiles of all
incoming engrams? This would let it detect "the fleet is collectively seeing something new"
before any individual instance has enough samples to mint a stable regime engram.

---

## Next Steps (in order)

### Step 1 — AsyncCritic consolidation loop
Implement the cluster → consolidate → prune cycle in `system.py`'s `AsyncCritic`:
- Mutual residual matrix across all striped engrams in library
- Hierarchical clustering (single-linkage on residual distance)
- Consolidation: re-train StripedSubspace on member windows
- Requires storing raw stripe_vecs at mint time (currently discarded after minting)

**Decision needed:** Where do we store the raw training windows for post-hoc consolidation?
Options: SQLite (alongside tracker), separate parquet per engram, in-memory only (lost on restart).

### Step 2 — Wire AsyncCritic to labeled reversal data
The critic currently has no access to the historical labels. Feed it `reversal_labels.parquet`
so it can score each engram against known BUY/SELL ground truth during the consolidation pass.

### Step 3 — Start live system against paper trading
```bash
../scripts/run_with_venv.sh python -u trading/system.py 2>&1 | tee /tmp/trading_live.txt
```
Let it run for 48h minimum. First 6h is warm-up.

### Step 4 — Federated HQ design (future)
Design the HQ ingestion endpoint and fleet distribution protocol. The encoding layer
already supports this (coordination-free). The missing piece is the transport and
the HQ consolidation scheduler.

---

## Open Questions

- **Raw window storage for consolidation:** SQLite rows? Parquet per-engram? Need to
  persist the encoded stripe_vecs that produced each engram so the critic can re-train.
- **Meta-subspace at HQ:** OnlineSubspace over residual profiles of all fleet engrams —
  would detect "the fleet is collectively seeing something new" before any single instance
  has enough samples.
- **Darwinism with nested paths:** `update_weights()` takes flat keys but encoder uses
  nested paths (e.g. `t0.macd.hist`). Bridge needs redesign once real data shows which
  fields drive decisions.
- **Engram decay:** Should old regime engrams fade if the market regime changes?
  EMA on the `score` field already supports this — just need the critic to apply it.

---

## Lessons Captured

See `HOLON_CONTEXT.md` for the full list. Key ones:

1. `encode_walkable_striped` is on `client.encoder`, NOT `client` — AttributeError otherwise
2. `LOOKBACK_CANDLES + WINDOW_CANDLES` rows required — not just `LOOKBACK_CANDLES`
3. DMI/ADX division-by-zero on flat price series — guard `tr_smooth=0` with `.replace(0, nan)`
4. Score before update — `residual()` THEN `update()`, never reversed
5. Bipolar MAP cosine — use `np.array_equal` for identity, cosine only for relative comparison
6. `StripedSubspace.threshold` is inf until all stripes have enough observations (k+1 each)
7. Geometry gate: use subspace residuals, NOT pairwise cosine — pairwise cosine is the
   batch-017 centroid mistake; reversal windows from different price regimes have low
   bundle-to-bundle cosine but still share the same algebraic manifold
8. K dominates quality, DIM barely matters — K=32 at DIM=512 beats K=16 at DIM=4096
9. Per-row iloc assignment on large DataFrames is catastrophically slow — use vectorized
   iloc with an array of indices instead
