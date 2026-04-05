# wat/ — The 007 Blueprint

Built leaves to root from Proposal 007: Exit Proposes.
This document defines every struct and its interface. No implementation.
The wat files implement what this document declares.

## Holon-rs primitives (provided by the substrate)

These are NOT specified in this tree. They are provided by holon-rs.

- **Journal** — accumulates labeled observations, produces discriminant, predicts
  - `(register journal label-name) → Label`
  - `(observe journal thought label weight)`
  - `(predict journal thought) → Prediction { direction, conviction }`
  - `(decay journal rate)`
  - `(discriminant journal label) → Vector`
  - `(recalib-count journal) → usize`
- **OnlineSubspace** — learns a manifold, measures anomaly via residual
  - `(update subspace vector)`
  - `(anomalous-component subspace vector) → Vector`
  - `(residual subspace vector) → f64`
  - `(sample-count subspace) → usize`
- **ScalarEncoder** — continuous value → vector
  - `(encode-log value) → Vector`
  - `(encode-linear value scale) → Vector`
  - `(encode-circular value period) → Vector`
- **Primitives** — the six
  - `(atom name) → Vector`
  - `(bind a b) → Vector`
  - `(bundle &vecs) → Vector`
  - `(cosine a b) → f64`
- **VectorManager** — deterministic atom → vector allocation
  - `(get-vector vm name) → Vector`

---

## Structs and interfaces

### 1. Candle (leaf)

The enriched candle. Raw OHLCV in, 100+ computed indicators out.

```
(struct candle
  ;; Raw
  ts open high low close volume
  ;; Moving averages
  sma20 sma50 sma200
  ;; Bollinger
  bb-upper bb-lower bb-width bb-pos
  ;; RSI, MACD, DMI, ATR
  rsi macd macd-signal macd-hist
  plus-di minus-di adx atr atr-r
  ;; Stochastic, CCI, MFI, OBV
  stoch-k stoch-d cci mfi obv
  ;; Keltner, squeeze
  kelt-upper kelt-lower kelt-pos squeeze
  ;; Range position
  range-pos-12 range-pos-24 range-pos-48
  ;; Multi-timeframe
  tf-1h-close tf-1h-high tf-1h-low tf-1h-ret tf-1h-body
  tf-4h-close tf-4h-high tf-4h-low tf-4h-ret tf-4h-body
  ;; Ichimoku
  tenkan-sen kijun-sen senkou-span-a senkou-span-b cloud-top cloud-bottom
  ;; Time
  hour day-of-week)
```

### 2. IndicatorBank (leaf)

Streaming state machine. Advances all indicators by one raw candle.

```
(struct indicator-bank ...)  ; internal state — ring buffers, EMA accumulators, etc.
```

**Interface:**
- `(tick indicator-bank raw-candle) → Candle`
- `(new-indicator-bank) → IndicatorBank`

### 3. WindowSampler (leaf)

Deterministic log-uniform window selection. Each observer gets its own seed.

```
(struct window-sampler
  seed min-window max-window)
```

**Interface:**
- `(sample window-sampler encode-count) → usize`  — the window size for this candle
- `(new-window-sampler seed min max) → WindowSampler`

### 4. Vocabulary (leaf)

Pure functions. Candle in, facts out. No state.
Each module covers a domain of technical analysis.

**Interface (per module):**
- `(encode-*-facts candle) → Vec<Fact>`

Modules: oscillators, flow, persistence, regime, divergence, ichimoku, stochastic, fibonacci, keltner, momentum, price-action, timeframe.

A **Fact** is `{ name: &str, value: f64, scale: f64, mode: ScalarMode }`.
The ThoughtEncoder renders facts to vectors via bind + scalar encoding.

### 5. ThoughtEncoder (leaf)

Renders facts to geometry. Shared across all observers. Immutable after construction.

```
(struct thought-encoder
  vocab fact-cache comparison-vecs)
```

**Interface:**
- `(encode-thought encoder candles vm lens) → Vector`
- `(encode-facts encoder facts) → Vec<Vector>`

### 6. LearnedStop (leaf)

Nearest-neighbor kernel regression. The exit observer's brain.
Cosine-weighted average of (thought, distance) pairs.

```
(struct learned-stop
  pairs         ; Vec<(Vector, f64, f64)> — (thought, distance, weight)
  max-pairs     ; usize — cap
  default-distance)  ; f64 — returned when empty (ignorance)
```

**Interface:**
- `(recommended-distance learned-stop composed-thought) → f64`
- `(observe-stop learned-stop composed-thought optimal-distance weight)`
- `(pair-count learned-stop) → usize`
- `(new-learned-stop max-pairs default-distance) → LearnedStop`

### 7. ScalarAccumulator (leaf)

Per-magic-number f64 learning. Separates grace/violence observations.

```
(struct scalar-accumulator
  name grace-acc violence-acc)
```

**Interface:**
- `(observe-scalar acc value grace? weight)`
- `(extract-scalar acc) → f64`
- `(new-scalar-accumulator name) → ScalarAccumulator`

### 8. MarketObserver (depends on: Journal, OnlineSubspace, WindowSampler)

Predicts direction. Learned. Labels from tuple journal propagation.

