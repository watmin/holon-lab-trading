# CLAUDE.md — holon-lab-trading

The enterprise. A self-organizing trading system built on holon-rs primitives.

## Build & Run

```bash
./enterprise.sh build                                    # compile (release)
./enterprise.sh run --max-candles 5000 --asset-mode hold  # quick run
./enterprise.sh test 100000 --asset-mode hold --name my-run  # benchmark → runs/
./enterprise.sh kill                                      # kill switch
```

Kill switch file: `touch trader-stop`

Build output goes to `.build/` (gitignored). Run ledgers and logs go to `runs/` (gitignored). Never delete run artifacts — they are training data for us.

## Architecture (Proposal 007)

Five primitives from holon-rs: atom, bind, bundle, cosine, reckoner.
One learning mechanism: the Reckoner (discrete or continuous readout).
One accountability measure: curve (conviction → accuracy).

The enterprise is a tree of posts. Each post is an asset pair (e.g. USDC→WBTC).

**Market observers** (N per post) predict direction (Up/Down) from candle data.
Each has a reckoner, a noise subspace, a window sampler, and a lens that
selects which vocabulary modules it thinks about. Six lenses: momentum,
structure, volume, regime, narrative, generalist.

**Exit observers** (M per post) predict distances — how far to set the trailing
stop, safety stop, take profit, and runner trailing stop. Four continuous
reckoners each. They compose market thoughts with their own exit-specific facts.

**Brokers** (N×M per post) bind one market observer to one exit observer.
The broker IS the accountability unit. It owns paper trades, scalar
accumulators, and a Grace/Violence reckoner. When a trade resolves, the
broker propagates the outcome back to its observers. More Grace → more
capital. More Violence → less capital.

**Post** — per-asset-pair unit. Owns all observers and brokers. Routes candles
through the four-step loop. Proposes trades to the treasury.

**Treasury** — available vs reserved capital. Funds proportionally to edge.
The proof curve answers "how much edge?" not "any edge?" Bounded loss:
capital reserved at funding, principal returns at finality.

**Enterprise** — coordination plane. Routes raw candles to posts.
CSP sync point. Does not own immutable config (that's ctx).

**ctx** — immutable world. ThoughtEncoder + VectorManager. Born at startup.

### The four-step loop (per candle, per post)

1. **RESOLVE** — settle triggered trades, propagate outcomes to brokers
2. **COMPUTE+DISPATCH** — encode candle → market observers predict → exit observers compose → brokers propose
3. **TICK** — 3a: parallel tick all brokers (paper trades, learning). 3b: sequential propagate (shared observers). 3c: update triggers.
4. **COLLECT+FUND** — treasury evaluates proposals, funds proven ones

### Labels

- **Up / Down** — direction. Market observers predict this.
- **Grace / Violence** — accountability. Brokers measure this.
- Win/Loss is dissolved. Grace/Violence IS the trust measure.

## Source of Truth

The `wat/` directory is the source of truth. `wat/GUIDE.md` is the master
blueprint — every struct, every interface, every dependency.

The Rust in `src/` implements what the wat declares. When code and spec
diverge, the wat is right unless the code discovered something the spec
missed — then update the wat to match the discovery. Never let them drift.

**Current state:** `src/` contains the pre-007 implementation (desk-based
architecture). It will be rebuilt from the wat. `src-archived/` will hold
the old code. The rebuild goes leaves-to-root following the guide.

## Module Layout (current src/ — pre-007, awaiting rebuild)

```
src/bin/enterprise.rs     — the heartbeat (orchestrates, doesn't define)
src/bin/build_candles.rs  — parquet → SQLite candle builder (legacy pipeline)
src/lib.rs                — crate root, re-exports
src/state.rs              — EnterpriseState, CandleContext, TradePnl, SharedState
src/event.rs              — Event enum (Candle, Deposit, Withdraw)
src/indicators.rs         — streaming IndicatorBank (all TA from raw OHLCV)
src/enterprise.rs         — Enterprise struct (007 four-step loop, tuple journals)
src/thought/
  mod.rs                  — ThoughtEncoder + eval methods (Layer 0: candle → thoughts)
  pelt.rs                 — PELT changepoint detection
src/market/
  mod.rs                  — Lens enum, OBSERVER_LENSES
  desk.rs                 — Desk struct (pre-007, to be replaced by Post)
  manager.rs              — manager encoding (pre-007, dissolved into broker)
  observer.rs             — Observer struct (resolve, proof gate, engram)
  exit.rs                 — ExitAtoms + encode_exit_thought
src/risk/
  mod.rs                  — RiskBranch, RiskAtoms, 5 specialist encoders + generalist
  manager.rs              — RiskManager (Reckoner: Healthy/Unhealthy)
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
src/journal.rs            — re-export of holon::Reckoner (was Journal)
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

**One encoding path.** Encoding IS the thought — it must be identical at prediction and resolution. One function, called in both places.

**The enterprise vocabulary.** Names match the 007 architecture:
- Observer (not expert, not trader) — they perceive, they don't decide
- Broker (not manager, not tuple-journal) — the accountability unit
- Post (not desk, not trader) — one post per asset pair
- Portfolio (not Trader) — portfolio state, not a person
- Ledger (not run_db) — the ledger records, it doesn't decide
- Candle (not db) — it holds computed indicators
- Reckoner (not journal) — the learning primitive

**Flat until siblings arrive.** Don't create `foo/mod.rs` until `foo/bar.rs` needs to exist. Grow the tree when the leaves arrive.

**Never average a distribution.** No fixed parameters derived from historical percentiles. Let values breathe with the market. ATR, conviction, regime — use the current state, not averaged history.

## Data

- `data/analysis.db` — 652,608 5-minute BTC candles (Jan 2019–Mar 2025)
- `runs/` — run ledgers and logs (append-only, never delete)

## Wards

Spells that defend against bad thoughts. Run `/wards` to cast them all.

- `/sever` — cuts tangled threads. Braided concerns, misplaced logic, duplicated encoding.
- `/reap` — harvests what no longer lives. Dead code, unused structs, write-only fields.
- `/scry` — divines truth from intention. Spec vs code divergences.
- `/gaze` — sees the form. Names that mumble, functions that don't fit, comments that lie.
- `/forge` — tests the craft. Values not places, types that enforce, functions that compose.
- `/temper` — quiets the fire. Redundant computation, loop-invariant work, allocation waste.
- `/assay` — measures substance. Is the spec a program or a description? Expression density.
- `/ignorant` — knows nothing. Reads the document as a stranger. The most powerful ward.

## Standard Test

100k candles is the benchmark. 500 for smoke tests. 652k for full validation.

```bash
./enterprise.sh test 100000 --asset-mode hold --swap-fee 0.0010 --slippage 0.0025 --name benchmark
```
