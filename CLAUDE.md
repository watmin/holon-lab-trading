# CLAUDE.md — holon-lab-trading

The enterprise. A self-organizing trading system built from six primitives.

## Build & Run

```bash
./enterprise.sh build                                    # compile (release)
./enterprise.sh run --max-candles 5000 --asset-mode hold  # quick run
./enterprise.sh test 100000 --asset-mode hold --name my-run  # benchmark → runs/
./enterprise.sh kill                                      # kill switch
```

Kill switch file: `touch trader-stop`

Build output goes to `.build/` (gitignored). Run ledgers and logs go to `runs/` (gitignored). Never delete run artifacts — they are training data for us.

## Architecture

Six primitives: atom, bind, bundle, cosine, journal, curve.
Two templates: prediction (Journal) and reaction (OnlineSubspace).
One tree: observers → manager → treasury.

**Observers** (leaves) predict direction from candle data at sampled time scales. Seven observers: five specialists (momentum, structure, volume, narrative, regime), one full generalist, one classic generalist (original 8-method vocabulary, for A/B testing). Each has its own Journal, own discriminant, own window.

**Manager** (branch) reads observer opinions encoded as Holon vectors. Learns which configurations of expert agreement predict profitability. Does not see candles. Does not encode market data. Thinks in expert opinions.

**Risk branches** measure portfolio health via OnlineSubspace anomaly detection. Five domains: drawdown, accuracy, volatility, correlation, panel. Risk manager (Template 1) learns Healthy/Unhealthy from branch ratios.

**Treasury** (root) holds assets. Deploys capital only to proven experts. The ledger records everything.

## Module Layout

```
src/bin/enterprise.rs     — the heartbeat (orchestrates, doesn't define)
src/bin/build_candles.rs  — parquet → SQLite candle builder (legacy pipeline)
src/lib.rs                — crate root, re-exports
src/state.rs              — EnterpriseState, CandleContext, TradePnl, SharedState
src/event.rs              — Event enum (Candle, Deposit, Withdraw)
src/indicators.rs         — streaming IndicatorBank (all TA from raw OHLCV)
src/thought/
  mod.rs                  — ThoughtEncoder + eval methods (Layer 0: candle → thoughts)
  pelt.rs                 — PELT changepoint detection
src/market/
  mod.rs                  — Lens enum, OBSERVER_LENSES
  desk.rs                 — Desk struct (the fold — on_candle, positions, learning)
  manager.rs              — manager encoding (ManagerAtoms, ManagerContext, encode_manager_thought)
  observer.rs             — Observer struct (resolve, proof gate, engram)
  exit.rs                 — ExitAtoms + encode_exit_thought
src/risk/
  mod.rs                  — RiskBranch, RiskAtoms, 5 specialist encoders + generalist
  manager.rs              — RiskManager (Template 1 Journal: Healthy/Unhealthy)
src/vocab/
  mod.rs                  — Fact enum, module registry
  oscillators.rs          — Williams %R, StochRSI, UltOsc, multi-ROC
  flow.rs                 — OBV, VWAP, MFI, buying/selling pressure
  persistence.rs          — Hurst, autocorrelation, ADX zones
  regime.rs               — KAMA-ER, choppiness, DFA, variance ratio, TD count, Aroon, fractal dim, entropy
  divergence.rs           — RSI divergence via PELT structural peaks
  ichimoku.rs             — cloud zone, TK cross (streaming values on Candle)
  stochastic.rs           — %K/%D zones and crosses
  fibonacci.rs            — retracement level detection
  keltner.rs              — channel position, BB position, squeeze
  momentum.rs             — CCI zones
  price_action.rs         — inside/outside bars, gaps, consecutive runs
  timeframe.rs            — 1h/4h structure + narrative + inter-timeframe agreement
src/journal.rs            — re-export of holon::Journal
src/candle.rs             — Candle struct (computed indicators per candle)
src/ledger.rs             — run DB schema + candle_snapshot + trade_facts
src/portfolio.rs          — Portfolio struct (equity, phase, drawdown tracking)
src/position.rs           — Pending, ManagedPosition, PositionEntry
src/treasury.rs           — asset map (claim/release/swap), Rate newtype
src/sizing.rs             — Kelly criterion, conviction threshold, signal weight
src/window_sampler.rs     — deterministic log-uniform window sampling
```

## Principles

**The binary orchestrates. Modules define.** enterprise.rs calls functions. It doesn't define structs, atoms, or encoding logic inline. When encoding appears in the heartbeat, a thought has escaped its home.

**One encoding path.** Manager encoding lives in `market/manager.rs`. One function (`encode_manager_thought`), called at prediction and resolution. The encoding IS the thought — it must be identical everywhere.

**The enterprise vocabulary.** Names match the architecture:
- Observer (not expert, not trader) — they perceive, they don't decide
- Portfolio (not Trader) — portfolio state, not a person
- Ledger (not run_db) — the ledger records, it doesn't decide
- Candle (not db) — it holds computed indicators
- Desk (not trader) — one desk per asset pair, owns the fold

**Flat until siblings arrive.** Don't create `foo/mod.rs` until `foo/bar.rs` needs to exist. Grow the tree when the leaves arrive.

**Never average a distribution.** No fixed parameters derived from historical percentiles. Let values breathe with the market. ATR, conviction, regime — use the current state, not averaged history.

## Data

- `data/btc_5m_raw.parquet` — 652,608 5-minute BTC candles (Jan 2019–Mar 2025), raw OHLCV
- `runs/` — run ledgers and logs (append-only, never delete)
- `docs/verification-sequence.md` — leaves-to-root diagnostic checklist

## Specifications

The `wat/` directory is the source of truth. The Rust in `src/` implements it.

When adding or changing behavior: update the wat first, then implement in Rust. When code and spec diverge, the wat is right unless the code discovered something the spec missed — then update the wat to match the discovery. Never let them drift silently.

## Wards

Spells that defend against bad thoughts. Run `/wards` to cast them all.

- `/sever` — cuts tangled threads. Braided concerns, misplaced logic, duplicated encoding.
- `/reap` — harvests what no longer lives. Dead code, unused structs, write-only fields.
- `/scry` — divines truth from intention. Spec vs code divergences.
- `/gaze` — sees the form. Names that mumble, functions that don't fit, comments that lie.
- `/forge` — tests the craft. Values not places, types that enforce, functions that compose.
- `/temper` — quiets the fire. Redundant computation, loop-invariant work, allocation waste.
- `/assay` — measures substance. Is the spec a program or a description? Expression density.

## Standard Test

100k candles is the benchmark. 500 for smoke tests. 652k for full validation.

```bash
./enterprise.sh test 100000 --asset-mode hold --swap-fee 0.0010 --slippage 0.0025 --name benchmark
```
