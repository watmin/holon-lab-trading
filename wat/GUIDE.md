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
- **Primitives** — atom, bind, bundle, cosine, journal, curve
  - `(atom name) → Vector` — name a thought
  - `(bind a b) → Vector` — compose two thoughts
  - `(bundle &vecs) → Vector` — superpose many thoughts
  - `(cosine a b) → f64` — measure similarity
  - `journal` — accumulate observations, predict. Two readouts:
    - label readout: Win/Loss, Grace/Violence (market observer, tuple journal)
    - scalar readout: distance (exit observer)
  - `curve` — evaluate the journal's quality. The proof gate.
- **VectorManager** — deterministic atom → vector allocation
  - `(get-vector vm name) → Vector`

---

## Forward declarations

Every name in the architecture, declared once. The details follow below.

- **RawCandle** — the input. A stream of OHLCV candles tagged with an asset pair.
- **Candle** — the enriched candle. 100+ computed indicators from the IndicatorBank.
- **IndicatorBank** — streaming state machine. Raw candle in, enriched candle out.
- **WindowSampler** — deterministic window selection. Each market observer has its own.
- **Vocabulary** — pure functions. Context in, fact-vectors out. Three domains: shared, market, exit.
- **ThoughtEncoder** — AST evaluator. Vocabulary speaks a DSL, the encoder evaluates it with caching.
- **ScalarAccumulator** — per-magic-number f64 learning. Grace vs violence. Global per-pair. On the tuple journal.
- **MarketObserver** — predicts direction. Learned. Journal with label readout (Win/Loss).
- **ExitObserver** — predicts exit distance. Learned. Three LearnedStops (trail, stop, tp) — regression, not journal.
- **LearnedStop** — nearest-neighbor regression. (thought, distance, weight) observations. The exit observer's brain.
- **TupleJournal** — closure over (market, exit). Accountability. Papers. Propagate. On the post.
- **Post** — one per asset pair. Owns observers + tuple journals. The thinking happens here.
- **Treasury** — holds capital. Receives proposals. Funds or rejects. Settles. Routes outcomes to posts.
- **Enterprise** — the coordination plane. Routes candles to posts. The four-step CSP.

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
"RSI is at 0.73"            → (bind (atom "rsi") (encode-linear 0.73 1.0))           → Vector
"close is 2.3% above SMA20" → (bind (atom "close-sma20") (encode-linear 0.023 0.1))  → Vector
"ATR is 1.8x its average"   → (bind (atom "atr-ratio") (encode-log 1.8))             → Vector
"hour is 14:00"              → (bind (atom "hour") (encode-circular 14.0 24.0))       → Vector
```

Every relationship is a signed scalar. Not "close is above SMA20" —
the relative distance, with sign.

`(bind (atom "close-sma20") (encode-linear  0.023 0.1))` — 2.3% above.
`(bind (atom "close-sma20") (encode-linear -0.041 0.1))` — 4.1% below.

Same atom. Same encoding. The sign IS the direction. The magnitude IS
the distance. No "above" atom. No "below" atom. No boolean. Just the
number. The discriminant learns what positive means and what negative
means. The word "above" doesn't exist in the vector space. The number
0.023 does. The number -0.041 does.

The boolean threw away the signal. The scalar preserves it. The
discriminant learns that 0.1% above is noise and 5% above is signal.
The sign carries direction. The magnitude carries conviction.

The vocabulary observes. It composes atoms. The result is a vector.
Many fact-vectors get bundled into one thought-vector. That's the
superposition. The thought is the bundle of facts.

```
vocabulary observes → composes atoms → fact (a vector)
many facts → bundle → thought (a vector)
thought → cosine against discriminant → prediction
```

**The vocabulary is conditional.** It emits what IS true. Close is within the
bands or beyond them — not both. Each truth has a scalar property. The
vocabulary observes reality and speaks only truth.

**The encoding scheme IS the bounding strategy.** The vocabulary chooses the
right scheme for each fact — not magic, logic:

- **encode-linear** — naturally bounded scalars. The bounds are in the math.
  - Bollinger position: [-1, 1] — where on the band
  - RSI: [0, 1] — Wilder's formula defines the range
  - Stochastic %K: [0, 1] — where in the recent range

- **encode-log** — unbounded positive scalars. Log compresses naturally.
  The difference between 1x and 2x matters more than 4x and 5x. No cap needed.
  - Band-widths beyond Bollinger: how far past the boundary
  - ATR ratio: volatility relative to price
  - Volume ratio: volume relative to its moving average

- **encode-circular** — periodic scalars. The value wraps.
  - Minute: mod 60. Hour: mod 24. Day-of-week: mod 7. Day-of-month: mod 31.

Some facts are bounded. Some aren't. That's honest. The log doesn't
bound — it compresses. The circular doesn't bound — it wraps. Only
linear needs bounds, and linear's bounds come from the math.

The vocabulary owns the encode AND the decode — it put the value on
the scalar, it can take it back. That's why scalar accumulators work.

**No zones. No categories. Only scalars.** "Overbought" is a human label
on a continuous value — a magic number wearing a name. WHO decided 70
was the boundary? The vocabulary emits "RSI is at 0.73." The discriminant
learns where the boundaries are. Maybe 65 for BTC, maybe 80 for SPY.
The data decides. Every zone is a premature measurement — the boolean
lie one level up. Kill them all. Emit the scalar. Let the discriminant learn.

The encoding receives normalized values. The scale is uniform.
The domain knowledge lives in the vocabulary, not in the encoder.

The ThoughtEncoder in the Rust is a cache and a renderer — an
optimization that pre-computes common compositions. But the concept
has no intermediate form. Atoms compose. Vectors result. Thoughts bundle.

---

### ThoughtEncoder (depends on: VectorManager)

The vocabulary produces ASTs — the specification of WHAT to think. The
ThoughtEncoder evaluates them — HOW to think efficiently. It walks the
AST bottom-up, checking its memory at every node. The minimum computation
happens. Parts of the thought are already ready for reuse.

Two kinds of memory:

**Atoms: a dictionary.** Finite. Known at startup. Pre-computed. Never
evicted because never growing. The set is closed. Always there.

**Compositions: a cache.** Infinite. Optimistic. Use it if we have it.
Compute if we don't. Evict when memory says so. The set is open.

The ThoughtEncoder reclaims its name. It IS an encoder — it takes a
thought AST and produces a vector, doing the minimum work.

Owned by the enterprise. Passed to posts.

```
(struct thought-encoder
  atoms                 ; map of name → Vector (finite, pre-computed, permanent)
  compositions)         ; LRU cache: key → Vector (optimistic, self-evicting)
