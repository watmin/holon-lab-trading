# wat/ — The 007 Blueprint

*The coordinates to where the machine is.*

A machine that measures thoughts against reality. (A "thought" is a
vector — the machine encodes a candle into a high-dimensional vector
and measures whether that vector predicted value or destruction.) Did
this thought produce value or destroy it? Built leaves to root from
`docs/proposals/2026/04/007-exit-proposes/`.

This document defines every struct and its interface. No implementation.
The wat files — s-expression specifications in Scheme-like syntax —
implement what this document declares. The wat language is defined in
`LANGUAGE.md` in the wat repo (`~/work/holon/wat/LANGUAGE.md`) — grammar,
host forms, core forms, type annotations, structural types (struct,
enum, newtype). The path assumes the standard workspace layout; the
document stands alone without it.

Each section declares its dependencies. The order of sections IS the build
order — leaves first, root last. Each file's dependencies are already
written before it appears.

## Holon-rs primitives (provided by the substrate)

These are NOT specified in this tree. They are provided by holon-rs.

- **atom** — `(atom name) → Vector` — name a thought
- **bind** — `(bind a b) → Vector` — compose two thoughts
- **bundle** — `(bundle &vecs) → Vector` — superpose many thoughts
- **cosine** — `(cosine a b) → f64` — measure similarity
- **reckoner** — the learning primitive. "Reckon" means both "to count"
  and "to judge." Market observers use discrete mode (Up/Down classification).
  Exit observers use continuous mode (distance regression). A reckoner
  keeps accounts and delivers a verdict. It accumulates experience.
  Internally it builds a discriminant — the direction that separates
  outcomes. It reckons a verdict from a new
  input via cosine against the discriminant. Old experience decays.
  The verdict sharpens over time through recalibration. One primitive,
  multiple readout modes:
  - `(make-reckoner name dims recalib-interval config)` → Reckoner
    - name: String — identifies the reckoner (e.g. "direction", "trail").
    - dims: usize — vector dimensionality. Separate from config.
    - recalib-interval: usize — observations between recalibrations. Separate from config.
    - config is a `reckoner-config` enum (defined in construction order)
      specifying the readout mode only:
      - `(Discrete (labels "Up" "Down"))` → discrete. N labels. Classification.
      - `(Continuous (default-value 0.015))` → continuous. Scalar. Regression.
  - `(observe reckoner thought observation weight)` — both modes.
    observation is a label (discrete) or a scalar (continuous).
    Not the Outcome enum — observation is the general term for what
    the reckoner learns from. Outcome is a specific kind of observation.
  - `(predict reckoner thought)` — both modes.
    returns Prediction — the reckoner's verdict.
  - `(decay reckoner factor)` — both modes. Old experience fades.
  - `(experience reckoner) → f64` — how much? 0.0 = ignorant.
  - `(recalib-count reckoner) → usize` — both modes.
  - **holon-rs has both modes.** `Reckoner` with `ReckConfig::Discrete`
    and `ReckConfig::Continuous`. The Reckoner is the only learning
    primitive in holon-rs.
  - Coordinates for later: circular readout (periodic values that wrap),
    ranked readout (orderings). Other readout modes are possible — the
    reckoner mechanism is general. These are future work, not current.
- **curve** — the reckoner's self-evaluation. The reckoner carries its own
  curve internally. After many predictions resolve (correct or wrong), the
  curve answers: "when you predicted strongly, how often were you right?"
  Input: prediction strength. Output: accuracy. A continuous surface.
  How much edge, not whether edge. resolve() feeds it. edge-at() reads it.
  - `(resolve reckoner conviction correct?)` — feed a resolved prediction to the reckoner's internal curve
  - `(edge-at reckoner conviction) → f64` — how accurate at this conviction level?
  - `(proven? reckoner min-samples) → bool` — enough data to trust?
  The curve self-evaluates — it reports amplitude and exponent from
  accumulated data. That is measurement, not learning.
  **Resolved: the curve communicates via one scalar.** The producer
  calls `(edge-at reckoner conviction)` and attaches the result to its message.
  The consumer encodes it as a scalar fact: `(bind (atom "producer-edge") (encode-linear edge 1.0))`.
  The consumer's reckoner learns whether the edge predicts Grace.
  No meta-journal. No curve snapshot. No new primitives. One f64.
  The problem was never "how do I learn a curve" — it was "how do I
  communicate what a curve knows." One number. The tools compose.
- **OnlineSubspace** — learns what normal looks like. Measures how unusual
  a new input is (the residual). High residual = unusual. Low = boring.
  - `(update subspace vector)`
  - `(anomalous-component subspace vector) → Vector`
  - `(residual subspace vector) → f64`
  - `(sample-count subspace) → usize`
- **ScalarEncoder** — continuous value → vector
  - `(encode-log value) → Vector`
  - `(encode-linear value scale) → Vector`
  - `(encode-circular value period) → Vector`
- **VectorManager** — deterministic atom → vector allocation
  - `(get-vector vm name) → Vector`
- **Utility operations** — from `std/vectors.wat` in the wat language, provided by holon-rs:
  - `(amplify vec vec weight) → Vector` — scale a vector by weight
  - `(zeros) → Vector` — zero vector at the current dimensionality
  - `(negate vec) → Vector` — flip sign
  - `(difference a b) → Vector` — subtract
  - `(blend a b ratio) → Vector` — weighted interpolation
  - `(prototype vecs) → Vector` — normalized average
  - `(online-subspace dims k) → OnlineSubspace` — constructor (k = principal components)
  - `(discriminant reckoner label) → Vector | None` — the learned separation direction

---

## Definitions — the thoughts themselves

Before the structs. Before the constructors. The meanings.
Each definition can only reference definitions above it.
If you want the shapes first, skip to Forward declarations and return
here when a name is unfamiliar.

#### Labels and measurement

- **Up / Down** — direction labels. The market observer predicts: the price
  will go up or the price will go down. That's the prediction. When a trade
  resolves, the actual direction is routed back to the market observer.
  The reckoner learns from reality.

- **Grace / Violence** — accountability labels. "Did this trade produce
  value or destroy it?" Grace = profit. Violence = loss. More Grace, more
  capital. More Violence, less capital. The Grace/Violence ratio IS the
  answer to "do we trust this team of observers?"

- **Labels** — Up/Down and Grace/Violence are labels. Labels are not
  booleans. They carry weight — how decisively the market answered.
  A strong Grace teaches harder than a marginal one. Two pairs for
  learning: Direction (Up/Down) and Accountability (Grace/Violence).
  A third pair for action: Side (Buy/Sell) — derived from Up/Down,
  used on proposals and trades. Note: Side × Direction forms a 2×2 grid
  where Buy+Up = Grace, Buy+Down = Violence, Sell+Down = Grace,
  Sell+Up = Violence. This is a THEOREM —
  true when the system is coherent — not a definition. Outcome is
  measured independently because incoherence (the system acting against
  its own prediction) is where the machine learns the most.

#### Data and encoding

- **Candle** — one period of market data. Raw: six data values (open, high,
  low, close, volume, timestamp) plus an asset pair for routing (source-asset,
  target-asset) — eight fields total on the RawCandle struct. Enriched: the
  raw data plus 100+ computed indicators (moving averages, oscillators,
  volatility, momentum, structure).

- **Indicator** — a derived measurement from price history. RSI, MACD,
  ATR (Average True Range — a measure of volatility), Bollinger Bands.
  Each one is a streaming computation — it needs all prior candles to
  produce the current value. Indicators produce SCALARS, not zones.
  "RSI at 0.73" not "RSI is overbought." The reckoner learns where the
  boundaries are.

- **Magic numbers** — k_trail (trailing stop), k_stop (safety stop),
  k_tp (take-profit), k_runner_trail (runner trailing stop). When a trade
  is open, four distances matter: how far to trail the price, how far to
  let it move against you, how far to let it go before taking the win,
  and how far to trail the runner after principal recovery. Someone
  chose these as multipliers of ATR (defined above). They are the last
  magic — crutches returned when the system has no experience. As
  observations accumulate, the crutch is replaced by what the market said.

- **Discriminant** — the direction in thought-space that separates two
  outcomes. The reckoner builds it from accumulated observations. "Which
  direction in 10,000 dimensions best separates Grace from Violence?"
  The discriminant IS that direction. Cosine against it → conviction.

- **Conviction** — how strongly the reckoner predicts. The cosine between
  the thought and the discriminant. High conviction = many facts voting
  in the same direction. Low conviction = ambiguous.

- **Fact** — a named observation about the world, composed from atoms. "RSI
  is at 0.73." The composition IS a vector. The vector IS the fact.

- **ThoughtAST** — a deferred fact. AST = Abstract Syntax Tree — a tree of
  operations described as data, not yet executed. The vocabulary produces
  these. The ThoughtEncoder evaluates them.

- **Thought** — a bundle of facts. Many fact-vectors superposed into one
  vector. The thought is what an observer perceived about this candle.
  A "composed thought" is a market thought bundled with exit facts —
  it appears on PaperEntry, Proposal, TradeOrigin, Resolution, and
  TreasurySettlement. Same vector, stashed at different lifecycle points.

#### Observers and learning

- **Lens** — which vocabulary subset an observer thinks through. A momentum
  lens selects momentum-related facts. A regime lens selects regime-related
  facts. A generalist lens selects all facts. The lens IS the observer's
  identity — it determines what thoughts the observer thinks.

- **N and M** — N is the number of market observers (one per MarketLens
  variant). M is the number of exit observers (one per ExitLens variant).
  N and M are determined by the lens enums — add a variant, add an observer.
  Every combination gets a broker. N×M brokers total. Each broker's identity
  is the set {"market-lens", "exit-lens"} — two names today, more later.

- **Observer** — an entity that perceives and learns. It has a lens and
  accumulated experience. Two kinds: market observers predict direction
  (Up/Down) using a discrete reckoner. Exit observers estimate distance
  (optimal exit) using continuous reckoners.

- **Exit reckoners** — the exit observer has four continuous reckoners,
  one per distance: trail, stop, tp, runner-trail. "For a thought like THIS, what
  distance did the market say was optimal?" Replaces magic numbers with
  measurement.

- **ScalarAccumulator** — per-magic-number f64 learning (extraction mechanism
  detailed in the ExitObserver section below). Each scalar value
  is encoded as a vector (using ScalarEncoder, defined above in primitives).
  Grace outcomes accumulate into a Grace prototype.
  Violence outcomes accumulate into a Violence prototype. To extract: try
  candidate values, encode each, cosine against the Grace prototype. The
  candidate closest to Grace wins. "What value does Grace prefer overall?"
  Global per-pair — one answer regardless of thought.

- **Paper trade** — a "what if." A hypothetical trade that tracks what WOULD
  have happened. Both sides (buy and sell) are tracked simultaneously.
  When both sides resolve, the paper teaches: what distance would have
  been optimal? Papers are the fast learning stream — cheap, many, every
  candle. Papers and active trades are treated equally by the learning
  system. Both use whatever the reckoner knows at the time. Both start
  ignorant (crutch values). Both feed Grace/Violence back to the broker.

- **Prediction** — what the reckoner returns when asked. Data, not action.
  An enum — two honest branches, no dead fields:
  - Discrete: a list of (label, score) pairs + conviction. The consumer picks.
  - Continuous: a scalar value + experience.
  Pattern-match to know which mode. The type tells you. The Discrete
  variant is keyed by label name (String) — the broker's reckoner returns
  ("Grace"/"Violence", score) pairs. The market observer's returns
  ("Up"/"Down", score) pairs. Same enum. Different label names.

- **Proof curve** — the reckoner's self-evaluation. The reckoner carries
  its own curve. resolve() feeds it. edge-at() reads it. How much edge?
  A continuous measure. 52.1% is barely there. 70% is screaming. The
  treasury funds proportionally. The entity earns a DEGREE of trust, not
  a binary gate. More edge, more capital. Not a separate object — it IS
  the reckoner's internal accountability surface.

#### Trade lifecycle

- **Broker** — binds a set of observers as a team. Any number — two today
  (market + exit), three tomorrow (market + exit + risk). The accountability
  primitive. It measures how successful the team is — Grace or Violence.
  It owns paper trades. When papers or real trades resolve, it routes
  outcomes to every observer in the set.

- **Residue** — permanent gain. When a trade settles with Grace, the
  principal returns to available capital and the profit stays — that
  profit is the residue. Residue is never withdrawn by the enterprise.
  It compounds. The accumulation model: deploy, recover principal,
  keep the residue. The residue IS the growth.

