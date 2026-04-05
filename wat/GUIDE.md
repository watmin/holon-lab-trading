# wat/ — The 007 Blueprint

*The coordinates to where the machine is.*

Built leaves to root from Proposal 007: Exit Proposes.
This document defines every struct and its interface. No implementation.
The wat files implement what this document declares.

Each section declares its dependencies. The order of sections IS the build
order — leaves first, root last. Each file's dependencies are already
written before it appears.

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

### RawCandle (the input — depends on: nothing)

The enterprise consumes a stream of raw candles. This is the only input.
Everything else is derived. Each raw candle identifies its asset pair —
the pair IS the routing key. Only the post for that pair receives it.

```
(struct raw-candle
  source-asset    ; Asset — e.g. USDC
  target-asset    ; Asset — e.g. WBTC
  ts open high low close volume)
```

Eight fields. From the parquet. From the websocket. The enterprise doesn't
care which. The asset pair IS the identity of the stream.

---

### Candle (depends on: RawCandle)

The enriched candle. Raw OHLCV in, 100+ computed indicators out.
Produced by IndicatorBank.tick(raw-candle). The post's first act
every candle.

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
  ;; Time — circular scalars (encode-circular)
  minute              ; mod 60
  hour                ; mod 24
  day-of-week         ; mod 7
  day-of-month)       ; mod 31
```

---

### IndicatorBank (depends on: RawCandle)

Streaming state machine. Advances all indicators by one raw candle.
Stateful — ring buffers, EMA accumulators, Wilder smoothers.
One per post (one per asset pair).

```
(struct indicator-bank ...)  ; internal state — implementation detail
```

**Interface:**
- `(new-indicator-bank) → IndicatorBank`
- `(tick indicator-bank raw-candle) → Candle`

---

### WindowSampler (depends on: nothing)

Deterministic log-uniform window selection. Each market observer has its
own — its own seed, its own time scale. The observer uses it every candle
to decide how much history to look at.

Owned by the market observer. Not by the enterprise. Not shared.
The enterprise doesn't sample windows — the observers do.

When window sampling becomes learned, the feedback routes through the
tuple journal's propagation — same as everything else. "This window size
produced Grace for this pair." The tuple journal knows. It routes back to
the market observer. The market observer adjusts its sampler.

```
(struct window-sampler
  seed min-window max-window)
