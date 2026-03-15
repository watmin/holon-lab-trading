# Holon Lab: Trading — Battle Plan

> **Before writing any code that touches holon:** read [`HOLON_CONTEXT.md`](./HOLON_CONTEXT.md).
> The common VSA/HDC literature is deficient in specific ways. Holon has solved problems
> the field hasn't published solutions to. When in doubt, consult
> `../algebraic-intelligence.dev/src/content/docs/blog/primers/` — that is the ground truth.

## Goal

Prove that the holon Python library (as-is, zero modifications) can power a
self-tuning BTC paper trader. This is a **proving ground**, not a library
extension. If something can't be done with the public API, articulate *why*
before touching holon core.

The system encodes 5-minute OHLCV candles + technical indicators into
hypervectors, learns market-regime manifolds via `OnlineSubspace`, mints
engrams for recognized patterns, and autonomously refines its memory bank
through a 2-phase feedback loop.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  holon (untouched)                   │
│  kernel: encode_walkable, bind, bundle, scalars      │
│  memory: OnlineSubspace, Engram, EngramLibrary       │
│  highlevel: HolonClient                              │
└──────────────────────┬──────────────────────────────┘
                       │ pip install -e ../
┌──────────────────────▼──────────────────────────────┐
│              holon-lab-trading/trading/               │
│                                                      │
│  features.py ─── technical indicators (pure pandas)  │
│  encoder.py  ─── OHLCV → hypervector (uses holon)   │
│  feed.py     ─── live + historical BTC data (ccxt)   │
│  tracker.py  ─── paper trading + metrics (sqlite)    │
│  harness.py  ─── brute-force engram discovery        │
│  darwinism.py ── per-field reward/punishment loop    │
│  system.py   ─── 2-phase orchestrator               │
└──────────────────────────────────────────────────────┘
```

---

## Modules (build in this order)

### 1. `trading/features.py` — Technical Feature Factory

**Depends on:** pandas, numpy (no holon imports)

Compute technical indicators from an OHLCV DataFrame. Return a flat
`dict[str, float]` ready for `encode_walkable`.

Indicators to implement:
- SMA (configurable periods — default 10 and 40 candles for 50m/200m equiv)
- Bollinger Bands: mid, upper, lower, width (20-period, 2σ)
- MACD: line, signal, histogram (12/26/9 scaled to 5m)
- ADX proxy (simplified from true range)
- RSI (14-period scaled)
- ATR (14-period scaled)
- Volume regime: current vol / rolling mean vol
- Returns: last-N pct_change values as a list (for ngram encoding)
- Cyclic time features: hour-of-day (sin/cos), day-of-week (sin/cos)

Requirements:
- Must handle NaN gracefully (early candles). Fill with 0.0 or neutral.
- Must work on any DataFrame with columns: timestamp, open, high, low, close, volume.
- Pure functions, no state, no side effects.

```python
class TechnicalFeatureFactory:
    def compute(self, df: pd.DataFrame) -> dict[str, float]: ...
    def compute_returns(self, df: pd.DataFrame, periods: int = 5) -> list[float]: ...
```

### 2. `trading/encoder.py` — OHLCV Encoder

**Depends on:** features.py, holon (HolonClient, encode_walkable)

Takes a DataFrame window and feature weights, produces a hypervector.

```python
class OHLCVEncoder:
    def __init__(self, client: HolonClient, feature_weights: dict[str, float] | None = None): ...
    def encode(self, df: pd.DataFrame) -> np.ndarray: ...
    def update_weights(self, weights: dict[str, float]) -> None: ...
```

Design:
- Call `TechnicalFeatureFactory.compute()` to get indicators.
- Build a walkable dict using `$linear` for price-derived features, `$log` for
  volume/ATR, `$time` for cyclic features.
- Weight each field by `feature_weights[field]` before encoding (multiply the
  scalar value). Start with uniform weights = 1.0.
- Encode recent returns as an ngram sequence (via `$mode: ngram` or manual
  positional binding) — this captures temporal pattern shape.
- Return the encoded vector.

### 3. `trading/feed.py` — Data Feed

**Depends on:** ccxt, pandas (no holon imports)

Two classes sharing the same generator interface:

```python
class LiveFeed:
    def __init__(self, symbol: str = "BTC/USDT", timeframe: str = "5m", window: int = 200): ...
    def stream(self) -> Iterator[pd.DataFrame]: ...

class HistoricalFeed:
    def __init__(self, parquet_path: str = "data/btc_5m.parquet",
                 symbol: str = "BTC/USDT", days: int = 730): ...
    def ensure_data(self) -> None: ...
    def random_episode(self, length: int = 200, window: int = 12) -> Iterator[pd.DataFrame]: ...
    def replay(self, start_idx: int, length: int, window: int = 12) -> Iterator[pd.DataFrame]: ...