- **Trade phases** — a trade has a phase, not just a status. The phase
  transitions are a state machine:
  - **Active** — capital is reserved. Trailing stop, safety stop, and
    take-profit are live. The trade is running.
  - Active + stop-hit → **Settled(Violence)** — loss bounded by reservation.
    Principal minus loss returns to available.
  - Active + price moves favorably → **Runner** — the trailing stop has
    moved far enough that exit would recover the principal. The trade is
    NOT exited. The trailing stop WIDENS. The trade continues riding.
    The "runner" is a stop-management phase, not a settlement event.
    The wider stop gives the trade room to breathe — because if it
    exits now, the principal is already covered. Zero effective risk.
  - **Runner** — the trade is still open. Still one position. The
    trailing stop is wider (runner-trail distance, a fourth learnable
    scalar). The trade rides until the runner stop fires.
  **The stops breathe.** Every candle, step 3c re-queries the exit
  observer: "for THIS thought in THIS market context, what are the
  optimal distances NOW?" The exit reckoner learned from every prior
  resolution which distances produced Grace. It applies that learning
  to active trades continuously. The stops are not set-and-forget.
  They adapt. Tighter when the market says tighten. Wider when the
  market says breathe. This continuous stop management IS the mechanism
  for maximizing value extraction — the trade captures as much residue
  as the market will give, bounded by the learned distances.

  **Update cost.** Trigger updates have a cost. In-memory: 0% — update
  every candle, no reason not to. On-chain: each update is a transaction
  with gas cost. Over-eager updating hurts — micro-adjustments that cost
  gas but don't materially change the stop levels produce Violence.
  The update-cost is a configurable parameter on the enterprise (default
  0.0 for in-memory). When non-zero, step 3c compares new levels against
  current levels: if the change is not worth the cost, skip the update.
  The machine should LEARN this — the reckoner can observe whether
  updates of a given magnitude produced Grace or Violence after accounting
  for the update cost. The optimal update frequency emerges from the
  learning, not from a hardcoded threshold.
  - Active/Runner + stop fires → **Settled** — one exit. One swap.
    The full position swaps back. The treasury computes:
    - If exit amount > principal: **Grace.** Principal returns to
      available. Residue (exit minus principal minus fees) is
      permanent gain.
    - If exit amount ≤ principal: **Violence.** What remains returns
      to available. Loss bounded by reservation.

  **Concrete example — the number flow:**
  ```
  Entry:  $50 USDC → 0.0005 WBTC at $100,000/BTC (one swap, minus fees)

  Price rises. Trailing stop ratchets up. At some point, the stop
  level implies exit would recover the principal → phase becomes :runner.
  No swap. No exit. The stop just widens. The trade continues.

  Price keeps rising to $120,000. Then reverses.
  Runner trailing stop fires at $115,000.
  Position value at exit: 0.0005 BTC × $115,000 = $57.50 worth

  Exit swap: enough WBTC → USDC to recover $50 principal (one swap, minus fees)
  That's 50 / 115,000 = ~0.000435 WBTC swapped back to ~$50 USDC

  What remains:
    $50 USDC       → available. The principal. Deployed again next candle.
    ~0.000065 WBTC → available. The residue. ~$7.50 worth. Stays as WBTC.

  Both sides of the pair grew. USDC recycled. WBTC accumulated.
  The residue IS the target asset. Not converted. Not swapped.
  The treasury manages wealth — not a cash balance.
  ```

  **The other side — same mechanics, reversed:**
  ```
  Entry:  0.001 WBTC → USDC at $100,000/BTC (one swap, minus fees)
  The observer predicted Down. Deploy WBTC. Acquire USDC.

  Price drops to $85,000. Trailing stop ratchets.
  Runner trailing stop fires at $88,000.
  The WBTC we would need to buy back is cheaper now.

  Exit swap: enough USDC → WBTC to recover 0.001 WBTC principal
  That's 0.001 × 88,000 = $88 USDC swapped back to 0.001 WBTC

  What remains:
    0.001 WBTC   → available. The principal. Deployed again next candle.
    ~$12 USDC    → available. The residue. Stays as USDC.

  WBTC recycled. USDC accumulated. Both sides grew.
  ```

  **The pair doesn't matter. The direction doesn't matter. The residue IS the point.**
  ```
  (SPY, GOLD):      deploy SPY → acquire GOLD. Recover SPY. Residue is GOLD.
  (GOLD, SPY):      deploy GOLD → acquire SPY. Recover GOLD. Residue is SPY.
  (SILVER, ANDURIL): deploy SILVER → acquire ANDURIL. Recover SILVER. Residue is ANDURIL.
  ```

  Any pair. Both directions. The architecture is agnostic. Deploy capital.
  Ride the trade. Recover capital. The remainder is wealth. The residue
  compounds. The goal: minimize capital lost. Maximize wealth accumulated.
  The machine strives to have the least lost capital possible while
  accumulating residue on every winning trade.

  Two swaps total. Entry and exit. The runner is NOT a swap — it is the
  stop widening. One trade. One entry. One exit. The treasury splits the
  proceeds after exit. Each swap incurs `swap-fee + slippage`. The edge
  must exceed the venue cost rate for the trade to be worth taking.

  The phase is a value on the Trade struct. The runner phase changes
  stop management, not the position. ONE settlement event per trade.
  Designers: "the mechanism is designable now. The parameters will be
  learned. That is the whole point of having reckoners."

- **Message protocol** — every learned message carries three semantic values:
  `(thought: Vector, prediction: Prediction, edge: f64)`.
  Thought = what you know. Prediction = what you think will happen.
  Edge = how accurate you are when you predict this strongly.
  Functions may return additional transport values (e.g. cache misses)
  alongside the protocol triple — those are plumbing, not content.
  edge ∈ [0.0, 1.0]. Accuracy from the curve at this conviction. 0.0 when unproven.
  0.50 = noise. Above = correlated. Below = anti-correlated (the flip).
  The consumer encodes the edge as a fact and is free to gate, weight,
  sort, or ignore. Every producer that has learned from experience
  attaches a measure of that experience to its output. Opinions carry
  credibility. Data (candles, raw facts) does not.

- **Propagation** — routing resolved outcomes through the broker to
  the observers that need to learn. Grace/Violence to the broker's
  own record. The actual direction (Up/Down) to the market observer.
  Optimal distance to the exit observer.

#### Infrastructure

- **Post** — a trading post. The NYSE had specialist posts — each one
  handled one security, had its own specialists, its own order book.
  The (USDC, WBTC) post. The (SPY, SILVER) post. The (SOL, GOLD) post.
  Any asset pair. The post doesn't care what the pair IS — it watches a
  stream of candles, acquires capital from the treasury, and the treasury
  holds it accountable. Grace or Violence. Each post has its own observers,
  its own brokers, its own indicator bank. No cross-talk between posts.
  The enterprise is the floor. Each post watches one market.

- **Denomination** — what "value" means. The treasury counts in a
  denomination. USD today. Could be EUR, could be SOL.

- **TradeId** — a newtype over usize. Not a raw integer — a distinct type
  that the compiler enforces. The treasury's key for active trades. Assigned
  at funding time. Maps back to (post-idx, slot-idx) via trade-origins.

- **slot-idx** — the flat index into the broker registry.
  Today each broker binds exactly one market observer + one exit observer.
  `slot-idx = market-idx × M + exit-idx` — one broker per
  (market, exit) pair, N×M total. When the broker generalizes to more
  than two observer kinds, the indexing scheme changes. The slot-idx
  remains — a usize into a flat vec. The formula adapts.

- **Noise subspace** — the background model. An OnlineSubspace that
  learns what ALL thoughts look like — the average texture of thought-space.
  The anomalous component IS what's unusual — the part the subspace cannot
  explain. strip-noise returns it directly. The reckoner learns from the
  residual.

- **Experience** — how much a reckoner has learned. 0.0 = empty. Grows
  with each observation. The reckoner's self-knowledge of its own depth.

- **Ignorance** — the starting state. Every reckoner begins with zero
  experience. No edge. The reckoner does not participate when it knows
  it doesn't know. No special bootstrap logic. The architecture IS the
  bootstrap — papers fill the reckoner, experience grows, the treasury
  starts listening. Start ignorant. Learn. Graduate.

- **Weight** — an f64 that scales how much an observation contributes to
  learning. 1.0 = normal contribution. Larger = stronger signal. Used in
  reckoner.observe, broker.propagate, and scalar accumulator.observe.
  Typically derived from the magnitude of the outcome — a large Grace
  teaches harder than a marginal one.

- **Recalibration** — the reckoner periodically recomputes its discriminant
  from accumulated observations. The interval (recalib-interval) is how
  often this happens — every N observations.

- **Engram gating** — after a recalibration with good accuracy, snapshot
  the discriminant as a "good state." An OnlineSubspace learns what good
  discriminants look like. Future recalibrations are checked against this
  memory — does the new discriminant match a known good state? Used by
  any entity that has a reckoner — market observers gate their direction
  predictions, brokers gate their Grace/Violence predictions. Same
  mechanism, same four fields, different reckoner, different purpose.

- **ctx** — the immutable world. Lowercase intentionally — ctx is a parameter
  that flows through function calls, not a type you instantiate like Post
  or Treasury. Born at startup. Contains the ThoughtEncoder (which
  contains the VectorManager), dims, recalib-interval. ctx flows in as a
  parameter — the enterprise receives it, posts receive it, observers
  receive it. Nobody owns it. Everybody borrows it. Immutable config is
  separate from mutable state. That's not duplication — that's honesty.
  **The one seam:** the ThoughtEncoder's composition cache is mutable.
  During encoding (parallel), the cache is read-only — misses are returned
  as values. Between candles (sequential), the enterprise inserts collected
  misses into the cache. ctx is immutable DURING a candle. The cache
  updates BETWEEN candles. The seam is bounded by the fold boundary.

- **encode-count** — the candle counter. How many candles the post has
  processed. The window sampler uses it to determine window size each candle.

---

## Forward declarations

The construction order. Each line can only reference what's above it —
those are the things that exist when this thing is constructed. The
constructor calls ARE the dependency graph.

### The path from market to thought

The market produces price data at regular intervals. For one time
period (5 minutes for BTC), five measurements:

- **Open** — price at the start of the period
- **High** — highest price during the period
- **Low** — lowest price during the period
- **Close** — price at the end of the period
- **Volume** — how much was traded during the period

This is a **RawCandle**. Tagged with its asset pair — which market
produced it. The enterprise consumes a stream of these. One per period.

The **IndicatorBank** consumes raw candles and computes technical
indicators — moving averages, oscillators, volatility measures,
momentum, structure. The output is an enriched **Candle** — the raw
data plus 100+ derived measurements. This is what the observers
think about.

### The construction order

This section shows the dependency graph as constructor calls — a sketch.
The "Structs and interfaces" section below is the authority — full field
definitions, full interface signatures. This section shows what depends
on what. That section shows what each thing IS.

