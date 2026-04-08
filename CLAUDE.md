# CLAUDE.md — holon-lab-trading

The enterprise. A self-organizing trading system built on holon-rs primitives.

## Source of Truth

The `wat/` directory is the source of truth. `wat/GUIDE.md` is the master
blueprint — every struct, every interface, every dependency. `wat/CIRCUIT.md`
visualizes it. `wat/ORDER.md` declares the construction order.

The wat files (s-expression specifications) implement what the guide declares.
The Rust in `src/` will implement what the wat specifies. When layers diverge,
the guide is right. The guide IS the program. The wat is the protein. The
Rust is the organism. The spells are the ribosomes.

**Current state:** The wat specification is at third inscription — 40 files,
3248 lines, proven by eight wards. The Rust (`src/`) is empty — it will be
compiled from the proven wat. Old code lives in `archived/`.

## Build & Run

```bash
./enterprise.sh build                                    # compile (release)
./enterprise.sh run --max-candles 5000 --asset-mode hold  # quick run
./enterprise.sh test 100000 --asset-mode hold --name my-run  # benchmark → runs/
./enterprise.sh kill                                      # kill switch
```

Kill switch file: `touch trader-stop`

## Architecture (Proposal 007)

Five primitives from holon-rs: atom, bind, bundle, cosine, reckoner.
One learning mechanism: the Reckoner (discrete or continuous readout).
One accountability measure: curve (conviction → accuracy).

The enterprise is a tree of posts. Each post is an asset pair. The
architecture is pair-agnostic — the binary takes an asset pool, each
unique pair becomes a post. One pair today. Many tomorrow.

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
broker returns PropagationFacts — the post applies them to the observers.
Values up, not effects down. More Grace → more capital. More Violence → less.

**Post** — per-asset-pair unit. Owns all observers and brokers. Routes candles
through the four-step loop. Proposes trades to the treasury. Uses
map-and-collect for the N×M grid — values, not mutation.

**Treasury** — available vs reserved capital. Funds proportionally to edge.
Bounded loss: capital reserved at funding, principal returns at finality.
Three trigger paths: active→settled-violence, active→runner, runner→settled-grace.

**Enterprise** — coordination plane. Three fields: posts, treasury,
market-thoughts-cache. Routes raw candles to posts. CSP sync point.
Returns (Vec<LogEntry>, Vec<misses>) from on-candle. Values up.

**ctx** — immutable world. ThoughtEncoder + dims + recalib-interval. Born
at startup. The one seam: composition cache updates between candles.

**Simulation** — pure functions. compute-optimal-distances sweeps candidate
values against price histories. Owns its own module.

### The four-step loop (per candle, per post)

1. **RESOLVE** — settle triggered trades, propagate outcomes to brokers → observers
2. **COMPUTE+DISPATCH** — encode candle → market observers predict → exit observers compose → brokers propose
3. **TICK** — 3a: parallel tick all brokers (paper trades). 3b: sequential propagate (shared observers). 3c: update triggers.
4. **COLLECT+FUND** — treasury evaluates proposals, funds proven ones

### Labels

- **Up / Down** — direction. Market observers predict this.
- **Grace / Violence** — accountability. Brokers measure this.
- **Side** — action (Buy/Sell). Derived from Up/Down for proposals.

## The Disposable Machine

The guide IS the DNA. The spells are the ribosomes. The wat is the protein.
Delete the wat. Run the spells. The wat reappears. Proven three times:

- Inscription 1: 38 files (pre-session, stale after guide changes)
- Inscription 2: 39 files, 4847 lines
- Inscription 3: 40 files, 3248 lines (five designer decisions applied)

Each inscription: leaner. Each ward pass: fewer findings. The fixed point approaches.

## Wards

Eight spells that defend against bad thoughts.

- `/sever` — cuts tangled threads. Braided concerns, misplaced logic.
- `/reap` — harvests what no longer lives. Dead code, unused fields.
- `/scry` — divines truth from intention. Spec vs implementation divergences.
- `/gaze` — sees the form. Names that mumble, comments that lie.
- `/forge` — tests the craft. Values not places, types that enforce.
- `/temper` — quiets the fire. Redundant computation, allocation waste.
- `/assay` — measures substance. Is the spec a program or a description?
- `/ignorant` — knows nothing. Reads the path as a stranger. The most powerful ward.

The assay is the eighth. Seven wards check correctness. The assay checks completeness.
It caught what the other seven missed — indicator-bank lost 1400 lines between
inscriptions and no other ward noticed.

## Principles

**Values up, not queues down.** Functions return side-effects as values.
Cache misses, log entries, propagation facts — all flow up through return types.
No queue parameters. No shared mutation during parallel phases.

**The binary orchestrates.** It creates ctx, creates the enterprise, feeds
the stream, writes the ledger, displays progress. It doesn't think.

**One encoding path.** Encoding IS the thought — identical at prediction
and resolution.

**The enterprise vocabulary.** Observer, Broker, Post, Treasury, Enterprise,
Reckoner. Not expert, manager, desk, journal. The names carry the architecture.

**Never average a distribution.** Let values breathe with the market.

## Data

- `data/analysis.db` — 652,608 5-minute BTC candles (Jan 2019–Mar 2025)
- `runs/` — run ledgers and logs (append-only, never delete)

## Standard Test

100k candles is the benchmark. 500 for smoke tests. 652k for full validation.

```bash
./enterprise.sh test 100000 --asset-mode hold --swap-fee 0.0010 --slippage 0.0025 --name benchmark
```