```

**The AST — what the vocabulary speaks:**

```scheme
(enum thought-ast
  (Atom name)                           ; dictionary lookup
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees
```

The vocabulary produces trees of this. Cheap. No vectors. No 10,000-dim
computation. Just "here is what I want to say." The calls to bind and
encode are deferred — the vocabulary knows what it wants, the encoder
decides how to compute it efficiently.

**Interface:**
- `(encode thought-encoder ast) → Vector`

One function. Recursive. Cache at every node. The cache key IS the AST
node — its structure is its identity. Same structure, same vector.

```scheme
(define (encode encoder ast)
  (or (lookup (:cache encoder) ast)          ;; cache hit → done
      (let ((result
              (match ast
                (Atom name)
                  (lookup-atom (:atoms encoder) name)

                (Linear name value scale)
                  (bind (encode encoder (Atom name))
                        (encode-linear value scale))

                (Log name value)
                  (bind (encode encoder (Atom name))
                        (encode-log value))

                (Circular name value period)
                  (bind (encode encoder (Atom name))
                        (encode-circular value period))

                (Bind left right)
                  (bind (encode encoder left)
                        (encode encoder right))

                (Bundle children)
                  (apply bundle
                    (map (lambda (c) (encode encoder c)) children)))))

        (store (:cache encoder) ast result)
        result)))
```

The vocabulary produces QUOTED expressions — data, not execution. The
encoder evaluates them. The vocabulary doesn't know about caching. The
encoder doesn't know about RSI. The quoted list is the interface.

The observer composes the thought:
```
observer calls vocab(context, cache) → Vec<Vector>  ; fact-vectors (cached per-candle)
observer calls bundle(facts)         → Vector        ; the thought
```

The lens is not a parameter. The lens is on the observer. The observer
knows which vocab modules are its domain.

**Thought composition is AST evaluation with caching.** The vocabulary
produces the AST — the structure of the thought. The ThoughtEncoder
walks it:

```
evaluate(node)
  → atom?        → dictionary (always succeeds)
  → any other?   → cache check → hit: reuse / miss: compute, store
  → bundle?      → always fresh (per-observer, per-candle)
```

Scalars, binds, encodes — all go through the cache. Same structure,
same vector. Scalars may evict quickly (values change each candle),
but within a candle the same scalar is reused across observers.

The AST IS a function. `bind(atom("rsi"), encode-linear(x, 1.0))` — the
structure is fixed. Only x varies. The encoder recognizes the structure
and reuses everything except the fresh scalar.

**The AST can be as complex as the thought requires.** These are data —
quoted expressions the vocabulary returns. The ThoughtEncoder evaluates them.

```scheme
;; A scalar fact — one atom, one signed value
(Linear "rsi" 0.73 1.0)

;; A signed relationship — 2.3% above. Negative would be below.
(Linear "close-sma20" 0.023 0.1)

;; A structural observation — RSI diverging from price, both magnitudes
(Bind (Atom "divergence")
  (Bind (Linear "close-delta" 0.03 0.1)
        (Linear "rsi-delta" -0.05 1.0)))

;; A moving average stack — the entire structure as signed distances
(Bundle
  (Linear "close-sma20" 0.023 0.1)
  (Linear "sma20-sma50" 0.011 0.1)
  (Linear "sma50-sma200" -0.035 0.1))

;; A conditional fact — the vocabulary chose this path, not both
(Log "bb-breakout-lower" 1.3)          ;; beyond: how far (log)
(Linear "bb-position" -0.7 1.0)        ;; inside: where (linear)

;; A temporal change — MACD histogram 3 candles ago vs now
(Bind (Atom "macd-hist-change")
  (Bind (Linear "now" -0.001 0.01)
        (Linear "3-ago" 0.002 0.01)))

;; Time — circular scalars that wrap
(Circular "hour" 14.0 24.0)
(Circular "minute" 35.0 60.0)
(Circular "day-of-week" 3.0 7.0)

;; A deep confluence — multi-timeframe + oscillator + momentum
(Bundle
  (Linear "tf-1h-trend" 0.7 1.0)
  (Linear "tf-4h-structure" 0.6 1.0)
  (Linear "rsi" 0.82 1.0)
  (Linear "macd-hist" -0.0005 0.01)
  (Log "macd-hist-from-peak" 0.167))
```

Simple thoughts are shallow trees. Complex thoughts are deep trees.
The encoder walks them all the same way. The mechanism doesn't change.

---

### Scalar journal (the mechanism — not a struct)

The exit observer's journal. Not a separate entity. The mechanism
that lives INSIDE the exit observer, on its `observations` field.

Same geometry as the market observer's journal. Different readout.
The market observer's journal returns a LABEL (Win/Loss). The exit
observer's journal returns a SCALAR (distance). Same cosine. Same
accumulation. Same decay.

k_trail, k_stop, k_tp — someone made these up. The exit observer's
journal replaces them with what the market actually said.
`compute_optimal_distance` sweeps candidate distances against real price
history and finds the one that maximized residue. That answer is stored
as an observation. Many answers accumulate. Old ones decay.

Each magic number gets its own exit observer:
- **Trail observer**: "given this thought, what trailing stop distance?"
- **Stop observer**: "given this thought, how far should the safety stop be?"
- **TP observer**: "given this thought, what take-profit distance?"

Each learns independently. Each starts ignorant — returns `default-distance`
(the ATR multiplier crutch). As observations accumulate, the crutch is
replaced by learned values. Ignorance blends to competence.

Two learning streams feed each exit observer:
- **Paper** (fast/cheap) — resolved paper entries from tick-papers
- **Reality** (on close) — compute_optimal_distance from hindsight

Paper fills it fast. Reality corrects it with the most honest signal.

The query interface is used by two callers:
- **The post** queries to seed its own paper entries — "what distance for this paper?"
  The tuple journal is the post's internal state. The post uses itself.
- **The treasury** queries through the post to manage active trades — "what distance now?"

Both read. Neither writes. The writing happens on RESOLUTION:
- **Paper resolves** (inside the post) → compute_optimal_distance → observe (write)
- **Trade resolves** (treasury settles, routes to post) → compute_optimal_distance → observe (write)

The query seeds the stop. The resolution teaches the answer.

---

### ScalarAccumulator (depends on: nothing)

Per-magic-number f64 learning. Lives on the tuple journal. Global per-pair.
Each magic number (trail-distance, stop-distance, tp-distance) gets its own.

Separates grace/violence observations into separate f64 prototypes.
Grace outcomes accumulate one way. Violence outcomes accumulate the other.
Extract via sweep recovers the value Grace prefers. "What value does
Grace prefer for this pair overall?" One answer regardless of thought.

Fed by resolution events: when a paper or trade resolves, the tuple
journal routes the optimal distance + Grace/Violence outcome to its
scalar accumulators.

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

### ExitObserver (depends on: Primitives — cosine-weighted regression)

Predicts exit distance. Learned. Each exit observer has THREE LearnedStops —
one per magic number (trail, stop, tp). Each is a nearest-neighbor
regression over (thought, distance, weight) observations. Not a journal.
A regression. The proposal explicitly replaced the exit journal with this.

Has a judgment vocabulary (volatility, structure, timing, generalist).
Composes market thoughts with its own judgment facts.
One per exit lens — M instances, not N×M.
The composed thought carries the market observer's signal in superposition.

```
(struct exit-observer
  lens                ; ExitLens enum — which judgment vocabulary
  trail-stop          ; LearnedStop — trailing stop distance regression
  safety-stop         ; LearnedStop — safety stop distance regression
  take-profit-stop    ; LearnedStop — take-profit distance regression
  default-distances)  ; (trail, stop, tp) — the crutches, returned when empty
```

Each LearnedStop: `(thought, distance, weight)` observations. Query by
cosine → distance for THIS thought. Contextual — different thoughts
get different distances.

**Interface:**
- `(new-exit-observer lens default-trail default-stop default-tp) → ExitObserver`
- `(encode-exit-facts exit-obs candle ctx) → Vec<Vector>`
  pure: candle → judgment fact vectors for this lens
- `(compose exit-obs market-thought exit-fact-vecs) → Vector`
  bundle market thought with exit facts
- `(recommended-distances exit-obs composed) → (trail, stop, tp)`
  query all three regressions — one call, three answers
- `(observe-distances exit-obs composed optimal-trail optimal-stop optimal-tp weight)`
  the market spoke — all three learn from one resolution
- `(experienced? exit-obs) → bool`
  have the regressions accumulated observations?

**Two mechanisms for the same magic numbers — now both introduced:**

The exit observer's LearnedStops are CONTEXTUAL: "for THIS thought,
what distance?" Cosine-weighted regression. Different thoughts →
different answers.

The tuple journal's ScalarAccumulators are GLOBAL per-pair: "what value
does Grace prefer for this pair overall?" One answer regardless of thought.

Both learn from the same resolution events. Different questions.
The cascade when queried: contextual (LearnedStop) → global per-pair
(ScalarAccumulator) → default (crutch).

---

### TupleJournal (depends on: Journal, OnlineSubspace, ScalarAccumulator, MarketObserver, ExitObserver)

The closure over (market-observer, exit-observer). The accountability
primitive. The manager replacement. Papers live inside. Propagate routes
to both observers.

The tuple journal does NOT own the observers — it references them.
The post owns the observers. The tuple journal accesses them.

The tuple journal does NOT own the exit observer's journal — that's on
the exit observer. The tuple journal routes training data TO it.

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
scalar-accumulator.wat  → (no deps)
market/observer.wat     → (depends on Journal, OnlineSubspace, WindowSampler)
exit/observer.wat       → (depends on Journal concept — scalar readout)
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
- Exit journal (Buy/Sell) → scalar journal on exit observer (distance)
- Panel engram → not needed
- Observer noise learning on market observer → tuple journal has its own
- Fixed ATR multipliers → exit observer's journal predicts from experience
- GENERALIST_IDX → the generalist is just another lens
- Desk → Post (clean per-pair unit, no monolithic fold)