```scheme
;; ── Primitives — depend on nothing ──────────────────────────────────

;; Asset: a named token
(struct asset
  [name : String])

(let ((source (make-asset "USDC"))
      (target (make-asset "WBTC"))
      (ts     "2025-01-01T00:00:00")
      (open   96000.0)
      (high   96500.0)
      (low    95800.0)
      (close  96200.0)
      (volume 1500.0))
  (make-raw-candle source target ts
    open high low close volume))                     → RawCandle

(make-indicator-bank)                                → IndicatorBank

(let ((seed 7919)
      (min-window 12)
      (max-window 2016))
  (make-window-sampler seed min-window max-window))  → WindowSampler

(let ((name "trail-distance")
      (encoding :log))
  (make-scalar-accumulator name encoding))           → ScalarAccumulator

;; ── Candle — produced by indicator bank from raw candle ─────────────

(tick indicator-bank raw-candle)                     → Candle

;; ── Vocabulary — pure functions, context in, ASTs out ───────────────
;; Three domains: shared (time), market (direction), exit (conditions)
;; The vocabulary speaks a DSL of ThoughtASTs — data, not execution

(oscillator-facts candle)                            → Vec<ThoughtAST>
;; ThoughtAST: data describing a composition — not vectors, not execution

;; ── ThoughtEncoder — evaluates the vocabulary's ASTs ────────────────

(let ((vector-manager (make-vector-manager dims)))
  (make-thought-encoder vector-manager))             → ThoughtEncoder
(encode thought-encoder ast)                          → (Vector, Vec<(ThoughtAST, Vector)>)

;; ── Label enums ─────────────────────────────────────────────────────
;; Side is action (what the trader does). Direction is observation (what
;; the price did). They are related (Up → Buy, Down → Sell) but distinct
;; types — one is a decision, the other is a measurement.

(enum Side :buy :sell)              ; trading action — on Proposal and Trade
(enum Direction :up :down)          ; price movement — used in propagation
(enum Outcome :grace :violence)     ; accountability — used everywhere

;; ── Newtypes ────────────────────────────────────────────────────────

(newtype TradeId usize)             ; treasury's key for active trades

;; ── Lenses — which vocabulary subset an observer thinks through ─────
;; A lens selects which vocab modules fire. The observer's identity.
;; Each variant selects a subset of the vocabulary. See vocab/ for the modules.
;; :generalist selects ALL modules in the domain.
(enum MarketLens :momentum :structure :volume :narrative :regime :generalist)
(enum ExitLens :volatility :structure :timing :generalist)
;; See Vocabulary section below for lens → module mappings.

;; ── Reckoner — the learning primitive ────────────────────────────────
;; One constructor. Config is data.

(enum reckoner-config
  (Discrete
    labels)            ; Vec<String> — ("Up" "Down")
  (Continuous
    default-value))    ; f64 — the crutch, returned when ignorant
;; dims and recalib-interval are separate parameters to the constructor,
;; not inside the config. The config specifies the readout mode only.
;; This enum is authoritative — no further expansion in Structs and interfaces.

(let ((dims 10000)
      (recalib-interval 500)
      (labels '("Up" "Down")))
  (make-reckoner "direction" dims recalib-interval (Discrete labels)))
                                                     → Reckoner

(let ((dims 10000)
      (recalib-interval 500)
      (default-value 0.015))  ; 0.015 = 1.5% of price — the crutch distance
  (make-reckoner "trail" dims recalib-interval (Continuous default-value)))
                                                     → Reckoner

;; ── Prediction — what a reckoner returns. Data. ─────────────────────
;; The consumer decides what "best" means.

(enum prediction
  (Discrete
    scores             ; Vec<(String, f64)> — (label name, cosine) for each label
    conviction)        ; f64 — how strongly the reckoner leans
  (Continuous
    value              ; f64 — the reckoned scalar
    experience))       ; f64 — how much the reckoner knows (0.0 = ignorant)

;; ── MarketObserver — depends on: Reckoner :discrete, WindowSampler ──

(let ((lens :momentum)
      (dims 10000)
      (recalib-interval 500)
      (seed 7919)
      (min-window 12)
      (max-window 2016)
      (sampler (make-window-sampler seed min-window max-window)))
  (make-market-observer lens dims recalib-interval sampler))
                                                     → MarketObserver

;; ── Distances and Levels — two representations of exit thresholds ────
;; Distances are percentages (from the exit observer — scale-free).
;; Levels are absolute prices (from the post — computed from distance × price).
;; Observers think in Distances. Trades execute at Levels. Different types
;; because they are different concepts with the same four fields.

(struct distances
  [trail : f64]                ; trailing stop distance (percentage of price)
  [stop : f64]                 ; safety stop distance
  [tp : f64]                   ; take-profit distance
  [runner-trail : f64])        ; runner trailing stop distance (wider than trail,
                               ; because the cost of stopping out a runner is zero)

(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64]          ; absolute price level for safety stop
  [take-profit : f64]          ; absolute price level for take-profit
  [runner-trail-stop : f64])   ; absolute price level for runner trailing stop
;; Distances are percentages (from exit observer). Levels are prices
;; (computed by the post: distance × current price → level). Trade
;; stores Levels. Proposal carries Distances. Different concepts.

;; ── ExitObserver — depends on: Reckoner :continuous (×4), Distances ──

(let ((lens :volatility)
      (dims 10000)
      (recalib-interval 500)
      (default-trail 0.015)
      (default-stop  0.030)
      (default-tp    0.045)
      (default-runner-trail 0.030))  ; wider than trail — zero cost basis
  (make-exit-observer lens dims recalib-interval
    default-trail default-stop default-tp default-runner-trail))
                                                     → ExitObserver

;; ── PaperEntry — hypothetical trade inside a broker ──────────
;; A paper trade is a "what if." Every candle, every pair gets one.
;; It tracks what WOULD have happened if a trade was opened here.
;; Both sides (buy and sell) are tracked simultaneously.
;; When both sides resolve (their trailing stops fire), the paper
;; teaches the system: what distance would have been optimal?
;;
;; distances.trail drives the paper's trailing stops (buy-trail-stop,
;; sell-trail-stop). The other three (stop, tp, runner-trail) are stored
;; for the learning signal — when the paper resolves, the Resolution
;; carries optimal-distances (what hindsight says was best). The
;; predicted distances at entry vs the optimal distances at resolution
;; IS the teaching: "you predicted trail=0.015 but optimal was 0.022."

(struct paper-entry
  [composed-thought : Vector]  ; the thought at entry
  [entry-price : f64]          ; price when the paper was created
  [distances : Distances]      ; from the exit observer at entry
  [buy-extreme : f64]          ; best price in buy direction so far
  [buy-trail-stop : f64]       ; trailing stop level (from distances.trail)
  [sell-extreme : f64]         ; best price in sell direction so far
  [sell-trail-stop : f64]      ; trailing stop level (from distances.trail)
  [buy-resolved : bool]        ; buy side's stop fired
  [sell-resolved : bool])      ; sell side's stop fired

;; ── Broker — depends on: Reckoner :discrete, ScalarAccumulator ──────
;; :log below is a ScalarEncoding variant (defined in ScalarAccumulator section).
;; It means: encode values with encode-log (ratios compress naturally).

(let ((observers '("momentum" "volatility"))
      (slot-idx 0)             ; position in the N×M grid, assigned by the post
      (exit-count 4)           ; M — number of exit observers
      (dims 10000)
      (recalib-interval 500))
  (make-broker observers slot-idx exit-count dims recalib-interval
    (list (make-scalar-accumulator "trail-distance" :log)
          (make-scalar-accumulator "stop-distance" :log)
          (make-scalar-accumulator "tp-distance" :log)
          (make-scalar-accumulator "runner-trail-distance" :log))))
                                                     → Broker

;; ── Proposal — what a post produces, what the treasury evaluates ────

;; Assembled by the post during step-compute-dispatch. The post calls:
;;   market observer → thought vector
;;   exit observer → evaluate-and-compose(thought, fact-asts, ctx) → composed + distances
;;   broker → propose(composed) → prediction
;;   post bundles these into a Proposal and submits to treasury.
(struct proposal
  [composed-thought : Vector]  ; market thought + exit facts
  [distances : Distances]      ; from the exit observer
  [edge : f64]                 ; the broker's edge. [0.0, 1.0]. Accuracy from
                               ; the broker's curve at its current conviction.
                               ; 0.0 when unproven.
                               ; This IS the edge from the message protocol.
                               ; The treasury sorts proposals by this value and
                               ; funds proportionally — more edge, more capital.
  [side : Side]                ; :buy or :sell — trading action, from the market observer's
                               ; Up/Down prediction. Up → :buy, Down → :sell.
                               ; Distinct from "direction" (:up/:down) which describes
                               ; price movement used in propagation.
  [source-asset : Asset]       ; what is deployed (e.g. USDC)
  [target-asset : Asset]       ; what is acquired (e.g. WBTC)
  [post-idx : usize]           ; which post this came from
  [broker-slot-idx : usize])   ; which broker proposed this

;; ── TradePhase — the state machine of a position's lifecycle ─────────

(enum trade-phase
  :active              ; capital reserved, all stops live
  :runner              ; residue riding, principal already returned
  :settled-violence    ; stop-loss fired — bounded loss
  :settled-grace)      ; runner trail fired — residue is permanent gain

;; ── Trade — an active position the treasury holds ───────────────────

(struct trade
  [id : TradeId]               ; assigned by treasury at funding time.
                               ; The trade's name. It travels with the trade —
                               ; TreasurySettlement, log entries, routing. A Trade that
                               ; can't say its own name is half a value.
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker (for trigger routing)
  [phase : TradePhase]         ; :active → :runner → :settled-*
  [source-asset : Asset]       ; what was deployed
  [target-asset : Asset]       ; what was acquired
  [side : Side]                ; copied from the funding Proposal at treasury funding time
  [entry-rate : f64]
  [source-amount : f64]        ; how much was deployed
  [stop-levels : Levels]       ; current trailing stop, safety stop, take-profit
                               ; absolute price levels, updated by step 3c
  [candles-held : usize]       ; how long open
  [price-history : Vec<f64>])  ; close prices from entry to now. Appended each
                               ; candle. The trade closes over its own history. Pure.

;; ── TreasurySettlement — what the treasury produces when a trade closes ──

(struct treasury-settlement
  [trade : Trade]              ; which trade closed (carries post-idx, broker-slot-idx, side)
  [exit-price : f64]           ; price at settlement
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value gained or lost
  [composed-thought : Vector]  ; from trade-origins, stashed at funding time
  [prediction : Prediction])   ; from trade-origins — the broker's verdict at funding time.
                               ; The learning pair: prediction (what the enterprise believed)
                               ; + outcome (what actually happened). The audit trail.
;; The treasury produces this. It does NOT have optimal-distances.

;; ── Resolution — what a broker produces when a paper resolves ────────
;; Facts, not mutations. Collected from parallel tick, applied sequentially.
;; A paper has two sides (buy and sell). Each side resolves independently.
;; Each resolved side produces one Resolution with its own direction.

(struct resolution
  [broker-slot-idx : usize]    ; which broker produced this
  [composed-thought : Vector]  ; the thought that was tested
  [direction : Direction]      ; :up or :down. Each paper side resolves
                               ; independently: buy-side stop fires → :up (price rose
                               ; then retraced). sell-side stop fires → :down.
                               ; The direction matches the side that was TESTED, not
                               ; the outcome — a buy-side paper only triggers because
                               ; price moved up, so direction is :up regardless of
                               ; whether outcome was Grace or Violence.
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value
  [optimal-distances : Distances]) ; hindsight optimal

;; ── LogEntry — the glass box. What happened. ────────────────────────
;; Generic. Each function returns its log entries as values.

(enum log-entry
  (ProposalSubmitted
    broker-slot-idx    ; usize
    composed-thought   ; Vector
    distances)         ; Distances
  (ProposalFunded
    trade-id           ; TradeId
    broker-slot-idx    ; usize
    amount-reserved)   ; f64
  (ProposalRejected
    broker-slot-idx    ; usize
    reason)            ; String
  (TradeSettled
    trade-id           ; TradeId
    outcome            ; :grace or :violence
    amount             ; f64
    duration           ; usize — candles held
    prediction)        ; Prediction — from TradeOrigin. The learning pair:
                       ; what the enterprise believed at funding + what happened.
  (PaperResolved
    broker-slot-idx    ; usize
    outcome            ; :grace or :violence
    optimal-distances) ; Distances
  (Propagated
    broker-slot-idx    ; usize
    observers-updated)); usize — how many observers received the outcome

;; ── TradeOrigin — where a trade came from, for propagation routing ───

(struct trade-origin
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker
  [composed-thought : Vector]  ; the thought at entry
  [prediction : Prediction])   ; :discrete (Grace/Violence) — the broker's prediction
                               ; at funding time. The archaeological record of WHY this
                               ; trade exists. Belongs here alongside composed-thought,
                               ; not on the funding request (Proposal).

;; ── Post — depends on: IndicatorBank, MarketObserver, ExitObserver, Broker ──

(let ((source (make-asset "USDC"))
      (target (make-asset "WBTC"))
      (dims 10000)
      (recalib-interval 500)
      (max-window-size 2016))
  (make-post post-idx source target dims recalib-interval max-window-size
    (make-indicator-bank)
    market-observers exit-observers registry))       → Post

;; ── Treasury — pure accounting ──────────────────────────────────────

(let ((denomination (make-asset "USD"))
      (initial-balances (map-of (make-asset "USDC") 10000.0))
      (swap-fee 0.0010)
      (slippage 0.0025))
  (make-treasury denomination initial-balances swap-fee slippage))
                                                     → Treasury

;; ── Ctx — the immutable world. Born at startup. ────────────────────
;; Immutable DURING each candle. The ThoughtEncoder's composition cache
;; is the one seam — updated BETWEEN candles from collected misses.

(struct ctx              ; this is the complete set — three fields, nothing else
  [thought-encoder : ThoughtEncoder] ; contains VectorManager + composition cache (the seam)
  [dims : usize]                     ; vector dimensionality
  [recalib-interval : usize])        ; observations between recalibrations

;; ── Enterprise — the coordination plane ─────────────────────────────

(let ((posts (list btc-post sol-post))
      (treasury (make-treasury denomination balances swap-fee slippage)))
  (make-enterprise posts treasury))                  → Enterprise
;; ctx is separate — created by the binary, passed to on-candle
```

---

## Structs and interfaces

### RawCandle (the input — depends on: nothing)

The enterprise consumes a stream of raw candles. This is the only input.
Everything else is derived. Each raw candle identifies its asset pair —
the pair IS the routing key. Only the post for that pair receives it.