```

- `LiveFeed.stream()` yields a DataFrame of the last N candles every 5 minutes,
  aligned to candle boundaries.
- `HistoricalFeed.ensure_data()` downloads and caches to parquet (first run only).
- `HistoricalFeed.random_episode()` picks a random offset and yields sliding
  windows — this is the "rewind to random historical offset, give the machine
  60 minutes of knowledge" approach.

### 4. `trading/tracker.py` — Experiment Tracker

**Depends on:** pandas, sqlite3, numpy (no holon imports)

Paper trading engine with full audit trail.

```python
class ExperimentTracker:
    def __init__(self, initial_usdt: float = 10000.0,
                 fee: float = 0.001, slippage_bp: float = 5,
                 db_path: str = "data/experiment.db"): ...
    def record(self, action: str, confidence: float, price: float,
               latency_ms: float = 0.0, used_engrams: list[str] | None = None,
               notes: str = "") -> dict: ...
    def equity(self) -> float: ...
    def summary(self) -> dict: ...
    def export_csv(self, path: str = "data/experiment_log.csv") -> None: ...
```

- Simulates BUY/SELL/HOLD with configurable fees + slippage.
- Logs every decision to SQLite: ts, action, confidence, price, equity,
  simulated_pnl, latency_ms, used_engrams (JSON list), notes.
- Rolling metrics: Sharpe (annualized from 5m), max drawdown, win rate,
  profit factor, total return.
- `summary()` returns the current metric snapshot.

### 5. `trading/harness.py` — Discovery Harness

**Depends on:** all above + holon.memory (OnlineSubspace, EngramLibrary)

Brute-force engram discovery via historical replay.

```python
class DiscoveryHarness:
    def __init__(self, dim: int = 4096, k: int = 32,
                 initial_usdt: float = 10000.0): ...
    def run(self, num_episodes: int = 50, episode_length: int = 200,
            window_candles: int = 12) -> None: ...
    def results(self) -> dict: ...
```

Flow per episode:
1. `HistoricalFeed.random_episode()` → sliding windows.
2. For each window: `OHLCVEncoder.encode()` → probe `EngramLibrary.match()`.
3. If match (low residual) → use engram metadata for action.
4. If no match → `OnlineSubspace.update()` + check if surprising.
5. If surprising → `EngramLibrary.add()` (mint new engram).
6. Simulate forward one candle → score the engram by realized return.
7. After all episodes: save `data/seed_engrams.json` + `data/discovery_log.csv`.

### 6. `trading/darwinism.py` — Feature Darwinism

**Depends on:** holon.memory (EngramLibrary), pandas

Algebraic feature selection via reward/punishment.

```python
class FeatureDarwinism:
    def __init__(self, field_names: list[str], ema_alpha: float = 0.3,
                 prune_threshold: float = 0.2): ...
    def update(self, engram_surprise_profile: dict[str, float],
               realized_return: float, action: str) -> None: ...
    def get_weights(self) -> dict[str, float]: ...
    def pruned_fields(self) -> list[str]: ...
    def report(self) -> str: ...
```

- Tracks per-field importance as an EMA.
- Reward: field had low surprise AND decision was profitable → boost weight.
- Punish: field had high surprise OR decision lost money → decay weight.
- Fields below `prune_threshold` get excluded from encoding.
- `report()` prints a ranked table of field importance.

### 7. `trading/system.py` — Two-Phase Orchestrator

**Depends on:** all above

```python
class RealTimeConsumer:
    """Phase 1: live feed → encode → recall/mint → paper trade."""
    def __init__(self, encoder: OHLCVEncoder, library: EngramLibrary,
                 subspace: OnlineSubspace, tracker: ExperimentTracker,
                 darwinism: FeatureDarwinism): ...
    def run(self) -> None: ...

class AsyncCritic(threading.Thread):
    """Phase 2: background refinement every N minutes."""
    def __init__(self, library: EngramLibrary, tracker: ExperimentTracker,
                 darwinism: FeatureDarwinism, interval_minutes: int = 30): ...
    def run(self) -> None: ...

class TradingSystem:
    """One-command start: seeds from engrams, starts consumer + critic."""
    def __init__(self, engram_path: str = "data/seed_engrams.json"): ...
    def start(self) -> None: ...
