# Proposal 007: Exit Proposes

**Scope: userland** -- existing forms only. No new language forms. No new primitives.

---

## 1. The current state

The enterprise processes one candle at a time in a single pass. Market observers encode thoughts. The manager aggregates. The desk opens positions when conviction is sufficient. Positions are managed with fixed ATR multipliers (k_trail, k_stop, k_tp). The exit module has four proven pieces that are not yet wired into the candle loop:

**LearnedStop** (`src/exit/learned_stop.rs`): Nearest neighbor regression over (thought, distance) pairs. Given a thought vector, returns a weighted average of distances from similar thoughts. Tested: trending regime returns 0.05%, choppy regime returns 1.40%. The interface is two methods: `observe(thought, optimal_distance, weight)` and `recommended_distance(thought)`.

**compute_optimal_distance** (`src/exit/optimal.rs`): Sweeps trailing stop distances over a resolved price history and finds the one that maximized residue. Pure function. No state. Tested on ascending, reversal, choppy, and realistic BTC shapes. The market's answer to "what distance should you have used?"

**ScalarAccumulator** (`src/exit/scalar.rs`): Accumulates f64-encoded scalar values by outcome. Grace observations and violence observations build separate prototypes. Extract via sweep recovers the learned value. Tested: recovers 1.70 exactly from noisy input.

**TupleJournal** (`src/exit/tuple.rs`): The accountability primitive. One journal per (market observer, exit observer) pair. Labels: Grace/Violence from treasury reality. Proof curve gates treasury funding. Scalar accumulators attach to each tuple for per-parameter learning.

**DualExcursion** (`src/position.rs`): Tracks buy-side and sell-side excursions independently per pending entry. Four floats (buy MFE, buy MAE, sell MFE, sell MAE) plus trailing stop state for both sides. 99.9% organic resolution -- both sides resolve through price movement, not timers.

All five are tested. None are in the candle loop. The market observers produce thoughts that go nowhere except the single-sided MFE/MAE labeling. The exit module exists as an island of proven code.

## 2. The problem

The market observer proposes trades. This is wrong. The market observer perceives direction. It does not know how to manage a trade. It does not know what trailing stop distance to use. It does not know when the position it created should close. It fires and forgets.

The market observer's conviction becomes the sizing signal. But conviction about DIRECTION is not conviction about MANAGEABILITY. A strong directional signal in a volatile regime is a different trade than the same signal in a trending regime. The market observer cannot distinguish these -- it sees direction, not distance.

The fixed ATR multipliers (k_trail, k_stop, k_tp) fill the gap that should be filled by a learning entity. The multipliers are the same for every trade, regardless of what the market observer thought at entry. A trending thought and a choppy thought get the same stop. This is the last magic.

The exit module has the primitives to fill this gap -- LearnedStop predicts distance from thought, compute_optimal_distance provides the training signal, TupleJournal provides accountability -- but there is no entity that wires them together. No process that receives a market thought, checks its own experience, decides "I know how to manage this kind of thought," and proposes the trade.

## 3. The proposed change

### Three passes per candle

The single-pass candle loop becomes three independent passes. Each is a CSP stage. No shared mutation between stages. Data flows forward.

**Pass 1: Market observers think.**

OHLCV arrives. Indicators compute. Each market observer encodes its thought through its vocabulary lens, strips noise, predicts direction. Unchanged from today. The market observer produces a thought vector and a directional prediction. It registers this thought with the exit observer -- "here is what I thought at this candle."

Every market thought registers as a paper entry. The exit observer manages ALL registered thoughts -- paper and live. Paper entries learn the optimal distance without risking capital. Live entries are the subset the exit observer proposed and the treasury funded.

**Pass 2: Exit observers manage.**

For each registered thought (paper or live), the exit observer checks the current price.

If the entry resolved (trailing stop fired on either side of the DualExcursion):
- Compute the optimal distance from hindsight (`compute_optimal_distance` on the resolved price history).
- Feed the learning: `learned_stop.observe(thought, optimal_distance, residue_weight)`.
- Propagate Grace/Violence to the TupleJournal.
- Label the market observer: the exit observer's resolution becomes the market observer's Win/Loss signal.