```
(struct raw-candle
  [source-asset : Asset]   ; e.g. USDC
  [target-asset : Asset]   ; e.g. WBTC
  [ts : String]
  [open : f64]
  [high : f64]
  [low : f64]
  [close : f64]
  [volume : f64])
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
  [ts : String] [open : f64] [high : f64] [low : f64] [close : f64] [volume : f64]
  ;; Raw fields are retained on the enriched Candle. The vocabulary currently
  ;; reads only derived indicators, but the binary writes raw values to the
  ;; ledger, and future vocabulary modules (volume profile, gap detection,
  ;; session boundaries) will need them. Dropping input information because
  ;; it's not consumed now has always backfired. The cost of carrying it is small.
  ;; Moving averages
  [sma20 : f64] [sma50 : f64] [sma200 : f64]
  ;; Bollinger
  [bb-upper : f64] [bb-lower : f64] [bb-width : f64] [bb-pos : f64]
  ;; bb-upper/lower retained. The vocabulary reads bb-pos and bb-width, but
  ;; the raw bounds carry information future observers may need (breakout
  ;; detection, band touch events). Derivable from pos + width + close, but
  ;; carrying them avoids reconstruction.
  ;; RSI, MACD, DMI, ATR
  [rsi : f64] [macd : f64] [macd-signal : f64] [macd-hist : f64]
  [plus-di : f64] [minus-di : f64] [adx : f64] [atr : f64] [atr-r : f64]
  ;; Stochastic, CCI, MFI, OBV, Williams %R
  [stoch-k : f64] [stoch-d : f64] [williams-r : f64] [cci : f64] [mfi : f64]
  [obv-slope-12 : f64]         ; 12-period linear regression slope of OBV
  [volume-accel : f64]            ; volume / volume_sma20 — volume acceleration
  ;; Keltner (computed from ema20 + atr on the bank), squeeze
  [kelt-upper : f64] [kelt-lower : f64] [kelt-pos : f64]
  [squeeze : f64]            ; bb-width / kelt-width ratio — continuous, not bool
  ;; Rate of Change
  [roc-1 : f64] [roc-3 : f64] [roc-6 : f64] [roc-12 : f64]
  ;; ATR rate of change
  [atr-roc-6 : f64] [atr-roc-12 : f64]  ; how is volatility changing?
  ;; Trend consistency
  [trend-consistency-6 : f64] [trend-consistency-12 : f64] [trend-consistency-24 : f64]
  ;; Range position
  [range-pos-12 : f64] [range-pos-24 : f64] [range-pos-48 : f64]
  ;; Multi-timeframe
  [tf-1h-close : f64] [tf-1h-high : f64] [tf-1h-low : f64] [tf-1h-ret : f64] [tf-1h-body : f64]
  [tf-4h-close : f64] [tf-4h-high : f64] [tf-4h-low : f64] [tf-4h-ret : f64] [tf-4h-body : f64]
  ;; Ichimoku
  [tenkan-sen : f64] [kijun-sen : f64] [senkou-span-a : f64] [senkou-span-b : f64] [cloud-top : f64] [cloud-bottom : f64]
  ;; senkou-span-a/b retained. The vocabulary reads cloud-top/bottom (the
  ;; max/min), but the raw spans carry information the vocabulary may need
  ;; later (span crossover, span direction). The cost of the fields is small.
  ;; The cost of reconstructing the spans from the tick function would require
  ;; re-computing Ichimoku's 52-period midpoints.
  ;; Persistence (pre-computed by IndicatorBank from ring buffers)
  [hurst : f64]                ; Hurst exponent — trending vs mean-reverting
  [autocorrelation : f64]      ; lag-1 autocorrelation — signed
  [vwap-distance : f64]        ; (close - VWAP) / close — signed distance
  ;; Regime (pre-computed by IndicatorBank — regime.wat needs these)
  [kama-er : f64]              ; Kaufman Adaptive Moving Average Efficiency Ratio [0, 1]
  [choppiness : f64]           ; Choppiness Index [0, 100] — high = choppy, low = trending
  [dfa-alpha : f64]            ; Detrended Fluctuation Analysis exponent
  [variance-ratio : f64]       ; variance at scale N / (N × variance at scale 1)
  [entropy-rate : f64]         ; conditional entropy of discretized returns
  [aroon-up : f64]             ; Aroon up [0, 100] — how recent was the highest high?
  [aroon-down : f64]           ; Aroon down [0, 100] — how recent was the lowest low?
  [fractal-dim : f64]          ; fractal dimension — 1.0 trending, 2.0 noisy
  ;; Divergence (pre-computed by IndicatorBank from PELT peaks — divergence.wat)
  [rsi-divergence-bull : f64]  ; bullish divergence magnitude (price lower, RSI higher)
  [rsi-divergence-bear : f64]  ; bearish divergence magnitude (price higher, RSI lower)
  ;; Ichimoku cross delta (ichimoku.wat)
  [tk-cross-delta : f64]       ; (tenkan - kijun) change from prev candle — signed
  ;; Stochastic cross delta (stochastic.wat)
  [stoch-cross-delta : f64]    ; (%K - %D) change from prev candle — signed
  ;; Price action (pre-computed by IndicatorBank — price-action.wat)
  [range-ratio : f64]          ; current range / prev range. < 1 = compression, > 1 = expansion
  [gap : f64]                  ; signed — (open - prev close) / prev close
  [consecutive-up : f64]       ; run count of consecutive bullish closes
  [consecutive-down : f64]     ; run count of consecutive bearish closes
  ;; Timeframe agreement (timeframe.wat)
  [tf-agreement : f64]         ; inter-timeframe agreement score — 5m/1h/4h direction alignment
  ;; Time — circular scalars (encode-circular)
  [minute : f64]             ; mod 60
  [hour : f64]               ; mod 24
  [day-of-week : f64]        ; mod 7
  [day-of-month : f64]       ; mod 31
  [month-of-year : f64])     ; mod 12
  ;; ... additional fields computed by IndicatorBank as the vocabulary grows.
  ;; This struct lists the current set. "100+" in the definitions is the
  ;; target — the actual count grows with the vocabulary.
```

---

### IndicatorBank (depends on: RawCandle)

Streaming state machine. Advances all indicators by one raw candle.
Stateful — ring buffers, EMA accumulators, Wilder smoothers.
One per post (one per asset pair).

The streaming primitives — the building blocks of indicator state:

```
;; Leaves — depend on nothing
(struct ring-buffer
  [data     : Vec<f64>]
  [capacity : usize]
  [head     : usize]
  [len      : usize])

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(struct wilder-state
  [value  : f64]
  [period : usize]
  [count  : usize]
  [accum  : f64])

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])  ; for computing obv-slope-12 via linear regression

;; Depend on RingBuffer
(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64])
;; period is the buffer's capacity — one source of truth, not two.

(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64])
;; period is the buffer's capacity.

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])  ; %K history for computing %D (3-period SMA of %K)

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(struct ichimoku-state
  [high-9  : RingBuffer]  [low-9  : RingBuffer]
  [high-26 : RingBuffer]  [low-26 : RingBuffer]
  [high-52 : RingBuffer]  [low-52 : RingBuffer])

;; Depend on EmaState
(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(struct dmi-state
  [plus-smoother  : WilderState]
  [minus-smoother : WilderState]
  [tr-smoother    : WilderState]
  [adx-smoother   : WilderState]
  [prev-high      : f64]
  [prev-low       : f64]
  [prev-close     : f64]
  [started        : bool]
  [count          : usize])
;; period is implicit in the WilderState smoothers — one source of truth.
```

The indicator bank — composed from the streaming primitives:

```
(struct indicator-bank
  ;; Moving averages
  [sma20  : SmaState]
  [sma50  : SmaState]
  [sma200 : SmaState]
  [ema20  : EmaState]         ; internal — for Keltner channel computation
  ;; Bollinger
  [bb-stddev : RollingStddev]
  ;; Oscillators
  [rsi  : RsiState]
  [macd : MacdState]
  [dmi  : DmiState]
  [atr  : AtrState]
  [stoch : StochState]
  [cci  : CciState]
  [mfi  : MfiState]
  [obv  : ObvState]
  [volume-sma20 : SmaState]   ; internal — for volume ratio computation in flow vocab
  ;; ROC
  [roc-buf : RingBuffer]      ; 12-period close buffer — ROC 1/3/6/12 index into this
  ;; Range position
  [range-high-12 : RingBuffer]  [range-low-12 : RingBuffer]
  [range-high-24 : RingBuffer]  [range-low-24 : RingBuffer]
  [range-high-48 : RingBuffer]  [range-low-48 : RingBuffer]
  ;; Trend consistency
  [trend-buf-24 : RingBuffer]
  ;; ATR history
  [atr-history : RingBuffer]  ; for computing atr-r (ATR ratio) on Candle
  ;; Multi-timeframe
  [tf-1h-buf  : RingBuffer]  [tf-1h-high : RingBuffer]  [tf-1h-low : RingBuffer]
  [tf-4h-buf  : RingBuffer]  [tf-4h-high : RingBuffer]  [tf-4h-low : RingBuffer]
  ;; Ichimoku
  [ichimoku : IchimokuState]
  ;; Persistence — pre-computed from ring buffers
  [close-buf-48 : RingBuffer]  ; 48 closes for Hurst + autocorrelation
  ;; VWAP — running accumulation
  [vwap-cum-vol : f64]         ; cumulative volume
  [vwap-cum-pv  : f64]         ; cumulative price × volume
  ;; Regime — state for regime.wat fields
  [kama-er-buf : RingBuffer]   ; 10-period close buffer for KAMA efficiency ratio
  [chop-atr-sum : f64]         ; running sum of ATR over choppiness period
  [chop-buf : RingBuffer]      ; 14-period ATR buffer for Choppiness Index
  [dfa-buf : RingBuffer]       ; close buffer for Detrended Fluctuation Analysis
  [var-ratio-buf : RingBuffer] ; close buffer for variance ratio (two scales)
  [entropy-buf : RingBuffer]   ; discretized return buffer for conditional entropy
  [aroon-high-buf : RingBuffer] ; 25-period high buffer for Aroon up
  [aroon-low-buf : RingBuffer]  ; 25-period low buffer for Aroon down
  [fractal-buf : RingBuffer]   ; close buffer for fractal dimension (Higuchi or box-counting)
  ;; Divergence — state for divergence.wat fields
  [rsi-peak-buf : RingBuffer]  ; recent RSI values for PELT peak detection
  [price-peak-buf : RingBuffer] ; recent close values aligned with RSI for divergence
  ;; Ichimoku cross delta — prev TK spread
  [prev-tk-spread : f64]       ; (tenkan - kijun) from previous candle
  ;; Stochastic cross delta — prev K-D spread
  [prev-stoch-kd : f64]        ; (stoch-k - stoch-d) from previous candle
  ;; Price action — state for price-action.wat fields
  [prev-range : f64]           ; previous candle range (high - low) for range-ratio
  [consecutive-up-count : usize]  ; running count of consecutive bullish closes
  [consecutive-down-count : usize] ; running count of consecutive bearish closes
  ;; Timeframe agreement — prev returns for direction comparison
  [prev-tf-1h-ret : f64]       ; previous 1h return for direction tracking
  [prev-tf-4h-ret : f64]       ; previous 4h return for direction tracking
  ;; Previous values
  [prev-close : f64]
  ;; Counter
  [count : usize])
```

**The tick contract** — what each computation IS, its parameters, its output:

```
Moving averages:
  SMA:  simple moving average. Periods: 20, 50, 200.
  EMA:  exponential moving average. Period: 20 (internal — for Keltner channel).

Bollinger Bands:
  bb-upper/lower = SMA(20) ± 2 × rolling-stddev(20).
  bb-width = (upper - lower) / close. bb-pos = (close - lower) / (upper - lower).

Oscillators:
  RSI:   Wilder-smoothed relative strength, period 14. Raw [0, 100].
  MACD:  fast EMA(12) - slow EMA(26). Signal = EMA(9) of MACD. Hist = MACD - signal.
  Stoch: %K = (close - low14) / (high14 - low14) × 100. %D = SMA(3) of %K.
  CCI:   (typical-price - SMA(tp, 20)) / (0.015 × mean-deviation). Period 20.
  MFI:   money-flow-ratio over 14 periods. Positive/negative flow by typical-price direction.
  Williams %R: (highest14 - close) / (highest14 - lowest14) × -100.

Directional movement:
  DMI:   Wilder-smoothed +DI, -DI, ADX. Period 14. ADX smoothed from DX.
  ATR:   Wilder-smoothed true range, period 14. atr-r = atr / close.

Volume:
  OBV:   cumulative on-balance-volume. obv-slope-12 = 12-period linear regression slope.
  volume-accel: volume / SMA(volume, 20). Ratio — how unusual is current volume.

Ichimoku:
  tenkan-sen = midpoint of high/low over 9 periods.
  kijun-sen = midpoint of high/low over 26 periods.
  senkou-span-a = (tenkan + kijun) / 2.
  senkou-span-b = midpoint of high/low over 52 periods.
  cloud-top = max(senkou-a, senkou-b). cloud-bottom = min.

Rate of change:
  ROC-N = (close - close_N_ago) / close_N_ago. Periods: 1, 3, 6, 12. Buffer capacity: 12.
  ATR ROC: same formula applied to ATR. Periods: 6, 12.

Range position:
  range-pos-N = (close - lowest-N) / (highest-N - lowest-N). Periods: 12, 24, 48.

Trend consistency:
  Fraction of candles in a window where close > prev-close. Periods: 6, 12, 24.

Multi-timeframe:
  1h = aggregate 12 5-min candles. 4h = aggregate 48. Emit close, high, low, return, body-ratio.
  tf-agreement: directional agreement score across 5m/1h/4h returns.

Persistence:
  Hurst exponent: R/S analysis over close buffer(48). >0.5 trending, <0.5 mean-reverting.
  Autocorrelation: lag-1 autocorrelation of close buffer(48). Signed.
  VWAP distance: (close - cumulative-VWAP) / close. Signed.

Regime:
  KAMA-ER: Kaufman efficiency ratio over 10-period close buffer. [0, 1].
  Choppiness: 100 × log(sum(ATR, 14) / range(14)) / log(14). [0, 100].
  DFA-alpha: detrended fluctuation analysis exponent over close buffer(48).
  Variance-ratio: variance at scale N / (N × variance at scale 1). Close buffer(30).
  Entropy-rate: conditional entropy of discretized returns over buffer(30).
  Aroon-up/down: 100 × (25 - periods-since-highest/lowest) / 25. Period 25.
  Fractal-dim: box-counting or Higuchi method over close buffer(30). 1.0 trending, 2.0 noisy.

Divergence:
  RSI divergence: PELT peak detection on price and RSI buffers.
  Bull: price makes lower low, RSI makes higher low. Bear: opposite.
  Magnitude = absolute difference in slopes.

Cross deltas:
  tk-cross-delta = (tenkan - kijun) change from prev candle. Signed.
  stoch-cross-delta = (%K - %D) change from prev candle. Signed.

Price action:
  range-ratio: current range / prev range. Compression vs expansion.
  gap: (open - prev-close) / prev-close. Signed.
  consecutive-up/down: run count of bullish/bearish closes.

Time:
  minute (mod 60), hour (mod 24), day-of-week (mod 7),
  day-of-month (mod 31), month-of-year (mod 12).
  Parsed from the timestamp string on the raw candle.
```

