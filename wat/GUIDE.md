# wat/ — The 007 Blueprint

This directory is the source of truth for the enterprise architecture.
Built leaves to root from Proposal 007: Exit Proposes.

## The entities

| Entity | What it IS | Depends on |
|--------|-----------|------------|
| Candle | Enriched OHLCV with 100+ indicators | IndicatorBank (streaming state machine) |
| WindowSampler | Deterministic log-uniform window selection | Nothing (seed only) |
| Vocabulary | Pure functions: candle → facts | Candle |
| MarketObserver | Predicts direction. Learned (Win/Loss) | Journal, OnlineSubspace, WindowSampler, Lens, Vocabulary |
| ExitObserver | Predicts exit distance. Learned (LearnedStop) | Lens, LearnedStop |
| TupleJournal | Closure over (market, exit). Accountability | Journal, OnlineSubspace, ScalarAccumulator, MarketObserver, ExitObserver |
| Treasury | Holds capital. Executes swaps. Settles trades | Nothing (pure accounting) |
| Enterprise | The four-step loop. Owns everything | All of the above |

## Holon-rs primitives (not specified here — provided by the substrate)

- **Journal** — accumulates labeled observations, produces discriminant, predicts
- **OnlineSubspace** — learns a manifold, measures anomaly via residual
- **ScalarEncoder** — continuous value → vector (log, linear, circular)
- **Primitives** — atom, bind, bundle, cosine
- **VectorManager** — deterministic atom → vector allocation

## The build order (leaves to root)

```
1. candle.wat              — the enriched candle struct + indicator bank interface
2. window-sampler.wat      — deterministic window selection
3. vocab/                  — thought vocabulary modules (pure: candle → facts)
4. market/observer.wat     — direction prediction, learned from propagation
5. exit/observer.wat       — distance prediction, LearnedStop is its brain
6. tuple-journal.wat       — the closure, accountability, papers, propagate
7. treasury.wat            — capital management, settle, fund
8. enterprise.wat          — the four-step loop, owns everything
```

Each file is agreed upon before the next is written.
Each file's dependencies must already exist.
The proposal is the source of truth for what each entity does.

## The CSP per candle

```
Step 1: RESOLVE     — treasury settles triggered trades
                      propagate → market observer (Win/Loss)
                      propagate → exit observer (optimal distance)
                      propagate → tuple journal (Grace/Violence)

Step 2: COMPUTE     — market observers encode (parallel)
         DISPATCH   — exit observers compose + propose (sequential)
                      register paper on every tuple journal
                      propose if funded + experienced

Step 3: PROCESS     — exit observer queries distance for active trades
                      tuple journal ticks papers → propagate resolved

Step 4: COLLECT     — treasury funds proven proposals
         FUND        proposals drain → empty after step 4
```

## What 007 replaced

- Manager journal → tuple journals (each pair IS its own manager)
- Pending queue + horizon labels → paper trades (fast learning)
- Exit journal (Buy/Sell) → LearnedStop regression (distance)
- Panel engram → not needed
- Observer noise learning on market observer → tuple journal has its own
- Fixed ATR multipliers → LearnedStop predicts from experience
- GENERALIST_IDX → the generalist is just another lens