If the entry is still active:
- Update the DualExcursion (tick MFE, MAE, trailing stops for both sides).
- Adjust the live position's trailing stop using the LearnedStop's current recommendation for this thought. The distance is not fixed -- it changes as the LearnedStop accumulates experience from other resolved entries.

For NEW market thoughts (just registered this candle):
- The exit observer queries `recommended_distance(thought)`. If the LearnedStop has enough experience with this kind of thought (not returning the default), and the market observer's conviction is high, the exit observer PROPOSES the trade to the treasury.
- The exit observer proposes because it is the entity that will manage the trade. It is on the hook.

**Pass 3: Treasury settles.**

For each proposal the exit observer made, the treasury checks:
- Is the TupleJournal for this (market, exit) pair proven? (curve_valid)
- Is capital available?
- Does the risk branch allow it?

If funded, the paper entry becomes a live entry. If not, it remains paper. Paper entries learn. Live entries learn AND accumulate capital.

For each live entry that resolved this candle, the treasury computes Grace/Violence from the actual P&L and cascades the signal to both the market observer and the exit observer.

### The exit observer is a LearnedStop wrapper

The exit observer does not encode its own thoughts from candles. It receives the market observer's thought and uses it as the query key into its LearnedStop. The LearnedStop IS the exit observer's brain.

`recommended_distance(thought)` is the exit observer's prediction. The prediction is a distance, not a direction. The exit observer answers "how much room does this kind of thought need?" not "which way?"

`observe(thought, optimal_distance, weight)` is the exit observer's learning. After a trade resolves, `compute_optimal_distance` provides the training signal. The LearnedStop accumulates. The next query for a similar thought returns a better distance.

The exit observer does not need its own vocabulary. It does not need its own noise subspace for encoding. It does not encode candle data. It receives a thought vector and manages it. The thought vector IS the context. A trending-regime thought naturally clusters near other trending-regime thoughts in the LearnedStop. A choppy-regime thought clusters near other choppy thoughts. The market observer's encoding already captures the regime. The exit observer reads the regime through the thought vector's position on the sphere.

### Each magic number gets its own LearnedStop

k_trail, k_stop, and k_tp are all distances. Each gets its own LearnedStop:

- **Trail LearnedStop**: "given this thought, what trailing stop distance?" Trained from `compute_optimal_distance` with the trail parameter.
- **Stop LearnedStop**: "given this thought, how far should the safety stop be?" Same sweep, different question.
- **TP LearnedStop**: "given this thought, what take-profit distance?" Same sweep, applied to the upside.

Each learns independently. Each returns the default until enough resolved entries have trained it. The defaults are the current ATR multipliers -- the crutch. As the LearnedStops accumulate experience, the crutch is replaced by learned values. No hard switch. The LearnedStop returns `default_distance` when empty and blends toward the learned value as pairs accumulate.

### Paper trades are the training ground

Every market thought registers as a paper entry. Every paper entry gets a DualExcursion. Every candle, every paper entry ticks. When a paper entry resolves (both sides of the DualExcursion fire), the optimal distance is computed and the LearnedStop learns.

Paper entries produce learning without risking capital. The exit observer trains on thousands of entries before proposing a single live trade. The proof gate on the TupleJournal ensures the exit observer has demonstrated edge before the treasury funds it.

Live entries are a subset of paper entries that were:
1. Proposed by the exit observer (high market conviction + proven distance for this thought).
2. Funded by the treasury (TupleJournal proven, capital available, risk allows).

Both paper and live entries produce learning. Paper is the training ground. Live is the exam.

### Three learning streams — all simultaneous

**Paper stream** (every candle, every market thought): the exit observer receives the thought, manages the paper entry, adjusts the paper trigger. When the paper entry resolves, the exit observer computes the optimal distance and learns. This is the fast stream. Thousands of data points per run. Cheap lessons.

**Live management stream** (every candle, every open position): the treasury asks the owning exit observer "what's the trigger now?" The exit observer queries its LearnedStop with the CURRENT thought — not the entry thought, the current one, because the market changed. The trigger moves every candle. This is the active stream. Real money, real adjustment, real time.