```

**Interface:**
- `(new-window-sampler seed min max) → WindowSampler`
- `(sample window-sampler encode-count) → usize`

**Note:** min-window and max-window are crutches. The observer needs them
to bootstrap — it cannot learn its own time scale from nothing. But the
optimal window is learnable. The market tells us which windows produce
Grace. This is a coordinate for future work, not a problem to solve now.

---

### Vocabulary (depends on: what it thinks about)

Pure functions. Something in, facts out. No state.
Each domain thinks about different things. Market vocab thinks about
candles. Exit vocab thinks about candles and conditions. Risk vocab
(future) thinks about portfolio state. The input is whatever the
domain needs to form its judgment.

Three domains. Each domain has scoped subfiles.

**Domains:**

- **shared/** — universal context. Any observer can use these.
  - `time.wat` — minute (mod 60), hour (mod 24), day-of-week (mod 7), day-of-month (mod 31). Circular scalars.

- **market/** — what the market IS DOING. Direction signal. Market observers use these.
  - `oscillators.wat` — Williams %R, StochRSI, UltOsc, multi-ROC
  - `flow.wat` — OBV, VWAP, MFI, buying/selling pressure
  - `persistence.wat` — Hurst, autocorrelation, ADX zones
  - `regime.wat` — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
  - `divergence.wat` — RSI divergence via PELT structural peaks
  - `ichimoku.wat` — cloud zone, TK cross
  - `stochastic.wat` — %K/%D zones and crosses
  - `fibonacci.wat` — retracement level detection
  - `keltner.wat` — channel position, BB position, squeeze
  - `momentum.wat` — CCI zones
  - `price-action.wat` — inside/outside bars, gaps, consecutive runs
  - `timeframe.wat` — 1h/4h structure + narrative + inter-timeframe agreement

- **exit/** — whether CONDITIONS favor trading. Distance signal. Exit observers use these.
  - `volatility.wat` — ATR regime, ATR ratio, squeeze state
  - `structure.wat` — trend consistency, ADX strength
  - `timing.wat` — momentum state, reversal signals

- **risk/** — portfolio health. Coordinate for future work. Not in 007.

**Interface (per module):**
- `(encode-*-facts context) → Vec<Vector>`
  context is whatever the domain thinks about — candles, portfolio, trade state

A **fact** is a composition of atoms. The composition IS a vector.
The vector IS the fact. It doesn't need a separate name. It simply is.

```
"RSI is overbought"        → (bind (atom "rsi") (atom "overbought"))            → Vector
"RSI is at 73.2"           → (bind (atom "rsi") (encode-linear 73.2 100.0))     → Vector
"close is 2.3% above SMA20"→ (bind (atom "close-sma20") (encode-linear 0.023 0.1)) → Vector
"divergence detected"      → (atom "divergence")                                → Vector
```

Every relationship carries its magnitude. Not "close is above SMA20" —
"close is 2.3% above SMA20." The boolean throws away the signal. The
scalar preserves it. The discriminant learns that 0.1% above is noise
and 5% above is signal. The sign carries direction. The magnitude
carries conviction. The vector holds both.

The vocabulary observes. It composes atoms. The result is a vector.
Many fact-vectors get bundled into one thought-vector. That's the
superposition. The thought is the bundle of facts.

```
vocabulary observes → composes atoms → fact (a vector)
many facts → bundle → thought (a vector)
thought → cosine against discriminant → prediction
```

**Scalars are always bounded.** The vocabulary normalizes every measurement
to its natural coordinate system before encoding. The scale is not magic —
it is coupled at point-in-code where the domain knowledge lives.

- Bollinger position: [-1, 1] — where on the band. The band IS the bounds.
- RSI: [0, 1] — Wilder's formula defines the range.
- ATR ratio: [0, 1] — volatility relative to price.
- Close-to-SMA: [-1, 1] — distance as fraction of typical range.
- Stochastic %K: [0, 1] — where in the recent range.

The vocabulary doesn't invent bounds. It discovers them in the math.
The vocabulary owns the encode AND the decode — it put the value on
the scalar, it can take it back. That's why scalar accumulators work.

The encoding receives normalized values. The scale is uniform.
The domain knowledge lives in the vocabulary, not in the encoder.

The ThoughtEncoder in the Rust is a cache and a renderer — an
optimization that pre-computes common compositions. But the concept
has no intermediate form. Atoms compose. Vectors result. Thoughts bundle.

---

### ThoughtEncoder (depends on: Vocabulary, VectorManager)

Renders facts to geometry. Owned by the enterprise. Immutable after
construction. The enterprise passes it down to posts — the posts
borrow it, they don't own it. Not a singleton. Owned.

Pre-computes common compositions — comparison facts, zone facts,
fibonacci facts. A cache of the vocabulary rendered as vectors.

```
(struct thought-encoder
  vocab fact-cache comparison-vecs)
```

**Interface:**
- `(encode-thought encoder candles vm lens) → Vector`
- `(encode-facts encoder facts) → Vec<Vector>`

---

### LearnedStop (depends on: nothing)

Nearest-neighbor kernel regression. The exit observer's brain.
Cosine-weighted average of (thought, distance) pairs.
Empty at construction — returns default-distance until pairs accumulate.

```
(struct learned-stop
  pairs            ; Vec<(Vector, f64, f64)> — (thought, distance, weight)
  max-pairs        ; usize — cap
  default-distance); f64 — returned when empty (ignorance)
```

**Interface:**
- `(new-learned-stop max-pairs default-distance) → LearnedStop`
- `(recommended-distance learned-stop composed-thought) → f64`
- `(observe-stop learned-stop composed-thought optimal-distance weight)`
- `(pair-count learned-stop) → usize`

---

### ScalarAccumulator (depends on: nothing)

Per-magic-number f64 learning. Separates grace/violence observations.
Each magic number (trail-distance, k-stop, k-tp) gets its own accumulator.

```
(struct scalar-accumulator
  name grace-acc violence-acc)
```

**Interface:**
- `(new-scalar-accumulator name) → ScalarAccumulator`
- `(observe-scalar acc value grace? weight)`
- `(extract-scalar acc) → f64`

---

### MarketObserver (depends on: Journal, OnlineSubspace, WindowSampler)

Predicts direction. Learned. Labels come from tuple journal propagation —
Win/Loss from resolved paper and real trades. The market observer does NOT
label itself. Reality labels it.

The generalist is just another lens. No special treatment.

```
(struct market-observer
  lens                 ; Lens enum
  journal              ; Journal — Win/Loss
  noise-subspace       ; OnlineSubspace — background model
  window-sampler       ; WindowSampler — own time scale
  ;; Proof tracking
  resolved conviction-history conviction-threshold
  curve-valid cached-accuracy
  ;; Engram gating
  good-state-subspace recalib-wins recalib-total last-recalib-count)