Each line is the tick contract for that indicator family. The inscribe
writes the implementation. The parameters are specified here — not in
the Rust, not in the wat comments. Here. One source of truth.

**Interface:**
- `(make-indicator-bank) → IndicatorBank`
- `(tick indicator-bank raw-candle) → Candle`

---

### WindowSampler (depends on: nothing)

Deterministic log-uniform window selection. Each market observer has its
own — its own seed, its own time scale. The observer uses it every candle
to decide how much history to look at.

Owned by the market observer. Not by the enterprise. Not shared.
The enterprise doesn't sample windows — the observers do.

When window sampling becomes learned, the feedback routes through the
same resolution mechanism that teaches everything else. "This window size
produced Grace." The system knows. It routes back to the market observer.
The market observer adjusts its sampler.

```
(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])
```

**Interface:**
- `(make-window-sampler seed min max) → WindowSampler`
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
  MarketLens → modules (every lens also includes shared/time + standard):
  - `:momentum` → oscillators, momentum, stochastic
  - `:structure` → keltner, fibonacci, ichimoku, price-action
  - `:volume` → flow
  - `:narrative` → timeframe, divergence
  - `:regime` → regime, persistence
  - `:generalist` → all of the above
  Files and atom lists (every atom each module MUST emit):
  - `oscillators.wat` — oscillator positions as scalars
    atoms: `rsi`, `cci`, `mfi`, `williams-r`, `roc-1`, `roc-3`, `roc-6`, `roc-12`
  - `flow.wat` — volume and pressure
    atoms: `obv-slope`, `vwap-distance`, `buying-pressure`, `selling-pressure`,
           `volume-ratio`, `body-ratio`
  - `persistence.wat` — memory in the series
    atoms: `hurst`, `autocorrelation`, `adx`
  - `regime.wat` — what KIND of market this is
    atoms: `kama-er`, `choppiness`, `dfa-alpha`, `variance-ratio`,
           `entropy-rate`, `aroon-up`, `aroon-down`, `fractal-dim`
  - `divergence.wat` — RSI divergence via structural peaks
    atoms: `rsi-divergence-bull`, `rsi-divergence-bear`, `divergence-spread`
  - `ichimoku.wat` — cloud position, TK cross, distances
    atoms: `cloud-position`, `cloud-thickness`, `tk-cross-delta`, `tk-spread`,
           `tenkan-dist`, `kijun-dist`
  - `stochastic.wat` — %K/%D spread and crosses
    atoms: `stoch-k`, `stoch-d`, `stoch-kd-spread`
  - `fibonacci.wat` — retracement level distances
    atoms: `range-pos-12`, `range-pos-24`, `range-pos-48`,
           `fib-dist-236`, `fib-dist-382`, `fib-dist-500`, `fib-dist-618`, `fib-dist-786`
  - `keltner.wat` — channel positions, squeeze
    atoms: `bb-pos`, `bb-width`, `kelt-pos`, `squeeze`,
           `kelt-upper-dist`, `kelt-lower-dist`
  - `momentum.wat` — trend-relative, MACD, DI
    atoms: `close-sma20`, `close-sma50`, `close-sma200`,
           `macd-hist`, `di-spread`, `atr-ratio`
  - `price-action.wat` — candlestick anatomy, range, gaps
    atoms: `range-ratio`, `gap`, `consecutive-up`, `consecutive-down`,
           `body-ratio-pa`, `upper-wick`, `lower-wick`
  - `timeframe.wat` — 1h/4h structure + inter-timeframe agreement
    atoms: `tf-1h-trend`, `tf-1h-ret`, `tf-4h-trend`, `tf-4h-ret`,
           `tf-agreement`, `tf-5m-1h-align`
  - `standard.wat` — universal context for all market observers.
    Reads the candle WINDOW (not just the current candle) for recency
    and distance computations. Interface: `(encode-standard-facts candle-window) → Vec<ThoughtAST>`.
    atoms: `since-rsi-extreme`, `since-vol-spike`, `since-large-move`,
           `dist-from-high`, `dist-from-low`, `dist-from-midpoint`,
           `dist-from-sma200`, `session-depth`

  Every MarketLens variant includes `shared/time` AND `standard` automatically.
  The generalist includes ALL modules above.

