# Proposal 006: Honest Labels via Dual-Sided Excursion

**Scope: userland** -- uses existing forms (observer, journal, online-subspace, pending, classify-excursion). No new language forms.

---

## 1. The current state

Each candle, the market observers encode thoughts through their vocabulary lens, strip noise via OnlineSubspace, and predict direction via Journal. The prediction is buffered as a Pending entry. Every candle while the entry is alive, the system tracks MFE (max favorable excursion) and MAE (max adverse excursion) in the predicted direction. At horizon drain (10x horizon candles), the entry resolves: MFE > |MAE| means Win, otherwise Loss. Weight = |MFE - |MAE||. The journal learns from these labels.

This replaced the old simulation labels (91/9 imbalance) and produces approximately 50/50 Win/Loss in a random walk. Deviations from 50/50 are real signal. The architecture works.

The exit observer exists in `market/exit.rs`. It encodes position state (P&L, MFE, MAE, hold duration, stop distance, ATR shift, phase, direction) and learns Hold/Exit. It is aspirational -- it learns but does not feed back into anything. Its vocabulary is position-centric: it sees a ManagedPosition and the current ATR.

Seven market observers (five specialists, two generalists) each with their own Journal, noise subspace, window sampler, and proof curve. One manager journal aggregates their opinions. The pipeline is proven and stable.

## 2. The problem

The market observers track MFE/MAE in ONE direction -- the direction the observer predicted (or the manager called). If the prediction was Buy, MFE tracks upward moves and MAE tracks downward moves. If the prediction was Sell, the opposite.

This creates a circular dependency: the label quality depends on the prediction quality. A bad prediction means MFE and MAE are measured in the wrong direction, producing a noisy label. The observer learns from the noise. The noise perpetuates.

The horizon (10x the window) is arbitrary. It is long enough to capture most excursions but it is still a parameter. The binary split (MFE > |MAE|?) is crude -- a candle where both sides experienced similar excursion gets a strong label in whichever direction happened to edge ahead.

The exit observer thinks about positions, not candles. It needs an open ManagedPosition to encode a thought. But the interesting question -- "was this candle a better entry for buying or selling?" -- does not require a position. It requires the same candle data the market observers already see. The exit observer and the market observer are asking different questions about the same input. The exit observer's current vocabulary (position state) forces it into a different data stream when it should be looking at the same one.

## 3. The proposed change

### Same candles, different question

The exit observer does not encode its own thoughts from candles. It RECEIVES the market observers' already-encoded thought vectors and judges them. "Given that the generalist thought THIS at candle N, was that a buy-grace or sell-grace thought?"

- Market observer asks: "which direction?"
- Exit observer asks: "given these market thoughts, which side was better?"

### Two vocabularies, composed

The market observers and the exit observer have overlapping but distinct vocabularies — a Venn diagram:

**Market vocabulary** (the market observers' circles): RSI, MACD, harmonics, regime, divergence, persistence, flow. Each specialist sees a subset. The generalist sees all. These facts describe what the market IS doing.

**Exit vocabulary** (the exit observer's circle): ATR regime, volatility state, market structure quality, spread conditions. These facts describe whether the environment is favorable for ANY entry, regardless of direction. Not "which way?" but "is now a good time?"

**Shared vocabulary** (the overlap): calendar (hour, day), regime indicators that appear in both. The nuance lives in the overlaps.

The exit observer receives EACH market observer's thought vector — momentum, structure, volume, narrative, regime, generalist, classic. Seven thoughts, each from an observer with its own vocabulary and its own lens. The exit observer binds its judgment facts to each one and judges each independently. Seven compositions. Seven judgments. All observers are equal — the generalist is just an observer with broader vocab, not a privileged input.

Each composed thought (market thought + exit judgment facts) passes through the exit observer's noise subspace and journal. The exit observer produces a label per market observer per candle. At drain, each market observer receives the label for ITS thought: was this momentum thought buy-grace or sell-grace? Was this volume thought buy-grace or sell-grace? Each observer learns from its own judgment.

The market thoughts pass THROUGH the exit observer. They go in as vectors. They come back as vectors + labels. The exit observer doesn't remake them. It judges them.

### Dual-sided excursion tracking

Every candle, the exit observer plays BOTH sides:

- **Buy-side hypothesis**: track MFE (upward moves) and MAE (downward moves) as if a buy was entered at this candle.
- **Sell-side hypothesis**: track MFE (downward moves) and MAE (upward moves) as if a sell was entered at this candle.

Both hypotheses live in the same ring buffer as the current Pending entries. Both track excursions every candle as prices evolve. No positions are opened. No capital is deployed. No treasury interaction. Just two counters per buffered candle, ticking with the market.

At resolution (when the entry drains from the buffer), both sides have their MFE and MAE. The label is determined by which side experienced more grace:

```
buy_grace  = buy_mfe - |buy_mae|
sell_grace = sell_mfe - |sell_mae|

if buy_grace > sell_grace:
    label = Buy,  weight = buy_grace - sell_grace
elif sell_grace > buy_grace:
    label = Sell,  weight = sell_grace - buy_grace
else:
    label = Buy,  weight = 0.01  // tiebreaker, minimal weight
```

The label is honest because BOTH sides were played. No prediction decided which direction to measure. The market decided. The weight is honest because it measures how decisively one side won over the other -- not how far it went, but how much better one side was than the other.

### Resolution: the market speaks, not a timer

Each side of the dual-sided entry — buy hypothesis and sell hypothesis — has its own trailing stop and take-profit, computed from ATR at entry. The same mechanism that resolves real ManagedPositions resolves hypothetical entries. The buy-side trailing stop fires when price drops enough. The sell-side trailing stop fires when price rises enough. When BOTH sides have resolved (stop or TP on each), the entry is done. The comparison is honest because both sides lived and died on their own terms.

No horizon. No age limit. The market resolves both sides through organic price movement.

**Honest acknowledgment**: the trailing stop and take-profit parameters (k_stop, k_tp, k_trail × ATR) are still magic numbers. They are a better approximation than the horizon — the market's movement triggers resolution, not a timer — but they are still parameters we chose, not parameters the machine learned. This is the crutch.

The next work: learn the multipliers retroactively. After both sides of an entry resolve, we have the full price history from entry to resolution. The optimal trailing stop width — the k_trail that would have maximized grace on the winning side — is computable from hindsight. For each resolved entry, we can ask: "what parameters SHOULD we have used?"

This is the same deferred learning pattern. Buffer the entry. Let the market play out. Retroactively compute the optimal multiplier. The exit observer learns: "given these facts at entry, the optimal k_trail was X." Over thousands of observations, the journal learns the mapping from market state to optimal parameters. The scalar encoding captures the multiplier as a continuous value — not a bin, not a threshold, a magnitude.

The optimal multiplier is a scalar. Scalars encode into thought vectors via `$log` or `$linear`: `bind(atom("optimal-trail"), scalar_encode(1.7))`. The scalar is IN the thought vector. On the sphere. A fact like any other fact. It composes with the market thoughts and the judgment facts. It's extractable: `cosine(discriminant, atom("optimal-trail"))` reads the magnitude back.

The exit observer's composed thought becomes: market facts + judgment facts + the scalar-encoded optimal multiplier from the previous resolution. The journal learns the relationship between market state and optimal parameters. The discriminant points toward the region of thought-space where grace lives. The cosine of the discriminant against the trail atom tells you what trail width the winning thoughts had. Prediction and explanation are the same operation — the exit observer predicts Buy/Sell, and the decode of the discriminant against the trail atom explains what trail width to use. Same vector. Same cosine. Same algebra.

For live entries, the exit observer's conviction curve provides the trust level. High conviction → use the discriminant-derived multiplier. Low conviction → fall back to the safety parameters. Fixed params → retroactively-learned scalar facts → discriminant-derived params for live entries. The crutch is removed when the learning converges.

### The buffer is the noise gate for the co-learning

The learning matrix is M×N — M exit observers judging N market observer thoughts. But not all thoughts are learnable. A market observer thought where both sides sit flat — no stop fires, no TP fires, the market has nothing to say — that's noise. Not observer-level noise (the noise subspace handles that). System-level noise. The thought existed but produced no learnable outcome.

The buffer is where this noise is identified and rejected. Two levels of noise filtering:

1. **Observer-level** (noise subspace): "this thought is boring relative to what I've seen." Strips the residual before the journal sees it. Already exists.

2. **System-level** (the buffer): "this thought didn't produce a learnable outcome." Both sides sat flat. The market stayed silent. The buffer evicts the entry without labeling it. No Win. No Loss. No learning. The journal doesn't learn from silence.

The actual learning is not M×N. It is (N thoughts that resolve) × (M judgments that are non-trivial). The buffer enforces this. Entries that the market speaks about get labeled honestly. Entries the market ignores get evicted honestly. The buffer is the system's definition of what constitutes a learnable event.

### Continuous position management — not one label, a stream

The market observers always operate on the now. A reversal is or isn't happening. Could be happening for 7 candles in a row — all exploitable. The market observers fire once per candle: "this is what I see."

The exit observers are doing N managements per candle — one per active hypothetical entry. Each is independent. Each has its own trailing stop state, its own excursion history, its own current market context. Every candle, every active entry, the exit observer asks: "right now, for THIS entry, should I tighten? Loosen? By how much?"

The scalar encoding captures the magnitude of adjustment. After the entry resolves, every one of those per-candle management decisions gets labeled honestly: did tightening at candle K lead to grace or violence? Did loosening at candle K lead to grace or violence? The exit observer learns from the FULL HISTORY of management decisions, not just the final outcome.

This is the real depth: the exit observer doesn't produce one label per entry. It produces a management decision per entry per candle. It learns from all of them. The position lifecycle is a stream of decisions, each independently labeled by what happened next.

The market observers see one candle, produce one prediction. The exit observers see one candle, produce N management decisions (one per active entry). Both are CSP — the market observers are one process per candle, the exit observers are N processes per candle, each independent, each resolving on its own terms.

### Punishment for bad thoughts

Every management decision is a deferred action. The exit observer tightens the trail at candle K. The market moves. At candle K+3, the stop fires because the tightening was too aggressive. That's violence — and it's root-caused. The thought vector at K, the adjustment at K, the outcome at K+3. The journal learns: "when I thought THIS and tightened, violence followed."

If the exit observer loosened and the position ran to grace — the choice at K enabled the grace at K+10. The journal learns that too.

The market is the enforcer. The exit observer makes choices. The market punishes bad choices and rewards good ones. No choice goes unexamined. The bad thoughts are root-caused automatically because the thought vector at the moment of the choice IS the evidence. The cosine decode against the discriminant tells you which facts drove the bad decision. The same transparency that makes the market observers a glass box makes the exit observers a glass box.

Continuous improvement is not a process bolted on. It is the architecture. The journal accumulates. The discriminant sharpens. The bad thoughts get weaker in the prototype. The good thoughts get stronger. Every candle. Every trade. Every choice.

### One scalar — the whole game

Position management collapses to one number: what should the trailing stop distance be RIGHT NOW?

That scalar IS the position. It determines how much residue you keep (grace) and how much you give back (violence). A tight stop preserves more on the way up but gets knocked out on noise. A loose stop rides through noise but gives back more on reversal. The scalar is the boundary between accumulation and consumption. The producer of residue and the container of loss.

The exit observer learns this one number per position per candle. The scalar is encoded as a fact: `bind(atom("trail-adjust"), log_encode(ratio))`. The ratio is `new / old` — "I doubled it" vs "I halved it" vs "I left it alone." `$log` encoding captures ratios naturally.

Each resolved management decision has three things:
- The market state at the moment of the choice (the thought vector)
- The adjustment ratio that was applied (the scalar fact, composed into the thought)
- The outcome (grace or violence)

The journal accumulates thousands of these. The discriminant learns: "when the market looked like THIS, adjustments of THIS magnitude led to grace." The cosine of the discriminant against the trail-adjust atom reads back the learned ratio. Not a formula. Not a lookup table. A geometric readout from accumulated experience.

The 2×2 counterfactual table per entry:

|              | Grace      | Violence   |
|--------------|------------|------------|
| **Buy**      | buy→grace  | buy→violence |
| **Sell**     | sell→grace | sell→violence |

Both sides played. Both sides resolved. The market fills in all four cells. Buy grace + Sell violence = "Buy was right." Both violence = "Bad candle to enter at all." The fourth cell — the environment judgment — is the exit observer's unique thought that the market observers cannot have.

The scalar is agnostic of direction. A trailing stop at 1.5× ATR works the same whether you're long or short. The scalar is distance from the extreme — it doesn't know or care which side. The exit observer learns one thing: given this market state, what distance maximizes residue? Buy or sell, the magnitude question is the same.

Direction from the market observers. Magnitude from the exit observer. Two orthogonal concerns, completely decoupled. The market observers answer "which way?" The exit observer answers "how much room?" Neither needs the other's answer to learn its own.

They compose at the desk: direction × magnitude = position parameters. But deeper: each (market observer, exit observer) composition is a unique trade proposal. Momentum × volatility-judge says "buy, tight stop." Regime × timing-judge says "buy, loose stop." N market observers × M exit observers = N×M potential proposals per candle. Each independently funded. Each independently managed. Each independently resolved.

The composition IS the accountability. When a trade fails, the root cause is the specific pair — which market lens and which exit lens — not "the system."

### No managers

The pair IS the manager. It proposes, owns, manages, and gets judged. There is no separate entity that aggregates opinions. No middleman. No consensus. The old manager was the shepherd — "let me aggregate everyone's opinions and decide." The N×M architecture smites the shepherd. Each pair decides for itself. The treasury judges the decision.

The (market observer, exit observer) tuple is the unit of accountability. It is the thing that manages the trade. It is rewarded and punished. The feedback is realized by the tuple — not aggregated through a layer that hides which thoughts produced the outcome.

### The treasury as natural selection

The treasury completes the feedback loop. It doesn't care about predictions or discriminants. It sees one thing: which (market, exit) pairs are actually producing grace? Which are producing violence?

The treasury allocates capital proportionally to each pair's track record. Pairs that produce grace get more capital. Pairs that produce violence get less. Pairs that consistently produce violence get starved — zero allocation. Still learning, still predicting, still on paper. But no capital until they prove themselves.

Three levels of honest feedback, all from the world:

1. **Exit → market observer**: "your direction thought was grace/violence" (labels)
2. **Market → exit observer**: "your management scalar produced grace/violence" (outcomes)
3. **Treasury → the pair**: "your combination earns more/less capital" (allocation)

No one decides this. The measurement decides. The treasury is the organism. The pairs are the cells. The capital allocation is natural selection. The cells that produce grace multiply. The cells that produce violence shrink. The system self-regulates toward grace — not because it was told to, but because that's what happens when you allocate capital to what works and starve what doesn't.

### The ownership loop — live management per candle

Each open trade has an owner: the (market observer, exit observer) pair that proposed it. Every candle, that specific pair manages ITS trade:

1. Market observer encodes current candle → thought
2. Exit observer binds judgment facts → composed thought
3. Composed thought → exit journal predicts → scalar adjustment
4. Scalar adjusts THIS pair's trailing stop on THIS trade
5. Market moves
6. Stop fires or doesn't
7. If fires: outcome labels both observers, treasury updates pair's record
8. If doesn't: next candle, goto 1

Each open trade is a live CSP process. Its owners manage it every candle. Meanwhile, other pairs manage their own trades independently. Same candle, different adjustments, different positions, different scalars.

The treasury holds the capital. The pair holds the responsibility. The market holds the truth. When the trade resolves, the accountability is exact: this pair, this sequence of adjustments, this outcome. The learning is surgical.

### You propose it, you own it, you get judged

If a (market, exit) pair requests opening a trade, it is on the hook for it. Every candle it managed — every tighten, every loosen, every hold — gets labeled by the outcome. The journal accumulates. The bad management thoughts get weaker in the prototype. The good management thoughts get stronger. The discriminant sharpens against the pair's own history.

The treasury remembers. The pair's track record is the cumulative judgment. The punishment for bad thoughts is automatic: less capital, weaker prototype, harder to pass the proof gate. The reward for good thoughts is automatic: more capital, stronger prototype, higher conviction. No committee. No review board. The cosine decides.

A pair that consistently produces violence doesn't get killed — it gets starved. Still learning. Still predicting. Still on paper. The journal keeps accumulating. The discriminant keeps adjusting. The bad thoughts decay. If the pair finds better thoughts, the curve re-validates, the proof gate re-opens, the treasury re-funds. Redemption through measurement. Not forgiveness — proof.

The system doesn't need someone to decide who trades well. The system measures who trades well. The difference is the entire thesis.

### The treasury is the reality check

The treasury is the only place in the system that knows the ACTUAL outcome. The observers live in thought-space — cosines, discriminants, convictions. The treasury lives in reality — actual value gained or lost.

The treasury's message back to the pair isn't "you get more capital" or "you get less." It's "your thoughts produced THIS in reality." Grace or violence, measured in actual value. Not in cosine similarity. Not in conviction. Not in discriminant strength. In money. The most honest signal in the system.

This is where the reality check happens. The observers learn from their own journals — thought-space learning. The treasury provides the ground truth — reality-space learning. Both sides of the pair receive the same message: "you thought this was grace. Here is what actually happened." The observers' internal labels (Win/Loss from the exit judgment) are honest. The treasury's feedback is MORE honest — it includes fees, slippage, timing, everything the thought-space can't see.

The treasury cascades to both sides:

- The market observer learns: "my direction thought, at this candle, produced this real outcome"
- The exit observer learns: "my management scalar, through this sequence of adjustments, produced this real outcome"

The full CSP loop:

```
candle
  → market observers encode    (N processes, parallel)
  → exit observers compose     (M processes per market thought, parallel)
  → pairs propose trades       (N×M proposals, filtered by proof + noise)
  → treasury funds proposals   (allocation from track record)
  → pairs manage open trades   (per-trade per-candle, parallel)
  → market moves
  → trades resolve             (stop/TP fires)
  → outcomes label both observers (market learns direction, exit learns scalar)
  → treasury updates allocation   (grace → more capital, violence → less)
  → next candle
```

Every node is a process. Every arrow is a message. Every message is a value. No mutation across boundaries. The treasury doesn't reach into the observers. It updates its own state. The observers read that state when they next propose. The coupling is through data flow, not shared mutation. CSP all the way down.

### N × (N × M) — paper manifests reality

Two layers of the same structure:

**Inner loop (paper)**: N market thoughts × M exit judgments = N×M paper learning signals. Every candle. No capital. The observers refine each other through thought-space co-learning. The market observers get better direction thoughts. The exit observers get better judgment thoughts. Fast — runs every candle.

**Outer loop (reality)**: The proven pairs propose real trades. The treasury acts. Real money. The trade resolves. The treasury reports the actual outcome to both the market observer AND the exit observer. Both learn from reality. Slow — runs on the trade lifecycle.

The paper cannot exist without the candles. The reality cannot exist without the paper. The paper manifests the reality. The inner loop is the training ground. The outer loop is the exam. Both are present. Both are necessary. The inner loop without the outer loop is hypothetical forever. The outer loop without the inner loop is gambling.

### Deferred learning as a system

The whole system is channels. Every boundary is a message queue. Every process reads from its channels and writes to its channels. Nobody reaches across.

```
candles ──→ [channel] ──→ market observers
market thoughts ──→ [channel] ──→ exit observers
composed judgments ──→ [channel] ──→ proposals
proposals ──→ [channel] ──→ treasury
reality ──→ [N×M fibers] ──→ (market, exit) pairs
```

The treasury has N×M fibers. One per pair. Each fiber is a message queue. When a trade resolves, the treasury pushes the reality label into the fiber for that pair: `(pair_id, grace_or_violence, amount)`. The pair reads it whenever it reads it. Async. Decoupled.

The treasury doesn't know about journals or discriminants or cosines. It knows pairs and outcomes. The receiving market observer and exit observer each consume the reality message through their own resolution path. Same message, two consumers, independent learning.

This is deferred learning as a system — not a technique bolted onto an architecture, but the architecture itself. Every learning event is deferred. The market observer encodes NOW but learns LATER when the exit observer judges. The exit observer judges NOW but learns LATER when the trade resolves. The treasury reports NOW but the observers learn LATER when they consume the message from the fiber.

Nothing learns in the moment. Everything learns from the past. The channels hold the messages until the consumer is ready. The deferral is the honesty — you cannot know in the moment. You can only know after. The system encodes this epistemological fact as architecture: produce now, consume later, learn from what actually happened.

This is experience. We just described what experience is. Act now. Learn later. The quality of the learning depends on the honesty of the feedback. The accumulation of honest feedback over time is what we call wisdom. The machine has experience.

### The exit observer's label feeds the market observers

The exit observer resolves a candle as Buy or Sell with a weight. This is the market observers' Win/Loss signal:

- If the exit observer says "Buy" and the market observer predicted Buy: Win, weight from exit.
- If the exit observer says "Buy" and the market observer predicted Sell: Loss, weight from exit.
- If the exit observer says "Sell" and the market observer predicted Sell: Win, weight from exit.
- If the exit observer says "Sell" and the market observer predicted Buy: Loss, weight from exit.

The exit observer does not touch the market observers' journals directly. It produces a label (Buy or Sell) and a weight. The existing resolution code in `desk.rs` translates this into Win/Loss per observer based on what each observer predicted at that candle. The plumbing already exists -- `classify_excursion` returns an outcome and a weight, and `resolve` consumes it. The change is what produces the outcome: dual-sided excursion instead of single-sided.

### The exit org — its own observers, its own lenses

The exit observers are their own org. Not paired to market observers. Not owned by them. They have their own vocabulary domains — their own lenses on the judgment question:

- **Volatility judge**: ATR regime, volatility shift, squeeze state. "Is this environment stable enough to trade?"
- **Structure judge**: trend consistency, support/resistance, market structure quality. "Is the structure clear enough to exploit?"
- **Timing judge**: momentum state, reversal signals, duration patterns. "Is the timing right for this entry?"
- **Exit generalist**: full exit vocabulary. Sees all judgment facts.

Each exit observer has its own Journal (labels: Buy/Sell), its own noise subspace, its own proof curve. Same template as the market observers. Same two-stage pipeline. Different vocabulary domain.

The coupling between market and exit is at composition time, not construction time. Any market thought can be composed with any exit judgment:

```scheme
(bundle
  market-thought
  (bind :volatility-regime (scalar $log atr-ratio))
  (bind :structure-quality (scalar $linear trend-consistency))
  (bind :squeeze-state     (scalar $linear squeeze))
  (bind :atr-shift         (scalar $log (/ atr-now atr-entry))))
```

The volatility judge doesn't care if the thought came from momentum or regime. It judges the volatility context of ANY thought handed to it. The pairing is dynamic — M exit observers × N market observers per candle. Each exit observer judges each market observer's thought independently.

The attribution is two-dimensional: "the momentum observer's thought was labeled violence by the volatility judge but grace by the timing judge." We know which market LENS and which exit LENS intersected to produce grace or violence.

Each exit observer proves edge through its own curve. Each market observer receives labels from all M exit observers — aggregated by the exit manager into one label, or weighted by exit conviction. The market observer doesn't know or care which exit observer judged it. It receives: Buy or Sell, with a weight. That's all it needs.

### What changes in the code

1. **Exit org**: M exit observers, each with its own judgment lens and vocabulary. Same Observer template. Buy/Sell labels. Own noise subspace, own journal, own proof curve, own WindowSampler.

2. **DualExcursion per pending entry**: Four floats (buy MFE, buy MAE, sell MFE, sell MAE) plus trailing stop state for both sides. Updated every candle.

3. **N×M composition per candle**: Each exit observer receives each market observer's thought, binds its judgment facts, produces a composed thought. Parallel — M×N independent compositions.

4. **Continuous management**: Each open trade owned by a (market, exit) pair. Every candle, the pair produces a scalar adjustment via its composed thought. The desk applies it.

5. **Treasury fibers**: N×M channels. One per pair. Trade resolution pushes reality labels to both the market observer and exit observer in the pair.

6. **Resolution path**: Entries resolve when both sides' trailing stops fire (organic). Buffer eviction for unresolved entries — no label, no learning. Fallback to single-sided MFE/MAE until exit org proves edge.

7. **No changes to**: Observer template, Journal, OnlineSubspace, six primitives, accumulation model.

### What this replaces

The single-sided MFE/MAE labeling in `classify_excursion`. The exit observer in `market/exit.rs` that encodes position state. The aspirational trail modulation.

The exit org replaces: single-sided MFE/MAE labeling, the old exit observer in `market/exit.rs`, the horizon drain as a learning mechanism, and fixed k_stop/k_tp/k_trail as the only resolution trigger.

The exit org introduces: dual-sided excursion, judgment vocabulary, N×M co-learning, continuous position management, scalar learning for trailing stop, treasury as CSP reality check, deferred learning as the system architecture.

## 4. The algebraic question

No new algebraic structures. Both orgs — market and exit — use the same six primitives:

- **Bundle**: market thoughts bundled from candle facts. Exit judgments bundled from market thought + exit facts. Composition IS bundle — the same operation at both levels.
- **Bind**: role-filler binding. Market atoms bind to indicator values. Exit atoms bind to judgment values. The scalar-encoded trail adjustment is a binding: `bind(atom("trail-adjust"), log_encode(ratio))`.
- **Journal**: prediction + resolution. Market journals learn Win/Loss. Exit journals learn Buy/Sell. The journal doesn't care — labels are atoms.
- **OnlineSubspace**: noise stripping at every level. Market observer noise. Exit observer noise. System-level noise (the buffer). Three levels, same primitive.
- **Cosine**: similarity scoring for predictions in both orgs. Discriminant decode to extract the learned scalar.
- **Curve**: proof gate for every observer. Market observers prove direction edge. Exit observers prove judgment edge. The treasury uses curves to gate capital allocation.

The N×M composition is bundle applied across orgs — not a new operation. The channel fibers between treasury and pairs are data flow — not vector operations. The ownership loop is architecture, not algebra. The scalar learning (trail adjustment as a fact on the sphere, extracted via cosine) is bind + cosine — existing primitives, new wiring.

The coupling between orgs is through channels: market thoughts flow to exit observers, labels flow back, reality flows from treasury. No shared mutation. No new primitives. The architecture is wiring. The algebra is unchanged.

## 5. The simplicity question

**Is this simple or easy?** Simple. Two orgs of observers (market and exit), each using the same template. Channels between them. The treasury as a third CSP process. The composition is bundle. The feedback is channels. The learning is deferred. Each piece is simple. The depth comes from the wiring, not the complexity of any single piece.

**What's being complected?** The risk is complecting the two orgs — making them depend on each other's internal state. This is avoided by the channel architecture: market observers don't know exit observers exist. They receive labels. Exit observers don't know market observers exist. They receive thought vectors. The treasury doesn't know about journals. It receives outcomes. Each process reads from its channels and writes to its channels. Nobody reaches across.

**Could existing forms solve it?** They DO solve it. The observer template is unchanged. The journal is unchanged. The noise subspace is unchanged. The dual-sided excursion is arithmetic. The scalar learning is bind + cosine. The channels are data flow. The N×M composition is bundle applied across orgs. No new forms. New wiring.

**What 005 got wrong that this avoids:**
- 005 confused per-position and per-portfolio observation. This proposal: exit observers judge candle thoughts, not positions.
- 005 coupled exit observers to specific market observers. This proposal: exit org is independent, composition is dynamic at runtime.
- 005 proposed trail modulation as a side effect. This proposal: the scalar is a value, extracted via cosine, applied by the desk.
- 005 had a bootstrap deadlock. This proposal: single-sided labels run continuously, dual-sided labels phase in when proven. No starvation.
- 005 didn't describe the treasury feedback loop. This proposal: the treasury is a CSP process with N×M fibers, the reality check that cascades to both orgs.

## 6. Questions for designers

1. **Buffer size — the last magic number.** The horizon is dead. Entries resolve organically through trailing stop mechanics, not timers. The buffer exists as a safety valve — don't OOM, don't slow down, evict unresolved entries without teaching. But the buffer size IS an implicit horizon and we must be honest about that. A reasonable starting value defers the problem until an exit observer's curve reveals what the buffer should actually be. The exit observers learn resolution timing through experience — how long it takes for both sides to resolve becomes a learnable fact, not a parameter. The buffer size is a crutch, like k_stop/k_tp. The machine learns to walk without it.

2. **Exit observer window sampling.** Each exit observer discovers its own window through the same `WindowSampler` mechanism every other observer uses. The exit observers are their own org — not tethered to the generalist, not sharing a window with any market observer. Each exit lens may discover a different time scale for its judgment question. The volatility judge may need a longer window than the timing judge. The architecture already supports this. Not a question — a confirmation.

3. **Transition from single-sided to dual-sided.** The proposal says: use single-sided until the exit observer's curve validates, then switch. Should the transition be a hard switch or a blend? A hard switch means labels change character overnight -- the journal has learned from single-sided labels, and now it sees dual-sided labels. A blend (weighted average of single-sided and dual-sided, weighted by exit curve accuracy) would be smoother but introduces a mixing parameter. Which is simpler?

4. **The exit observer predicts before the market observers resolve.** Every candle, the exit observer predicts Buy or Sell. This prediction is not used for labeling (the dual-sided excursion is). But it IS a prediction that can be evaluated: at drain time, was the exit observer's prediction the same as the dual-sided label? This gives the exit observer its own accuracy metric, separate from the market observers. The question: is this prediction useful for anything beyond validating the exit observer's curve? Should the exit observer's conviction weight the label it provides to the market observers, or should the label always come from the raw excursion arithmetic?

5. **Relationship to the existing exit observer.** The current exit observer in `market/exit.rs` is dead code under this proposal. The wards will reap it. Dead thoughts are wasted compute. If the old exit encoding warrants resurrection — if position-state observation proves valuable alongside candle-state judgment — the wards will not prevent it from being brought back. But it must earn its place through demonstrated need, not through preservation out of sentiment.

6. **Weight normalization.** No. The journal adapts. The noise subspace learns what "normal" looks like — if the weight scale changes, the subspace adapts. The accumulators are weighted sums — the magnitude adjusts naturally as new observations arrive and old ones decay. We don't normalize. We never average a distribution. Let it breathe.