```

**Interface:**
- `(new-market-observer lens dims recalib-interval seed) → MarketObserver`
- `(observe-candle observer candles vm) → Prediction`
  encode → noise update → strip noise → predict
- `(resolve observer thought prediction outcome weight q window)`
  called by tuple journal propagation — journal learns Win/Loss
- `(strip-noise observer thought) → Vector`
- `(funded? observer) → bool` — proof gate

---

### ExitObserver (depends on: LearnedStop)

Predicts exit distance. Learned. LearnedStop IS its brain.
Has a judgment vocabulary (volatility, structure, timing, generalist).
Composes market thoughts with its own judgment facts.
One LearnedStop per exit observer — M instances, not N×M.
The composed thought carries the market observer's signal in superposition.

```
(struct exit-observer
  lens            ; ExitLens enum — which judgment vocabulary
  learned-stop)   ; LearnedStop — nearest neighbor regression
```

**Interface:**
- `(new-exit-observer lens max-pairs default-distance) → ExitObserver`
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

---

### TupleJournal (depends on: Journal, OnlineSubspace, ScalarAccumulator, MarketObserver, ExitObserver)

The closure over (market-observer, exit-observer). The accountability
primitive. The manager replacement. Papers live inside. Propagate routes
to both observers.

The tuple journal does NOT own the observers — it references them.
The post owns the observers. The tuple journal accesses them.

The tuple journal does NOT own the LearnedStop — that's the exit
observer's brain. The tuple journal routes training data TO it.

The tuple journal does NOT own proposals or active trades — those are
the treasury's. The tuple journal proposes TO the treasury.

```
(struct tuple-journal
  market-name exit-name
  ;; Accountability
  journal noise-subspace grace-label violence-label
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
- `(new-tuple-journal market-name exit-name dims recalib-interval) → TupleJournal`
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

---

### Post (depends on: IndicatorBank, MarketObserver, ExitObserver, TupleJournal)

A self-contained unit for one asset pair. The post is where the thinking
happens. It owns the observers, the tuple journals, the indicator bank.
It does NOT own proposals or trades — those belong to the treasury.

Each post watches one market. (USDC, WBTC) is one post. (USDC, SOL) is
another. No cross-talk. Observers within a post learn together. Observers
across posts are independent.

The post proposes to the treasury. The treasury decides. When a trade
closes, the treasury routes the outcome back to the post for
accountability — to the tuple journal that proposed it.

```
(struct post
  ;; Identity
  source-asset         ; Asset — e.g. USDC
  target-asset         ; Asset — e.g. WBTC

  ;; Data pipeline
  indicator-bank       ; IndicatorBank — streaming indicators for this pair
  candle-window        ; VecDeque<Candle> — bounded history
  max-window-size      ; capacity

  ;; Observers — both are learned, both are per-pair
  market-observers     ; Vec<MarketObserver> [N]
  exit-observers       ; Vec<ExitObserver> [M]

  ;; Accountability — N×M tuple journals
  registry             ; Vec<TupleJournal> [N×M] — closures, permanent

  ;; Counter
  encode-count)
```

**Interface:**
- `(new-post source target dims recalib-interval max-window-size) → Post`
- `(post-on-candle post raw-candle ctx) → Vec<Proposal>`
  tick indicators → push window → encode → compose → propose → tick papers
  returns proposals for the treasury to evaluate
- `(post-update-triggers post trades thoughts) `
  update active trade triggers with fresh thoughts (treasury passes its trades)
- `(post-propagate post slot-idx thought outcome amount optimal)`
  treasury routes a resolved trade back to the post for accountability

---

### Treasury (depends on: nothing — pure accounting, but receives proposals from Posts)

Holds capital. Receives proposals from posts. Accepts or rejects.
Holds active trades. Settles trades. Routes outcomes back to posts
for accountability.

The treasury is where the money happens. It does not think. It counts.
It decides based on capital availability and proof curves.

The treasury maps each active trade back to its post and tuple journal
so that on settlement, propagate reaches the right observers.

```
(struct treasury
  ;; Capital
  assets               ; map of Asset → balance

  ;; Proposals — received from posts each candle, drained after funding
  proposals            ; Vec<Proposal> — cleared every candle

  ;; Active trades — funded proposals become trades
  trades               ; map of TradeId → Trade
  trade-origins        ; map of TradeId → { post, slot-idx, thought }
)
```

**Interface:**
- `(submit-proposal treasury proposal post slot-idx)`
  a post submits a proposal for the treasury to evaluate
- `(fund-proposals treasury)`
  evaluate all proposals, fund proven ones, reject the rest, drain
- `(settle-triggered treasury current-price) → Vec<Settlement>`
  check all active trades, settle what triggered, return settlements
  each settlement includes the post and slot-idx for propagation
- `(capital-available? treasury direction) → bool`
- `(deposit treasury asset amount)`
- `(balance treasury asset) → f64`

---

### Enterprise (depends on: everything above)

The coordination plane. The CSP sync point.

The enterprise is the only entity that sees the whole picture. Every other
entity is an independent process — it takes input and produces output.
It does not know about parallelism, ordering, or other entities.

The enterprise holds posts and a treasury. It routes raw candles to the
right post. It coordinates the four-step loop across all posts and the
treasury.

The enterprise knows:
- **What runs parallel** — market observers encode simultaneously (par_iter)
- **What runs sequential** — exit dispatch into registry (disjoint slots)
- **What order** — RESOLVE before COMPUTE before PROCESS before COLLECT
- **What flows where** — proposals from posts to treasury, settlements from treasury to posts
- **What gets cleared** — proposals empty after funding, every candle

```
(struct enterprise
  ;; The posts — one per asset pair
  posts                ; Vec<Post> — each watches one market

  ;; The treasury — shared across all posts
  treasury             ; Treasury — holds capital, funds trades, settles

  ;; Shared resources
  thought-encoder      ; ThoughtEncoder — immutable, shared across all posts
  vector-manager       ; VectorManager — immutable, shared

  ;; Logging
  pending-logs)
```

**Interface:**
- `(on-candle enterprise raw-candle)`
  route to the right post, then four steps
- `(step-resolve enterprise)`
  treasury settles triggered trades
  for each settlement: route to the post for propagation
- `(step-compute-dispatch enterprise candle post) → proposals`
  post encodes, composes, proposes — returns proposals for the treasury
- `(step-process enterprise post thoughts)`
  post ticks papers, treasury passes active trades for trigger updates
- `(step-collect-fund enterprise)`
  treasury funds or rejects all proposals, drains

---

## The build order

The order of sections above IS the build order. Each section declares its
dependencies. Each wat file is written after its dependencies exist.

```
raw-candle.wat          → (no deps)
candle.wat              → (depends on RawCandle)
indicator-bank.wat      → (depends on RawCandle)
window-sampler.wat      → (no deps)
vocab/                  → (depends on Candle)
thought-encoder.wat     → (depends on Vocabulary, VectorManager)
learned-stop.wat        → (no deps)
scalar-accumulator.wat  → (no deps)
market/observer.wat     → (depends on Journal, OnlineSubspace, WindowSampler)
exit/observer.wat       → (depends on LearnedStop)
tuple-journal.wat       → (depends on Journal, OnlineSubspace, ScalarAccumulator,
                            MarketObserver, ExitObserver)
post.wat                → (depends on IndicatorBank, MarketObserver, ExitObserver,
                            TupleJournal)
treasury.wat            → (no structural deps — receives proposals from Posts)
enterprise.wat          → (depends on Post, Treasury, ThoughtEncoder)
```

Each file is agreed upon before the next is written.
The proposal is the source of truth for what each entity does.

---

## The CSP per candle

```
Step 1: RESOLVE     — treasury settles triggered trades
                      for each settlement: enterprise routes to post
                      post.propagate → tuple journal → both observers learn

Step 2: COMPUTE     — each post: market observers encode (parallel)
         DISPATCH   — each post: exit observers compose + propose (sequential)
                      each post: register paper on every tuple journal
                      proposals submitted to treasury

Step 3: PROCESS     — each post: tuple journals tick papers → propagate resolved
                      treasury passes active trades to posts for trigger updates
                      exit observers query distance for each active trade

Step 4: COLLECT     — treasury funds proven proposals, rejects the rest
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
- Desk → Post (clean per-pair unit, no monolithic fold)