**Reality stream** (on position close): the treasury reports Grace/Violence with the actual amount. The exit observer learns from reality. The market observer receives the Win/Loss label. The TupleJournal records the pair's track record. This is the slow stream. Most honest. Final.

All three feed the same LearnedStop. Paper fills it fast with cheap lessons. Live management keeps it current with the market's state. Reality corrects it with the most honest signal. The learning never stops.

### The optimal distance replaces ALL magic numbers

The market does not use formulas. It uses measurement. `compute_optimal_distance` sweeps 100+ candidate distances against the actual price history from entry to resolution. It finds the peak residue. That is the market's answer.

The LearnedStop stores (thought, market_answer) pairs. When a new thought arrives, it queries: "what did the market say about thoughts like this?" The answer is a distance. Not a formula. Not a multiplier. A weighted average of the market's answers for similar thoughts.

The exit observer proposes only when:
1. The market observer has high conviction (strong directional signal).
2. The LearnedStop has proven experience for this kind of thought (not returning default).

Condition 2 is the key difference from today. Today, every high-conviction signal opens a trade with the same fixed stops. Under this proposal, the exit observer gates entries based on its own experience. A thought shape it has never seen stays on paper. A thought shape it has managed successfully before gets proposed.

### What changes

1. **Candle loop**: single pass becomes three passes (think, manage, settle). Each pass reads the output of the previous. No shared mutation within a pass.

2. **Exit observer**: wraps LearnedStop (one per distance parameter). Receives market thoughts. Proposes when experienced. Manages live entries every candle.

3. **Paper entries**: every market thought registers. DualExcursion tracks both sides. Resolved paper entries train the LearnedStops.

4. **Live entry creation**: the exit observer proposes, not the market observer. The treasury funds proposals from proven tuples.

5. **Label flow**: exit observer resolution becomes market observer Win/Loss label. The market observer learns from how the trade was managed, not from a fixed horizon drain.

6. **Trailing stop**: per-candle update from `recommended_distance(current_thought)`. The distance is contextual and learned, not fixed.

### What does NOT change

- The six primitives.
- The observer template (noise subspace + journal).
- The market observers' encoding pipeline.
- The risk branches.
- The accumulation model.
- The treasury's asset management.
- DualExcursion, LearnedStop, compute_optimal_distance, ScalarAccumulator, TupleJournal -- all exist and are tested.

## 4. The algebraic question

No new algebraic structures. The market observers use the existing pipeline (bind, bundle, journal, online-subspace, cosine, curve). The exit observer does not use the vector algebra for encoding -- it uses the vectors the market observers already produced as keys into a regression. The regression is cosine-weighted averaging, which is the same similarity primitive the journal uses.

The LearnedStop is `cosine(query, stored) * weight` summed over pairs. That is the same operation as journal prediction -- weighted similarity against accumulated experience. The difference is the output: the journal outputs a label (Win/Loss), the LearnedStop outputs a scalar (distance). Same geometry, different readout.

The TupleJournal uses the full algebra: bind, bundle, journal, noise subspace, curve. It operates on composed thoughts (market thought bundled with exit context). It is the third journal in the stack, alongside the market observer journal and the manager journal.

The coupling between passes is data flow: Pass 1 produces thoughts, Pass 2 consumes them and produces proposals + resolutions, Pass 3 consumes proposals and produces reality labels. No algebraic coupling. No shared vectors mutated across passes. CSP.

## 5. The simplicity question

**Is this simple or easy?** Simple. Each pass does one thing. Pass 1: think. Pass 2: manage. Pass 3: settle. The exit observer is a wrapper around LearnedStop, which is a tested primitive. The three-pass structure makes the data flow explicit -- no entangled mutation within a single candle step.

**What's being complected?** The risk is coupling the exit observer's proposal decision to the market observer's conviction. These are independent judgments: "is the direction strong?" and "can I manage this kind of thought?" The proposal gate requires both but they must remain separate measurements. The exit observer does not see conviction -- it sees the thought vector and queries its own experience.

**Could existing forms solve it?** They DO solve it. Every piece exists and is tested:
- LearnedStop: nearest neighbor regression. Tested.
- compute_optimal_distance: hindsight sweep. Tested.
- DualExcursion: dual-sided tracking. Tested, 99.9% organic resolution.
- TupleJournal: accountability primitive. Tested.
- ScalarAccumulator: continuous value learning. Tested.

