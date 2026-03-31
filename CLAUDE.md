# CLAUDE.md — holon-lab-trading

The enterprise. A self-organizing BTC trading system built from six primitives.

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

**Observers** (leaves) predict direction from candle data at sampled time scales. Five profiles: momentum, structure, volume, narrative, regime. Each has its own Journal, own discriminant, own window discovered through experience.

**Manager** (branch) reads observer opinions encoded as Holon vectors. Learns which configurations of expert agreement predict profitability. Does not see candles. Does not encode market data. Thinks in expert opinions.

**Risk branches** measure portfolio health via OnlineSubspace anomaly detection. Five domains: drawdown, accuracy, volatility, correlation, panel.

**Treasury** (root) holds assets. Deploys capital only to proven experts. The ledger records everything.

## Module Layout

```
src/bin/enterprise.rs     — the heartbeat (orchestrates, doesn't define)
src/thought/
  mod.rs                  — ThoughtEncoder + eval methods (Layer 0: candle → thoughts)
  pelt.rs                 — PELT changepoint detection
src/market/
  mod.rs                  — shared market primitives (time encoding)
  manager.rs              — manager encoding (ManagerAtoms, ManagerContext, encode_manager_thought)
  observer.rs             — Observer struct
src/risk/
  mod.rs                  — RiskBranch struct
src/vocab/
  oscillators.rs          — Williams %R, StochRSI, UltOsc, multi-ROC
  flow.rs                 — OBV, VWAP, MFI, buying/selling pressure
  persistence.rs          — Hurst, autocorrelation, ADX zones
src/journal.rs            — the learning primitive (generic, no domain)
src/candle.rs             — Candle struct + SQLite loader
src/ledger.rs             — run DB schema (the ledger that counts)
src/portfolio.rs          — Portfolio struct (equity, phase, risk_branch_wat)
src/position.rs           — Pending, ExitObservation, ManagedPosition
src/treasury.rs           — asset map (claim/release/swap)
src/sizing.rs             — Kelly criterion
src/window_sampler.rs     — deterministic log-uniform window sampling
```

## Principles

**The binary orchestrates. Modules define.** enterprise.rs calls functions. It doesn't define structs, atoms, or encoding logic inline. When encoding appears in the heartbeat, a thought has escaped its home.

**One encoding path.** Manager encoding lives in `market/manager.rs`. One function (`encode_manager_thought`), called at prediction and resolution. The encoding IS the thought — it must be identical everywhere.

**The enterprise vocabulary.** Names match the architecture:
- Observer (not expert, not trader) — they perceive, they don't decide
- Portfolio (not Trader) — portfolio state, not a person
- Ledger (not run_db) — the ledger records, it doesn't decide
- Candle (not db) — it loads candles

**Flat until siblings arrive.** Don't create `foo/mod.rs` until `foo/bar.rs` needs to exist. Grow the tree when the leaves arrive.

**Never average a distribution.** No fixed parameters derived from historical percentiles. Let values breathe with the market. ATR, conviction, regime — use the current state, not averaged history.

## Data

- `data/analysis.db` — 652,608 5-minute BTC candles (Jan 2019–Mar 2025) with pre-computed indicators
- `runs/` — run ledgers and logs (append-only, never delete)

## Specifications

The `wat/` directory contains domain specifications in s-expression format. These are the source of truth for what the enterprise SHOULD do. The Rust implements them. When code and spec diverge, update the one that's wrong.

## Wards

Five spells that defend against bad thoughts. Run `/wards` to cast all five.

- `/sever` — cuts tangled threads. Braided concerns, misplaced logic, duplicated encoding.
- `/reap` — harvests what no longer lives. Dead code, unused structs, write-only fields.
- `/scry` — divines truth from intention. Spec vs code divergences.
- `/gaze` — sees the form. Names that mumble, functions that don't fit, comments that lie.
- `/forge` — tests the craft. Values not places, types that enforce, functions that compose.

## Standard Test

100k candles is the benchmark. 500 for smoke tests. 652k for full validation.

```bash
./enterprise.sh test 100000 --asset-mode hold --swap-fee 0.0010 --slippage 0.0025 --name benchmark
```