```

Phase 1 (main thread):
- Consumes `LiveFeed.stream()`.
- Encodes each window → probes library.
- Match found (low residual) → deploy metadata action.
- No match + surprising → mint candidate engram.
- Logs everything to tracker (including used engram IDs + residuals).
- Every 10 minutes: check if critic shipped a newer engram version → hot-reload.

Phase 2 (daemon thread):
- Reads recent decisions from SQLite (last 48h).
- Scores engrams by realized outcomes (direction × return magnitude).
- Runs `FeatureDarwinism.update()` using surprise profiles.
- Prunes bottom 35% of engrams.
- Clones + mutates top engrams with small metadata perturbations (exploration).
- Saves versioned engram bank → consumer hot-reloads via atomic file rename.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Vector dimensions | 4096 | Python default, plenty for ~15 indicator fields |
| Subspace k | 32 | Enough for market regime manifold |
| Window size | 12 candles (60 min) | "Only ever sees a finite window" — per spec |
| Scoring | direction_match × abs(return) × (1 - surprise) | Rewards correct calls, penalizes confusion |
| Pruning rate | Keep top 65% | Aggressive enough to evolve, conservative enough to retain |
| Critic interval | 30 min | ~6 candles of new data per cycle |
| Hot-reload | Atomic rename (tmp → json) | Zero-downtime, no file corruption |
| Feature weighting | Multiplicative on scalar before encoding | Keeps geometry valid — just scales the field contribution |

---

## Holon API Surface Used (read-only, no modifications)

From `holon.highlevel.client`:
- `HolonClient(dim=4096)` — facade
- `client.encode_walkable(data)` — structured data → hypervector
- `client.similarity(a, b)` — cosine similarity

From `holon.memory.subspace`:
- `OnlineSubspace(dim, k)` — CCIPCA manifold learner
- `subspace.update(vec)` → residual
- `subspace.residual(vec)` — anomaly score without update
- `subspace.threshold` — self-calibrating boundary
- `subspace.anomalous_component(vec)` — out-of-manifold component
- `subspace.snapshot()` / `OnlineSubspace.from_snapshot()` — serialization

From `holon.memory.engram`:
- `EngramLibrary(dim)` — collection of engrams
- `library.add(name, subspace, surprise_profile, **metadata)` — mint
- `library.match(vec, top_k)` → `[(name, residual), ...]`
- `library.get(name)` → `Engram`
- `library.remove(name)` — prune
- `library.save(path)` / `EngramLibrary.load(path)` — ship

From `holon.kernel.walkable`:
- `LinearScale`, `LogScale`, `TimeScale` — scalar wrappers for `$linear`, `$log`, `$time` markers

---

## File Layout

```
holon-lab-trading/
├── PLAN.md              ← this file
├── README.md
├── requirements.txt
├── .gitignore
├── scripts/
│   ├── run_with_venv.sh
│   ├── discover.sh      ← runs harness
│   └── run_live.sh       ← starts 2-phase system
├── trading/
│   ├── __init__.py
│   ├── features.py       ← Module 1
│   ├── encoder.py        ← Module 2
│   ├── feed.py           ← Module 3
│   ├── tracker.py        ← Module 4
│   ├── harness.py        ← Module 5
│   ├── darwinism.py      ← Module 6
│   └── system.py         ← Module 7
├── tests/
│   ├── __init__.py
│   ├── test_features.py
│   ├── test_encoder.py
│   ├── test_tracker.py
│   └── test_harness.py
├── data/                 ← gitignored, runtime artifacts
│   └── .gitkeep
└── docs/
```

---

## Dependency Order

```
1. features.py     (pure pandas/numpy)
2. feed.py         (pure ccxt/pandas)       } can be built in parallel
3. tracker.py      (pure pandas/sqlite)     }
4. encoder.py      (depends on 1 + holon)
5. darwinism.py    (depends on holon.memory)
6. harness.py      (depends on 1-5)
7. system.py       (depends on all)
```

Modules 1, 2, 3 have zero holon dependencies — they're pure data plumbing.
Module 4 uses only `HolonClient.encode_walkable()` and walkable scalars.
Modules 5-7 add `OnlineSubspace` and `EngramLibrary`.

---

## Testing Strategy

- **Unit tests for features.py**: known OHLCV → known indicator values.
- **Unit tests for encoder.py**: verify encoded vectors have expected dimensionality,
  verify structurally similar windows produce high cosine similarity,
  verify different regimes produce low similarity.
- **Unit tests for tracker.py**: simulate BUY→SELL sequence, verify PnL math.
- **Integration test for harness.py**: run 3 episodes × 10 steps on synthetic
  data, verify engrams are minted, scored, and saved.
- **No tests for system.py initially** — that's the live orchestrator, tested by
  running it.

---

## Entry Points

```bash
# Step 1: Download historical data
./scripts/run_with_venv.sh python -c "from trading.feed import HistoricalFeed; HistoricalFeed().ensure_data()"

# Step 2: Discover seed engrams (offline, ~10 min)
./scripts/discover.sh

# Step 3: Run live self-tuning system (24/7)
./scripts/run_live.sh

# Step 4: Check feature importance after a few hours
./scripts/run_with_venv.sh python -c "
from trading.darwinism import FeatureDarwinism
import json
d = FeatureDarwinism.load('data/feature_weights.json')
print(d.report())
"
```

---

## Success Criteria

1. `encode_walkable` produces geometrically meaningful vectors from OHLCV data
   (similar market states → high cosine similarity).
2. `OnlineSubspace` learns a market-regime manifold and `residual()` correctly
   flags regime shifts.
3. Engrams minted during discovery generalize — they fire on similar patterns
   in unseen data.
4. The 2-phase loop improves metrics (Sharpe, win rate) over 48+ hours vs the
   first-hour baseline.
5. Feature Darwinism produces a non-trivial ranking (not all weights equal)
   after 24 hours.
6. **Zero changes to holon core.**