The proposal is wiring. The pieces are proven. The question is the topology of the wiring, not the pieces themselves.

**What 005 and 006 attempted that this simplifies:**
- 005 proposed an exit PANEL (multiple exit observers with their own vocabulary lenses). This proposal: one exit observer wrapper per market observer, no exit encoding, no exit vocabulary. The exit observer's intelligence is the LearnedStop, not a journal over exit-specific facts.
- 006 proposed N x M composition (N market observers x M exit observers) with dual-sided labeling and continuous management scalars. This proposal: the exit observer is simpler -- it is a regression, not a journal. It does not predict Buy/Sell. It predicts a distance. The composition is not bundle -- it is a function call.
- Both 005 and 006 described the exit observer as a full observer with its own encoding pipeline. This proposal: the exit observer has no encoding. It is a LearnedStop with a proposal gate. The intelligence is in the (thought, distance) pairs, not in a separate thought about the thought.

## 6. Questions for designers

1. **One exit observer or one per market observer?** The LearnedStop stores (thought, distance) pairs. Thoughts from different market observers live in different regions of the sphere (different vocabulary, different lens). A single shared LearnedStop would cluster them naturally -- trending-momentum thoughts near other trending-momentum thoughts, choppy-regime thoughts near other choppy-regime thoughts. Alternatively, one LearnedStop per market observer keeps the accountability clean: each market observer's exit performance is measured independently. The question: is one shared regression sufficient, or does per-observer separation produce better learning? The TupleJournal already exists for per-pair accountability. Does the LearnedStop need the same separation?

2. **Paper entry memory.** Every market thought registers as a paper entry. Seven observers, one thought each per candle, each living until both sides of the DualExcursion resolve. At 99.9% organic resolution, entries die. But the buffer is implicit memory pressure. How many concurrent paper entries is reasonable? The DualExcursion is 8 floats per entry. At 7 observers x ~100 candle average lifetime, that is ~700 concurrent entries. Is this the right order? The buffer cap is the last implicit parameter.

3. **When does the exit observer start proposing?** The LearnedStop returns `default_distance` when it has zero pairs. As pairs accumulate, it blends. The question is the proposal gate: how many resolved paper entries must the LearnedStop have before the exit observer is willing to propose a live trade? This is the boot-up parameter. Too few and the exit observer proposes from ignorance. Too many and it stays on paper while the market moves. The TupleJournal's proof curve could gate this -- the exit observer proposes only when the tuple has proven Grace over Violence. Is the proof curve sufficient, or does the LearnedStop need its own minimum pair count?

4. **Does the exit observer adjust live stops every candle?** The current proposal says yes: each candle, the exit observer queries `recommended_distance(current_thought)` for each live entry. The thought changes each candle (new market state). The recommended distance changes as the LearnedStop accumulates new pairs. This means the trailing stop is not fixed at entry -- it adapts to the evolving market context and the exit observer's evolving experience. The question: is per-candle adjustment the right frequency, or should the stop only adjust at discrete events (regime change, DualExcursion milestone)?

5. **Label flow direction.** The proposal says: exit resolution becomes market observer Win/Loss label. Today, the label comes from single-sided MFE/MAE at horizon drain. The transition: paper entries resolve via DualExcursion (both sides organically), producing Buy/Sell + weight. The market observer's prediction is compared against this label. The exit observer's management quality is embedded in the resolution timing -- a well-managed entry resolves at a better price than a poorly-managed one. The question: does the dual-sided label from paper entries replace the current MFE/MAE label immediately, or should both run in parallel until the exit observer proves edge?

6. **The current thought as query key.** The exit observer queries `recommended_distance(current_thought)` where `current_thought` is the market observer's thought at the CURRENT candle, not the entry candle. This means the distance adapts as the market changes -- what started as a trending thought might look choppy 20 candles later, and the recommended distance shifts. Is this correct? The alternative: query with the ENTRY thought (fixed at entry, never changes). The entry thought captures what the market looked like when the trade was opened. The current thought captures what it looks like now. Which is the right key for "what distance should the stop be?"