```
(struct market-observer
  lens              ; Lens enum
  journal           ; Journal — Win/Loss
  noise-subspace    ; OnlineSubspace — background model
  window-sampler    ; WindowSampler — own time scale
  ;; Proof tracking
  resolved          ; deque of (conviction, correct)
  conviction-history
  conviction-threshold
  curve-valid
  cached-accuracy
  ;; Engram gating
  good-state-subspace
  recalib-wins recalib-total last-recalib-count)
```

**Interface:**
- `(observe-candle observer candles vm) → Prediction`
  encode → noise update → strip noise → predict
- `(resolve observer thought prediction outcome weight q window)`
  called by tuple journal propagation — journal learns Win/Loss
- `(strip-noise observer thought) → Vector`
- `(funded? observer) → bool` — proof gate
- `(new-market-observer lens dims recalib-interval seed) → MarketObserver`

### 9. ExitObserver (depends on: LearnedStop)

Predicts exit distance. Learned. LearnedStop is its brain.

```
(struct exit-observer
  lens           ; ExitLens enum — which judgment vocabulary
  learned-stop)  ; LearnedStop — nearest neighbor regression
```

**Interface:**
- `(encode-exit-facts exit-obs candle ctx) → Vec<Vector>`
  pure: candle → judgment fact vectors for this lens
- `(compose exit-obs market-thought exit-fact-vecs) → Vector`
  bundle market thought with exit facts
- `(recommended-distance exit-obs composed) → f64`
  query the LearnedStop
- `(observe-distance exit-obs composed optimal-distance weight)`
  feed the LearnedStop — called by tuple journal propagation
- `(can-propose? exit-obs composed) → bool`
  has the LearnedStop accumulated pairs?
- `(new-exit-observer lens max-pairs default-distance) → ExitObserver`

### 10. TupleJournal (depends on: Journal, OnlineSubspace, ScalarAccumulator, MarketObserver, ExitObserver)

The closure over (market-observer, exit-observer). Accountability primitive.
Papers live inside. Propagate routes to both observers.

```
(struct tuple-journal
  market-name exit-name
  ;; Accountability
  journal           ; Journal — Grace/Violence
  noise-subspace    ; OnlineSubspace
  grace-label violence-label
  ;; Track record
  resolved conviction-history conviction-threshold
  curve-valid cached-acc
  cumulative-grace cumulative-violence trade-count
  ;; Papers — the fast learning stream
  papers            ; deque of PaperEntry, capped
  ;; Scalar learning
  scalar-accums     ; Vec<ScalarAccumulator>
  ;; Engram gating
  good-state-subspace recalib-wins recalib-total last-recalib-count)
```

**Interface:**
- `(propose tj composed) → Prediction`
  noise update → strip noise → predict Grace/Violence
- `(funded? tj) → bool` — proof curve gate
- `(register-paper tj composed entry-price entry-atr k-stop distance)`
  create a paper entry — every candle, every tuple
- `(tick-papers tj current-price market-observer exit-observer) → observations`
  tick all papers, resolve completed, propagate to both observers
- `(propagate tj thought outcome amount optimal market-observer exit-observer)`
  route to market observer (Win/Loss), exit observer (distance), self (Grace/Violence)
- `(paper-count tj) → usize`
- `(new-tuple-journal market-name exit-name dims recalib-interval) → TupleJournal`

### 11. Treasury (leaf — pure accounting)

Holds capital. Executes swaps. Settles trades.

```
(struct treasury
  assets)           ; map of asset → balance
```

**Interface:**
- `(settle treasury trade outcome) → settlement`
  execute swap, update balances
- `(capital-available? treasury direction) → bool`
  is there capital to deploy in this direction?
- `(open-trade treasury proposal price atr) → Trade`
  deploy capital, create position
- `(deposit treasury asset amount)`
- `(balance treasury asset) → f64`

### 12. Enterprise (depends on: everything above)

The four-step loop. Owns everything.

```
(struct enterprise
  indicator-bank candle-window max-window-size
  market-observers    ; Vec<MarketObserver> [N]
  exit-observers      ; Vec<ExitObserver> [M]
  encode-count
  treasury            ; Treasury
  registry            ; Vec<TupleJournal> [N×M]
  proposals           ; Vec<Option<Proposal>> [N×M]
  trades              ; Vec<Option<Trade>> [N×M]
  trade-thoughts      ; Vec<Option<Vector>> [N×M]
  pending-logs)
```

**Interface:**
- `(on-candle enterprise raw ctx)`
  tick indicators → push window → four steps
- `(step-resolve enterprise current-price candle-window)`
- `(step-compute-dispatch enterprise candle ctx) → thoughts`
- `(step-process enterprise thoughts current-price)`
- `(step-collect-fund enterprise current-price current-atr)`
- `(enterprise-index market-idx exit-idx exit-count) → slot-idx`

---

## The build order

```
1. candle.wat              — Candle struct, IndicatorBank interface
2. window-sampler.wat      — WindowSampler struct + sample
3. vocab/                  — fact modules (pure: candle → facts)
4. market/observer.wat     — MarketObserver struct + full interface
5. exit/observer.wat       — ExitObserver struct + LearnedStop interface
6. tuple-journal.wat       — TupleJournal struct + propagate + papers
7. treasury.wat            — Treasury struct + settle/fund interface
8. enterprise.wat          — Enterprise struct + four-step loop
```

Each file is agreed upon before the next is written.
Each file's dependencies must already exist.
The proposal is the source of truth for what each entity does.

---

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