- **exit/** — whether CONDITIONS favor trading. Distance signal. Exit observers use these.
  ExitLens → modules:
  - `:volatility` → volatility.wat — ATR regime, ATR ratio, squeeze state
    atoms: `atr-ratio`, `atr-r`, `atr-roc-6`, `atr-roc-12`, `squeeze`, `bb-width`
  - `:structure` → structure.wat — trend consistency, ADX strength
    atoms: `trend-consistency-6`, `trend-consistency-12`, `trend-consistency-24`,
           `adx`, `exit-kama-er`
  - `:timing` → timing.wat — momentum state, reversal signals
    atoms: `rsi`, `stoch-k`, `stoch-kd-spread`, `macd-hist`, `cci`
  - `:generalist` → all three (volatility + structure + timing)

**Interface (per module):**
- `(encode-<domain>-facts candle) → Vec<ThoughtAST>`
  e.g. `(encode-oscillator-facts candle)`, `(encode-flow-facts candle)`.
  Each module is a pure function: candle in, ASTs out. The observer
  calls the modules matching its lens, collects the ASTs, and passes
  them to evaluate-and-compose.

Each lens maps to multiple vocabulary modules. The observer calls each
module for its lens, appends the resulting AST lists into one
Vec<ThoughtAST>, then wraps in a Bundle for encoding. Example:
`:momentum` calls encode-oscillator-facts, encode-momentum-facts, and
encode-stochastic-facts, then appends all three lists.

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

Lives on ctx — the immutable world created at startup. Passed to posts
via ctx on every on-candle call. The enterprise does not own it directly.

```
(struct thought-encoder
  [atoms : Map<String, Vector>]          ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>]) ; optimistic, self-evicting
;; The cache is eventually-consistent: encode returns misses as values
;; during parallel encoding, the enterprise collects all misses and
;; inserts them after all steps complete (miss on candle N, hit on N+1).
;; WHY: the cache mutates on miss, but ctx is immutable. This is the
;; one seam. The parallel phase returns misses as values. The sequential
;; phase inserts. No locks during encoding. No queues. Values up.
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
- `(encode thought-encoder ast) → (Vector, Vec<(ThoughtAST, Vector)>)`
  On cache hit: return the vector and an empty misses list. On cache miss:
  compute the vector, return it AND the (ast, vector) pair in the misses list.
  The caller collects all misses. The enterprise collects them from each step's
  return values and inserts into the cache after all steps complete.
  The encode function NEVER writes to the cache. Values up, not queues down.

One function. Recursive. Cache at every node. The cache key IS the AST
node — its structure is its identity. Same structure, same vector.

```scheme
(define (encode encoder ast)
  (let ((no-misses '()))
    (when-let ((cache-hit (get (:compositions encoder) ast)))
      (list cache-hit no-misses))             ;; found in cache → return vector, nothing to learn
  (let (((result misses)
          (match ast
            ((Atom name)
              (list (lookup-atom (:atoms encoder) name) '()))

            ((Linear name value scale)
              (let (((atom-vec atom-misses) (encode encoder (Atom name))))
                (list (bind atom-vec (encode-linear value scale))
                      atom-misses)))

            ((Log name value)
              (let (((atom-vec atom-misses) (encode encoder (Atom name))))
                (list (bind atom-vec (encode-log value))
                      atom-misses)))

            ((Circular name value period)
              (let (((atom-vec atom-misses) (encode encoder (Atom name))))
                (list (bind atom-vec (encode-circular value period))
                      atom-misses)))

            ((Bind left right)
              (let (((l-vec l-misses) (encode encoder left))
                    ((r-vec r-misses) (encode encoder right)))
                (list (bind l-vec r-vec)
                      (append l-misses r-misses))))

            ((Bundle children)
              (let ((pairs (map (lambda (c) (encode encoder c)) children)))
                (list (apply bundle (map first pairs))
                      (apply append (map second pairs))))))))

    (list result (cons (list ast result) misses))))
```

The vocabulary produces QUOTED expressions — data, not execution. The
encoder evaluates them. The vocabulary doesn't know about caching. The
encoder doesn't know about RSI. The quoted list is the interface.

The observer composes the thought:
```
observer calls vocab(context)                → Vec<ThoughtAST>  ; AST nodes
observer wraps in (Bundle facts)             → ThoughtAST      ; still data
observer calls (encode encoder bundle-ast)   → (Vector, misses) ; the thought + cache misses
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

### Distances (depends on: nothing)

The four exit values. A named tuple. Percentage of price, not absolute
levels. Appears on PaperEntry, Proposal, and Resolution. The
post converts Distances to Levels (trail-stop, safety-stop, take-profit,
runner-trail-stop on Trade) using the current price.

Defined in the forward declarations section (search for `struct distances`).
Four f64 fields: trail, stop, tp, runner-trail.

**Interface:**
- `(distances-to-levels distances price side) → Levels`
  Converts percentage distances to absolute price levels. Side-dependent:
  buy stops are below price, sell stops are above. One place to get the
  signs right.

---

### ScalarAccumulator (depends on: Outcome enum)

Per-magic-number f64 learning. Lives on the broker. Global per-pair.
Each distance (trail, stop, tp, runner-trail) gets its own.

Separates grace/violence observations into separate f64 prototypes.
Grace outcomes accumulate one way. Violence outcomes accumulate the other.
Extract recovers the value Grace prefers — sweep candidate values against
the Grace accumulator, find the one with highest cosine. "What value does
Grace prefer for this pair overall?" One answer regardless of thought.

Fed by resolution events: when a paper or trade resolves, the
broker routes the optimal distance + Grace/Violence outcome to its
scalar accumulators.

```
(enum scalar-encoding
  :log                           ; no params — log compresses naturally
  (Linear [scale : f64])         ; encode-linear scale
  (Circular [period : f64]))     ; encode-circular period

(struct scalar-accumulator
  [name : String]              ; which magic number ("trail-distance", etc.).
                               ; Diagnostic label. The binary reads it for human-readable
                               ; log entries and progress display. e.g. "trail-distance",
                               ; "stop-distance".
  [encoding : ScalarEncoding]  ; configured at construction — the data and
                               ; its interpretation travel together
  [grace-acc : Vector]         ; accumulated encoded values from Grace outcomes
  [violence-acc : Vector]      ; accumulated encoded values from Violence outcomes
  [count : usize])             ; number of observations. 0 = no data.
```

**Interface:**
- `(make-scalar-accumulator name encoding) → ScalarAccumulator`
  encoding: ScalarEncoding — determines how values are encoded.
- `(observe-scalar acc value outcome weight)`
  value: f64 — the scalar to accumulate (e.g. a distance).
  Encoded via the accumulator's ScalarEncoding — pattern-match on the
  enum to dispatch. Distances use :log (ratios compress naturally).
  observe and extract use the SAME encoding — it's on the struct.
  outcome: Outcome — :grace or :violence. Determines which accumulator
  receives the encoded value.
  weight: f64 — scales the contribution. Larger weight = stronger signal.
- `(extract-scalar acc steps range) → f64`
  steps: usize — how many candidates to try.
  range: (f64, f64) — (min, max) bounds to sweep across.
  Sweep `steps` candidate values across `range`, encode each, cosine
  against the Grace prototype. Return the candidate closest to Grace.

---

### Simulation (depends on: Distances)

Pure functions that simulate trailing stop mechanics against price
histories. `simulation.wat`. No post state. Vec<f64> in, f64 out.

- `(compute-optimal-distances price-history direction) → Distances`
  direction: Direction — :up or :down. Which way the price moved.
  This is observation (what the price did), not action (what the trader did).
  Takes no self. Pure.
  **The objective function:** for each distance (trail, stop, tp, runner-trail),
  sweep candidate values against the price-history. For each candidate,
  simulate the trailing stop mechanics. The candidate that produces the
  maximum residue IS the optimal distance. This is a well-posed optimization
  over a finite series — not a heuristic. The exit observer learns to predict
  this value BEFORE the path completes. The wat may approximate this
  optimization (e.g. MFE/MAE ratios) but the objective is: maximize residue.
  price-history in, Distances out.
  Called by the enterprise during step 1 (resolve and propagate).
- `(best-distance price-history simulate-fn) → f64`
  Sweep candidates, evaluate each via simulate-fn, return the best.
- `(simulate-trail price-history distance) → f64`
  Simulate a trailing stop at the given distance. Returns residue.
- `(simulate-stop price-history distance) → f64`
  Simulate a safety stop at the given distance. Returns residue.
- `(simulate-tp price-history distance) → f64`
  Simulate a take-profit at the given distance. Returns residue.
- `(simulate-runner-trail price-history distance) → f64`
  Simulate a runner trailing stop at the given distance. Returns residue.

All pure. Vec<f64> in, f64 out. No post state.

---

### MarketObserver (depends on: Reckoner, OnlineSubspace, WindowSampler)

Predicts direction. Learned. Labels come from broker propagation —
Predicts Up/Down. The broker routes the actual direction back from
resolved paper and real trades. The market observer does NOT label itself.
Reality labels it.

The generalist is just another lens. No special treatment.

```
(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]                ; :discrete — Up/Down
  [noise-subspace : OnlineSubspace]    ; background model
  [window-sampler : WindowSampler]     ; own time scale
  ;; Proof tracking
  [resolved : usize]                   ; how many predictions have been resolved
  ;; The reckoner carries its own curve. resolve() feeds it. edge-at() reads it.
  ;; No separate curve field — use (edge-at (:reckoner obs) conviction) and
  ;; (proven? (:reckoner obs) min-samples).
  ;; Engram gating
  [good-state-subspace : OnlineSubspace] ; learns what good discriminants look like
  [recalib-wins : usize]               ; wins since last recalibration
  [recalib-total : usize]              ; total since last recalibration
  [last-recalib-count : usize]         ; recalib-count at last engram check
  [last-prediction : Direction])       ; set by observe-candle, read by resolve
```

**Interface:**
- `(make-market-observer lens dims recalib-interval window-sampler) → MarketObserver`
  Constructs the reckoner internally: `(make-reckoner "direction" dims recalib-interval (Discrete '("Up" "Down")))`.
  noise-subspace: `(online-subspace dims 8)` — 8 principal components for the
  background model. good-state-subspace: `(online-subspace dims 4)` — 4 components
  for engram gating (fewer — the good-state manifold is simpler).
  lens: MarketLens.
  All proof-tracking and engram-gating fields initialize to zero/empty.
- `(observe-candle observer candle-window ctx) → (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)`
  returns: thought Vector, Prediction (Up/Down), edge (f64 — the
  observer's current edge, from `(edge-at (:reckoner observer) conviction)`),
  and cache misses. Every learned output carries its track record. The
  consumer decides what to do with it. Cache misses are returned as
  values — the caller collects.
  candle-window: a slice of recent candles (NOT the full deque — the post
  calls `(sample (:window-sampler observer) encode-count)` to get the
  window size, slices, and passes the slice). The observer encodes →
  noise update → strip noise → predict. Stores the predicted direction
  on the observer for resolve to compare against the actual direction. The Prediction does NOT appear
  on the Proposal. The broker produces its OWN prediction (Grace/Violence)
  from the composed thought.
- `(resolve observer thought direction weight)`
  direction: Direction (:up or :down) — the actual price movement.
  weight: f64 — how much value was at stake.
  Called by broker propagation — reckoner learns from reality.
  Not "outcome" (which is Outcome :grace/:violence). Different type.
  Compares last-prediction against the actual direction. Match → correct.
  Mismatch → incorrect. Feeds the reckoner's internal curve via
  `(resolve (:reckoner observer) conviction correct?)`. The engram gate
  learns from real accuracy, not a constant.
- `(strip-noise observer thought) → Vector`
  return the anomalous component — what the noise subspace CANNOT explain.
  The residual IS the signal. The reckoner learns from what is unusual,
  not what is normal.
- `(experience observer) → f64` — how much has this observer learned?

---

### ExitObserver (depends on: Reckoner :continuous)

Estimates exit distance. Learned. Each exit observer has FOUR continuous
reckoners — one per distance (trail, stop, tp, runner-trail). No noise-subspace,
no curve, no engram gating — intentionally simpler than MarketObserver.
The exit observer's quality is measured through the BROKER's curve, not
its own. The broker's Grace/Violence ratio reflects the combined quality
of its market + exit observers. The exit observer doesn't need its own
proof gate — it is proven through the team it belongs to.

Each reckoner accumulates (thought, distance, weight) observations and returns the
cosine-weighted answer for a given thought.

Has a judgment vocabulary matching its ExitLens:
`:volatility` → `exit/volatility.wat`, `:structure` → `exit/structure.wat`,
`:timing` → `exit/timing.wat`, `:generalist` → all three.
The generalist is just another lens. No special treatment.
Composes market thoughts with its own judgment facts.
One per exit lens — M instances, not N×M.
The composed thought carries the market observer's signal in superposition.

```
(struct exit-observer
  [lens : ExitLens]                    ; which judgment vocabulary
  [trail-reckoner : Reckoner]          ; :continuous — trailing stop distance
  [stop-reckoner : Reckoner]           ; :continuous — safety stop distance
  [tp-reckoner : Reckoner]             ; :continuous — take-profit distance
  [runner-reckoner : Reckoner]         ; :continuous — runner trailing stop distance (wider)
  [default-distances : Distances])     ; the crutches (all four), returned when empty
```

Each reckoner: `(thought, distance, weight)` observations. Query by
cosine → distance for THIS thought. Contextual — different thoughts
get different distances.

**Interface:**
- `(make-exit-observer lens dims recalib-interval default-trail default-stop default-tp default-runner-trail) → ExitObserver`
- `(encode-exit-facts exit-obs candle) → Vec<ThoughtAST>`
  pure: candle → judgment fact ASTs for this lens
- `(evaluate-and-compose exit-obs market-thought exit-fact-asts ctx) → (Vector, Vec<(ThoughtAST, Vector)>)`
  two operations, honestly named:
  1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
  2. COMPOSE: bundle the evaluated exit vectors with the market thought
  ASTs in, one composed Vector out. Returns the composed vector AND any
  cache misses from encoding. The name says what it does.
  The observer returns ASTs rather than vectors because it does not own
  the ThoughtEncoder — ctx does, so evaluation is deferred to the call
  site which has ctx in scope.
- `(recommended-distances exit-obs composed broker-accums) → (Distances, f64)`
  returns: Distances + experience (f64 — how much the exit observer knows).
  Every learned output carries its track record. The consumer filters.
  broker-accums: Vec<ScalarAccumulator> — the broker's global per-pair learners.
  the cascade, per magic number:
  ```
  ;; experienced? = (> (experience reckoner) 0.0) — convenience predicate
  ;; has-data? = (> (:count accum) 0) — at least one observation
  (if (experienced? reckoner)
    (predict reckoner composed)          ; contextual — for THIS thought
    (if (has-data? broker-accum)
      (extract-scalar broker-accum ...)  ; global per-pair — any thought
      default-distance))                 ; crutch — the starting value
  ```
  One call, four answers. Each distance cascades independently.
- `(observe-distances exit-obs composed optimal weight)`
  composed: Vector — the COMPOSED thought (market + exit facts), not the
  raw market thought. The exit observer learns from the same vector it
  produced via evaluate-and-compose(). This is what makes the learning contextual.
  optimal: Distances — the hindsight-optimal distances from resolution.
  The market spoke — all four reckoners learn from one resolution.
- `(experienced? exit-obs) → bool`
  true if ALL FOUR reckoners have accumulated enough observations to
  produce meaningful predictions (experience > 0.0 on each). If any
  reckoner is ignorant, the exit observer is inexperienced — the cascade
  falls through to the ScalarAccumulator or crutch.

---

### Broker (depends on: Reckoner, OnlineSubspace, ScalarAccumulator)

The accountability primitive. Today: binds one market observer + one
exit observer. N×M brokers total. Tomorrow: more observer kinds may join.
Holds papers. Propagates resolved outcomes to every observer in the set.
Measures Grace or Violence.

The broker's identity IS the set of observer names it closes over.
`{"momentum", "volatility"}` is one broker. `{"regime", "timing"}` is
another. `{"momentum", "volatility", "drawdown"}` is a third — N observers,
not locked to two.

The broker does NOT own the observers — they live on the post.
The broker knows their coordinates: indices into the post's observer
vecs, resolved from names at construction, frozen forever. At runtime
the broker grabs its observers by index. O(1). The coordinates are known.

The broker does NOT own proposals or active trades — those are
the treasury's. The broker proposes TO the treasury.

**Lock-free parallel access.** At construction, the enterprise enumerates
all broker sets. Each set gets a slot in a flat vec. The mapping
`Set<String> → slot-idx` is built once, then frozen. Never written to
again. At runtime, all access is by slot-idx into the flat vec. Disjoint
slots. No mutex. The borrow checker proves the writes are disjoint.

```
construction:  enumerate all sets → allocate flat vec → build frozen map
runtime:       frozen map (read-only) → slot-idx → &mut broker (disjoint)
```

```
(struct broker
  [observer-names : Vec<String>]       ; the identity. e.g. ("momentum" "volatility").
                                       ; Diagnostic identity for the ledger. The binary reads
                                       ; observer-names for human-readable log entries. Derivable
                                       ; from slot-idx + lens enums, but carrying the names avoids
                                       ; modular arithmetic in every log line.
  [slot-idx : usize]                   ; the broker's position in the N×M grid. THE identity.
  [exit-count : usize]                 ; M — needed to derive market-idx and exit-idx:
                                       ; market-idx = slot-idx / exit-count
                                       ; exit-idx   = slot-idx mod exit-count
                                       ; One fact (slot-idx), not two. The indices are derived.
  ;; Accountability
  [reckoner : Reckoner]                ; :discrete — Grace/Violence
  [noise-subspace : OnlineSubspace]
  ;; The reckoner carries its own curve. resolve() feeds it. edge-at() reads it.
  ;; No separate curve field.
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers — the fast learning stream
  [papers : VecDeque<PaperEntry>]      ; capped
  ;; Scalar learning
  [scalar-accums : Vec<ScalarAccumulator>]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])
```

```
(struct propagation-facts
  [market-idx : usize]           ; which market observer should learn
  [exit-idx : usize]             ; which exit observer should learn
  [direction : Direction]        ; for the market observer
  [composed-thought : Vector]    ; for both observers
  [optimal : Distances]          ; for the exit observer
  [weight : f64])                ; for both observers
```

**Interface:**
- `(make-broker observers slot-idx exit-count dims recalib-interval scalar-accums) → Broker`
  observers: list of lens names (e.g. '("momentum" "volatility")).
  slot-idx: usize — the broker's position in the N×M grid. Assigned by
  the post at construction. THE identity. market-idx and exit-idx are
  derived: market-idx = slot-idx / exit-count, exit-idx = slot-idx mod exit-count.
  exit-count: usize — M, the number of exit observers.
  scalar-accums: Vec<ScalarAccumulator>.
  noise-subspace: `(online-subspace dims 8)`. good-state-subspace: `(online-subspace dims 4)`.
  Same k values as MarketObserver — same mechanism, same dimensionality needs.
- `(propose broker composed) → Prediction`
  noise update → strip noise → predict Grace/Violence
- `(edge broker) → f64` — how much edge? Reads from the reckoner's
  internal curve via `(edge-at (:reckoner broker) conviction)`.
  0.0 = no edge. The treasury funds proportionally. More edge, more capital.
- `(register-paper broker composed entry-price distances)`
  create a paper entry — every candle, every broker.
  distances: Distances (all four: trail, stop, tp, runner-trail) from the exit observer.
- `(tick-papers broker current-price) → (Vec<Resolution>, Vec<LogEntry>)`
  tick all papers, resolve completed. Returns resolution facts and
  PaperResolved log entries.
  **Paper optimal-distances:** papers don't carry price-history. They
  derive optimal distances from their tracked extremes (MFE/MAE):
  buy-extreme and sell-extreme relative to entry-price. This is a
  simpler approximation than the full replay used for real trades.
  The objective is the same (maximize residue) but the data is limited
  to what the paper tracked. The wat implements the approximation.
- `(propagate broker thought outcome weight direction optimal) → (Vec<LogEntry>, PropagationFacts)`
  thought: Vector. outcome: Outcome. weight: f64 — how much value was at
  stake. A $500 Grace teaches harder than a $5 Grace.
  direction: Direction — derived from the trade's price movement.
  If exit-price > entry-price, :up. If exit-price < entry-price, :down.
  optimal: Distances from hindsight.
  The broker learns its OWN lessons (reckoner + its internal curve, engram,
  track record, scalars) — feeds the curve via
  `(resolve (:reckoner broker) conviction correct?)`. It RETURNS what the
  observers need — the post applies the facts to its own observers.
  Values up, not effects down.
- `(paper-count broker) → usize`

**Two mechanisms for the same magic numbers — both now introduced:**

The exit observer's continuous reckoners are CONTEXTUAL: "for THIS thought,
what distance?" Different thoughts → different answers.

The broker's ScalarAccumulators are GLOBAL per-pair: "what value
does Grace prefer for this pair overall?" One answer regardless of thought.

Both learn from the same resolution events. Different questions.
The cascade when queried: contextual (reckoner) → global per-pair
(ScalarAccumulator) → default (crutch).

---

### Post (depends on: IndicatorBank, MarketObserver, ExitObserver, Broker)

A self-contained unit for one asset pair. The post is where the thinking
happens. It owns the observers, the brokers, the indicator bank.
It does NOT own proposals or trades — those belong to the treasury.

Each post watches one market. (USDC, WBTC) is one post. (USDC, SOL) is
another. No cross-talk. Observers within a post learn together. Observers
across posts are independent.

The post proposes to the treasury. The treasury decides. When a trade
closes, the treasury routes the outcome back to the post for
accountability — to the broker that proposed it.

```
(struct post
  ;; Identity
  [post-idx : usize]                   ; this post's index in the enterprise's posts vec
  [source-asset : Asset]               ; e.g. USDC
  [target-asset : Asset]               ; e.g. WBTC

  ;; Data pipeline
  [indicator-bank : IndicatorBank]     ; streaming indicators for this pair
  [candle-window : VecDeque<Candle>]   ; bounded history
  [max-window-size : usize]            ; capacity

  ;; Observers — both are learned, both are per-pair
  [market-observers : Vec<MarketObserver>]  ; [N]
  [exit-observers : Vec<ExitObserver>]      ; [M]

  ;; Accountability — brokers in a flat vec, parallel access
  [registry : Vec<Broker>]             ; one per observer set, pre-allocated

  ;; Counter
  [encode-count : usize])
```

**Interface:**
- `(make-post post-idx source target dims recalib-interval max-window-size
    indicator-bank market-observers exit-observers registry) → Post`
- `(post-on-candle post raw-candle ctx) → (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)`
  Returns proposals for the treasury, market-thoughts for step 3c, AND all
  collected cache misses from encoding. No queues — misses are values.
  The N×M composition uses map-and-collect: map the grid producing
  (Proposal, misses) per cell, then unzip. Values, not places. The loop
  does not accumulate by mutation.
  tick indicators → push window → market observers observe-candle (→ thoughts + predictions + edge + misses)
  → exit observers encode-exit-facts then evaluate-and-compose(market-thought, exit-fact-asts, ctx) → (composed + misses)
  → exit observers recommended-distances(composed, broker.scalar-accums) → Distances
    (the POST passes the broker's scalar accumulators to the exit observer —
    the post has access to both because it owns both)
  → brokers propose(composed) → returns Prediction (Grace/Violence)
  → the POST assembles each Proposal from: composed-thought, distances,
    broker.edge(), side, source-asset, target-asset, post-idx,
    broker-slot-idx. The broker's Prediction is not on the Proposal — it
    is stashed on the TradeOrigin at funding time (the archaeological
    record of why the trade exists). The post knows its source-asset and
    target-asset — it copies them to the Proposal at assembly time.
    Side derivation: the market observer's Prediction has scores for "Up"
    and "Down". The winning label is the one with the higher score.
    Compare up-score against down-score: `(if (>= up-score down-score) :buy :sell)`.
    The side is derived from which direction the market observer's reckoner
    leans toward, not from whether up-score is positive.
    The winning label maps to Side: "Up" → :buy, "Down" → :sell.
    The market observer's edge (from `(edge-at (:reckoner obs) conviction)`,
    the third return value) is available to the broker as a fact per the
    message protocol — the broker MAY encode it as
    `(bind (atom "market-edge") (encode-linear edge 1.0))`
    in its composed thought. This is a coordinate for later — the current
    architecture does not yet consume it. The value is produced and returned
    so the path exists when the broker is ready to use it.
  → register papers → return proposals, market-thoughts, and collected misses
- `(post-update-triggers post trades market-thoughts ctx) → (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)`
  trades: Vec<(TradeId, Trade)> — treasury's active trades for this post.
  market-thoughts: Vec<Vector> — this candle's encoded thoughts (one per
  market observer). Returns level updates (TradeId + new Levels for the
  enterprise to write back to the treasury) AND cache misses from exit
  observer composition. The post composes with exit observers for fresh
  distances, converts to Levels, and returns both. Values up.
- `(current-price post) → f64`
  the close of the last candle in the post's candle-window.
  The enterprise calls this per post to build current-prices for the treasury.
- `(post-propagate post slot-idx thought outcome weight direction optimal) → Vec<LogEntry>`
  direction: Direction. The post calls broker.propagate to get
  PropagationFacts, then applies them: direction + thought + weight →
  market observer via resolve, optimal + composed + weight → exit observer
  via observe-distances. The enterprise routes a settlement back to the
  post. Returns Propagated log entries.

---

### Treasury (depends on: nothing — pure accounting, but receives proposals from Posts)

Holds capital. Capital is either available or reserved. When a trade is
funded, the capital moves from available to reserved — off limits. No
other trade can touch it. When the trade ends, the principal returns
to available. The residue is permanent gain.

Receives proposals from posts — the barrage. Accepts or rejects based on
available capital and the broker's Grace/Violence ratio. If 10 brokers
propose and there's capital for 3 — fund the top 3, reject the rest.

Settles trades. Routes outcomes back to posts for accountability.
The maximum loss on any trade is bounded by its reservation.

The treasury is where the money happens. It does not think. It counts.
It decides based on capital availability and proof curves.

The treasury maps each active trade back to its post and broker
so that on settlement, propagate reaches the right observers.

```
(struct treasury
  ;; Capital — the ledger
  [denomination : Asset]               ; what "value" means (e.g. USD).
                                       ; The unit of measurement. total-equity converts all
                                       ; assets to this denomination. Currently the consumer
                                       ; (total-equity) does not reference the field — this is
                                       ; a wiring gap, not a dead field. The denomination IS how
                                       ; the treasury answers "how much is everything worth?"
  [available : Map<Asset, f64>]        ; capital free to deploy
  [reserved : Map<Asset, f64>]         ; capital locked by active trades

  ;; The barrage — proposals received each candle, drained after funding
  [proposals : Vec<Proposal>]          ; cleared every candle

  ;; Active trades — funded proposals become trades
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]

  ;; Venue costs — configuration applied at settlement
  [swap-fee : f64]                     ; per-swap venue cost as fraction
  [slippage : f64]                     ; per-swap slippage estimate

  ;; Counter
  [next-trade-id : usize])             ; monotonic
```

The treasury NEVER deploys more than available capital. The loss on any trade is bounded by its reservation. This is not a policy — it is the architecture. The treasury cannot over-commit. No trade can push available below zero. No reservation can exceed what was available at funding time.

**Interface:**
- `(make-treasury denomination initial-balances swap-fee slippage) → Treasury`
  denomination: Asset — what "value" means (e.g. USD).
  swap-fee: f64 — per-swap venue cost as fraction.
  slippage: f64 — per-swap slippage estimate as fraction.
  initial-balances: map of Asset → f64. All other fields start empty/zero.
- `(submit-proposal treasury proposal)`
  a post submits a proposal for the treasury to evaluate.
  The proposal carries post-idx and broker-slot-idx inside it.
- `(fund-proposals treasury) → Vec<LogEntry>`
  evaluate all proposals, sorted by proposal edge (the curve's accuracy measure).
  Fund the top N that fit in available capital. Reject the rest.
  Returns ProposalFunded and ProposalRejected log entries.
  Before funding, the treasury computes the expected venue cost: `(swap-fee + slippage) × amount × 2`. Both paths cost 2 swaps — violence (entry + stop-loss) and grace (entry + take-profit partial recovery). The residue from grace stays as the target asset and never swaps back. The treasury reserves `amount + worst-case-venue-costs` (2 swaps). A proposal whose edge does not exceed the total venue cost rate is rejected — negative expected value. The system never takes a trade it can't afford to lose.
  For each funded proposal: move capital from available to reserved,
  create a Trade, stash a TradeOrigin (post-idx, broker-slot-idx,
  composed-thought, prediction) for propagation at settlement time. Drain proposals.
- `(settle-triggered treasury current-prices) → (Vec<TreasurySettlement>, Vec<LogEntry>)`
  current-prices: map of (Asset, Asset) → f64 — one price per asset pair.
  Each post provides its latest candle close as its current price.
  Check all active trades against their stop-levels, settle what triggered.
  Returns treasury-settlements and TradeSettled log entries.
  When settling a trade, apply venue costs: the exit value is reduced by
  `(swap-fee + slippage) × trade-amount` per swap. A round trip (entry + exit)
  costs `2 × (swap-fee + slippage)`. The treasury deducts these from the
  returned capital before computing residue. Venue costs flow through the
  treasury's accounting, not through the enterprise or the binary.
  **Two settlement paths (step 1 — triggers fire against price):**
  - **:active + safety-stop fires** → :settled-violence.
    Full position swaps back. Principal minus loss returns. Trade is done.
  - **:active or :runner + trailing-stop fires** → outcome determines phase.
    The treasury swaps enough of the target asset back to the source
    asset to recover the principal. The remainder IS the residue —
    it stays as the target asset. Not converted. Not swapped.
    if value at exit > principal → :settled-grace (residue is permanent gain).
    if value at exit ≤ principal → :settled-violence (loss bounded by reservation).
    Violence: the full position swaps back because there is no residue to keep.
  The runner phase does NOT trigger a settlement. The runner phase is
  set by step 3c when the stop has moved past the break-even point.
  Step 1 only checks: did a stop-level fire? One entry. One exit.
  Each settled trade produces a TreasurySettlement. The enterprise computes
  direction and optimal-distances directly (derives direction from
  exit-price vs entry-rate, replays trade's price-history for
  optimal-distances) and passes them to post-propagate.
- `(available-capital treasury asset) → f64`
  how much is free to deploy?
- `(deposit treasury asset amount)`
  add to available
- `(total-equity treasury) → f64`
  available + reserved, all converted to denomination
- `(update-trade-stops treasury trade-id new-levels)`
  new-levels: Levels — absolute price levels, not Distances (percentages).
  The post converts Distances → Levels using the current price.
  step 3c: the post computes, the enterprise writes back.
- `(trades-for-post treasury post-idx) → Vec<(TradeId, Trade)>`
  step 3c: the enterprise queries active trades for a given post.

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
- **What order** — Step 1: RESOLVE+PROPAGATE → Step 2: COMPUTE+DISPATCH → Step 3a: TICK (parallel) → Step 3b: PROPAGATE (papers) → Step 3c: UPDATE TRIGGERS → Step 4: COLLECT+FUND
- **What flows where** — proposals from posts to treasury, treasury-settlements from treasury to enterprise to posts
- **What gets cleared** — proposals empty after funding, every candle

```
(struct enterprise
  ;; The posts — one per asset pair
  [posts : Vec<Post>]                  ; each watches one market

  ;; The treasury — shared across all posts
  [treasury : Treasury]                ; holds capital, funds trades, settles

  ;; The enterprise does NOT own immutable config. It receives ctx
  ;; as a parameter on every on-candle call. ctx is born at startup
  ;; and never changes. The enterprise is mutable state. ctx is not.

  ;; Per-candle cache — produced in step 2, consumed in step 3c
  [market-thoughts-cache : Vec<Vec<Vector>>]) ; one Vec<Vector> per post, cleared each candle
;; Log entries and cache misses are returned as values from each step,
;; not accumulated in queues. The enterprise collects them from return
;; values and processes them sequentially at the candle boundary.
;; Cache misses: collected from all steps, inserted into ThoughtEncoder
;; after all steps complete. Eventually-consistent — miss on candle N,
;; hit on N+1. Same pattern, no queues.
;; Log entries: collected from fund-proposals, settle-triggered,
;; tick-papers, and post-propagate. The binary decides what to do
;; with them (write to DB, print, discard).
```

**Interface:**
- `(on-candle enterprise raw-candle ctx) → (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)`
  route to the right post, then four steps. ctx flows in from the binary.
  Each step returns its log entries and cache misses as values. The
  enterprise collects all cache misses from all steps and returns them
  alongside the concatenated log entries. The BINARY inserts the misses
  into ctx's ThoughtEncoder cache between candles — the enterprise cannot,
  because it does not own ctx. Returns: log entries (for the ledger) and
  cache misses (for the seam).
- `(step-resolve-and-propagate enterprise) → Vec<LogEntry>`
  Returns TradeSettled and Propagated log entries. No ctx needed —
  settlement and propagation use pre-existing vectors, no encoding happens.
  The enterprise collects current prices internally (calls current-price
  on each post). Treasury settles triggered trades using those prices.
  For each settlement: enterprise computes optimal-distances via
  compute-optimal-distances (free function — price-history in, Distances out),
  then routes to the post for propagation.
- `(step-compute-dispatch enterprise post-idx raw-candle ctx) → (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)`
  post-idx: usize — which post. raw-candle: RawCandle — the raw candle
  received by on-candle, threaded through to the post. The post returns
  proposals, market-thoughts, and cache misses as values.
  post encodes, composes, proposes — returns proposals for the treasury,
  market-thoughts (Vec<Vector>) for step 3c, and cache misses. The
  enterprise caches market-thoughts between steps and collects misses.
- `(step-tick enterprise post-idx) → (Vec<Resolution>, Vec<LogEntry>)`
  parallel tick of all brokers' papers. Returns resolution facts and
  PaperResolved log entries.
- `(step-propagate enterprise post-idx resolutions) → Vec<LogEntry>`
  sequential: apply resolutions to observers. Returns Propagated log
  entries. Brokers learn Grace/Violence. Market observers learn Up/Down.
  Exit observers learn optimal distances.
- `(step-update-triggers enterprise post-idx market-thoughts ctx) → Vec<(ThoughtAST, Vector)>`
  the enterprise queries the treasury for active trades belonging to this
  post, then calls post-update-triggers(post, trades, market-thoughts, ctx).
  The post returns `(Vec<(TradeId, Levels)>, Vec<misses>)` — level updates
  and cache misses as VALUES UP from the post. The enterprise applies the
  level updates to its own treasury (the enterprise owns the treasury —
  mutation of own state, not a side-effect pushed down). Collects misses.
  This is step 3c — after tick and propagate.
- `(step-collect-fund enterprise) → Vec<LogEntry>`
  treasury funds or rejects all proposals, returns log entries, drains

---

### The Binary (depends on: Enterprise, ctx, Ledger)

The outer shell. The driver of the fold. The binary creates the world,
feeds candles, writes the ledger, and displays progress. It does not
think. It does not predict. It does not learn. It orchestrates.

The binary has a wat file like everything else — `bin/enterprise.wat`.
The wat specifies the shape. The Rust implements it. The binary is the
root of the call tree.

**Responsibilities:**

1. **CLI** — parse arguments. The configuration that the enterprise
   receives as constants:
   - `dims` — vector dimensionality (default 10000)
   - `recalib-interval` — observations between recalibrations (default 500)
   - `denomination` — what "value" means (e.g. "USD")
   - `assets` — the pool of assets to manage, as a list of (name, initial-balance)
     pairs. e.g. `[("USDC", 10000.0), ("WBTC", 0.0)]` or `[("USDC", 2000.0),
     ("WBTC", 0.1)]` — whatever amount of value you want, in whatever form.
     The initial balances are valued at the first candle's prices to compute
     initial equity in the denomination. The binary does not know or care what
     the assets ARE. Each unique pair of assets becomes a post. One asset pair
     today. Many tomorrow. The architecture is the same.
   - `data-sources` — one data source per asset pair. Parquet path or
     websocket URL. The binary maps each source to its pair.
   - `max-candles` — stop after N candles (0 = run all)
   - `swap-fee` — per-swap venue cost as fraction (e.g. 0.0010 = 10bps)
   - `slippage` — per-swap slippage estimate as fraction (e.g. 0.0025)
   - `max-window-size` — maximum candle history (default 2016)
   - `ledger` — path to output SQLite database (auto-generated if omitted)

2. **Construction** — build the world, then the machine:
   ```
   vm              = make-vector-manager(dims)
   thought-encoder = make-thought-encoder(vm)
   ctx             = { thought-encoder, dims, recalib-interval }

   ;; One post per asset pair — the binary enumerates pairs from the asset pool
   posts = for each (source, target) pair in assets:
     indicator-bank   = make-indicator-bank()
     market-observers = [make-market-observer for each MarketLens variant]
     exit-observers   = [make-exit-observer for each ExitLens variant]
     registry         = [make-broker for each (market, exit) combination]
     make-post(idx, source, target, dims, recalib-interval,
       max-window-size, indicator-bank,
       market-observers, exit-observers, registry)

   treasury  = make-treasury(denomination, initial-balances, swap-fee, slippage)
   enterprise = make-enterprise(posts, treasury)
   ```
   ctx is immutable after construction. Enterprise is mutable state.
   One pair today (USDC, WBTC). The architecture holds any number.

3. **Ledger** — initialize SQLite database for this run:
   - `meta` table — run parameters (dims, recalib-interval, fees, etc.)
   - `log` table — receives LogEntry values from on-candle
   The ledger is the glass box. The DB is the debugger.

4. **The loop** — the fold driver:
   ```
   for raw-candle in stream:
     if kill-file exists → abort
     (log-entries, cache-misses) = on-candle(enterprise, raw-candle, ctx)
     insert cache-misses into ctx.thought-encoder  ; the one seam
     flush log-entries to ledger (in batches)
     if progress-interval → display diagnostics
   ```
   The stream comes from parquet (backtest) or websocket (live).
   The binary doesn't know which. It consumes RawCandles. Same code path.

5. **Progress** — every N candles, display:
   - encode-count, throughput (candles/second)
   - treasury equity, return vs buy-and-hold
   - per-observer stats (recalib count, discriminant strength)
   - broker stats (paper count, Grace/Violence ratio, curves proven)
   - accumulation (residue earned per side)

6. **Kill switch** — the file `trader-stop`. Touch it to abort the run.
   Checked periodically (every 1000 candles), not every candle.

7. **Summary** — after the loop completes:
   - final equity, return percentage, buy-and-hold comparison
   - trade count, win rate, accumulation totals
   - venue costs paid
   - observer panel summary
   - ledger path and row count

**Query functions** — the binary reads enterprise state for diagnostics.
These are public API on the enterprise's components, not the binary's
logic. The binary just calls them and formats the output.

Interface functions (declared on their structs):
- `(total-equity treasury) → f64`
- `(paper-count broker) → usize`
- `(experience observer) → f64`
- `(recalib-count reckoner) → usize`
- `(edge broker) → f64`

Field reads (keyword-as-function, from the struct definition):
- `(:encode-count post) → usize`
- `(:cumulative-grace broker) → f64`
- `(:cumulative-violence broker) → f64`
- `(:trade-count broker) → usize`

The binary reads diagnostic labels and identifiers from every entity:
`(:observer-names broker)` for broker identity, `(:name accumulator)` for
scalar accumulator identity, `(:denomination treasury)` for equity
denomination. These are human-readable names that make the ledger speak
to humans.

The binary is the last thing built. It depends on everything. It
touches nothing. It drives the fold and writes what happened.

---

## The build order

The construction order section above IS the build order. The sections
below it detail each entity in the same order. Each file is agreed
upon before the next is written.

---

## The CSP (Communicating Sequential Processes) per candle

Every boundary is a channel. Every process reads from its channels and
writes to its channels. Nobody reaches across. The coupling is data flow,
not shared mutation. Nothing learns in the moment. Everything learns from
the past. Produce now, consume later, learn from what actually happened.

### Channels — the typed boundaries

```scheme
;; What flows between processes. Each channel has a type.

raw-candle       ; RawCandle           — enterprise → post (routed by asset pair)
market-thoughts  ; Vec<Vector>         — the thought vectors from market observers
                 ;                      (predictions are internal to the observer)
composed         ; Vec<Vector>         — exit observers → brokers
proposals        ; Vec<Proposal>       — posts → treasury (the barrage)
treasury-settlements ; Vec<TreasurySettlement> — treasury → enterprise
                 ;   enterprise computes direction + optimal-distances directly
                 ;   and passes them to posts (reality feedback)
trade-triggers   ; Vec<(TradeId, Trade)> — treasury → posts (active trades for update)
distances        ; Distances            — exit observers → proposals + papers
propagation      ; (thought, outcome, weight)
                 ;   broker → market observer.resolve (Up/Down)
                 ;   broker → exit observer.observe-distances (optimal)
                 ;   broker → self reckoner (Grace/Violence)
```

### The four steps — who produces, who consumes

```
Step 1: RESOLVE + PROPAGATE (propagation path 1 — real trades)
  treasury reads:   active trades, current price
  treasury produces: treasury-settlements
  enterprise computes: direction + optimal-distances from each treasury-settlement directly
  enterprise routes: treasury-settlements + direction + optimal-distances → posts → brokers → propagation → observers learn
  NOTE: this IS propagation — real trade outcomes teach the observers.
  Step 3b is propagation path 2 (paper resolutions). Both paths call
  broker.propagate. Both teach. Different sources, same mechanism.

Step 2: COMPUTE + DISPATCH
  posts read:       raw-candle
  market observers produce: market-thoughts (parallel, par_iter)
  exit observers consume:   market-thoughts → compose → composed
  brokers consume:          composed → propose → register paper
  posts produce:    proposals (the barrage)
  treasury receives: proposals

Step 3a: TICK (parallel — all cores)
  brokers par_iter: tick papers, check conditions, compute outcomes
  each broker touches ONLY its own papers. Disjoint. Lock-free.
  brokers produce:  Vec<Resolution> — facts, not mutations
  collect() is the synchronization primitive.

Step 3b: PROPAGATE (propagation path 2 — paper resolutions, sequential)
  fold over resolutions: apply to shared observers
  market observers learn Up/Down. Exit observers learn distance.
  brokers learn Grace/Violence. Sequential because observers are shared.
  Same broker.propagate as step 1. Different source (papers, not trades).

Step 3c: UPDATE TRIGGERS (sequential)
  treasury passes active trades to posts.
  posts compose fresh thoughts, query exit observers for distances.
  posts compute new stop levels. Treasury applies new values to trades.

Step 4: COLLECT + FUND
  treasury reads:   proposals, available capital, broker edge levels
  treasury produces: funded trades (move capital: available → reserved)
  treasury drains:  proposals → empty
```

---

## Performance

The machine must process enough candles to learn. 652,608 candles at 3/s
takes 60 hours. At 250/s it takes 43 minutes. Throughput IS the ability
to learn. Performance is not an optimization — it is a requirement.

**Target:** 75-500 candles/second at 10,000 dimensions. The prior Rust
(pre-007) sustained 251/s flat. The new architecture has more observers
(10 vs 7) and more brokers (24 vs 7) but the same algebra. The target
is achievable with correct parallelism.

**What must be parallel:**

- **Step 2: market observer encoding.** Six market observers encode the
  same candle independently. Each has its own lens, its own window sampler,
  its own reckoner. No shared mutable state during encoding. `par_iter`
  over market observers, `collect()` the results. Each returns
  `(Vector, Prediction, f64, Vec<misses>)`. This is the heaviest step —
  six 10,000-dim encodings. Parallelism turns 6x into ~1x.

- **Step 3a: broker tick.** 24 brokers tick their papers independently.
  Each broker touches only its own paper deque. Disjoint. `par_iter`,
  `collect()` the resolutions. Light per-broker (a few papers each) but
  24 of them.

**What must be sequential:**

- **Step 2: exit observer dispatch.** Exit observers receive market thoughts
  as input — they depend on step 2's market results. Sequential within
  step 2, after the parallel market encoding.

- **Step 3b: propagation.** Resolutions from 3a route to shared observers.
  The market observer is shared across brokers. Sequential fold over
  resolutions.

- **Step 3c: trigger updates.** Queries shared observers and treasury.
  Sequential.

**SIMD:** holon-rs supports AVX2/NEON via `features = ["simd"]`. The
`cosine`, `bind`, `bundle` operations are the hot path — called thousands
of times per candle. SIMD gives ~5x on these primitives. Enable with
`cargo build --release --features simd`.

**The algebra is cheap. The parallelism makes it fast.** 10 observers ×
~20 atoms each × 10,000 dimensions = ~2M float operations per candle.
One core at ~10 GFLOPS can do this in microseconds. The bottleneck is
the SERIAL execution of what should be parallel, not the algebra itself.

---

## Forge coordinates

Known findings from the ninth inscription's Rust compilation. These
are coordinates for refinement, not blockers.

- **broker.edge on zero vector.** `edge()` calls `predict(&Vector::zeros(...))`.
  A zero vector has no contextual meaning. Should take the composed thought
  as input, or rename to `baseline_edge`. The edge returned is the broker's
  general confidence level, not its confidence for a specific thought.

- **treasury.settle_triggered complexity.** 170 lines, three paths welded:
  safety-stop, trail/tp/runner, and runner-transition. Extract
  `settle_one(&trade, price, cost_rate) → Settlement` as a pure function.
  The capital invariant becomes testable in isolation.

- **market_thoughts_cache.** Enterprise writes market-thoughts in step 2,
  reads in step 3c. An explicit field on the struct. Threading as a return
  value would eliminate the cache and make the fold body purer. Hickey's
  coordinate from the designer review.

- **Lifecycle tests missing.** enterprise.on_candle, treasury.fund_proposals,
  treasury.settle_triggered, post.on_candle, broker.propagate,
  broker.tick_papers — all untested. The component parts work (116 tests
  pass) but the lifecycle has no end-to-end test at the Rust level.

---

## The circuit

See `wat/CIRCUIT.md` — the machine as signal flow diagrams. No new
definitions; it visualizes the components and interfaces declared above.
The full enterprise circuit, plus sub-circuits for encoding, learning,
papers, funding, breathing stops, cascade, propagation, and the binary.
Nine circuits. Mermaid source + component and edge legends.

`f(state, candle) → state` — one tick of the clock.

