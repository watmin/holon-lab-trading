# Review: Proposal 003 — Observer Redesign

**Reviewer**: Rich Hickey (voice)
**Verdict**: CONDITIONAL

---

## The Good: You Found the Right Decomposition

The two-stage pipeline is a value pipeline. Data flows through transformations: thought -> noise projection -> residual -> journal prediction. No mutation, no coordination, no hidden state coupling. This is composition. The fact that it uses two existing primitives (OnlineSubspace and Journal) without inventing a third is the strongest signal that you're on the right track.

> "Two existing primitives composed: online-subspace (Template 2) and journal (Template 1). No new primitives. The generalist is a composition, not an invention."

Yes. This is exactly right. The best designs don't add things. They reveal that the things you already have compose in ways you hadn't tried.

## The Good: Observer as Configuration

> "The 'generalist' is just `vocab = all modules`. A specialist is `vocab = one module`."

This is simple. An observer is a value — a record of (vocabulary, noise-subspace, journal, window). The pipeline is a function over that record. The generalist is not a special case. It is the same function with a wider input. When your "special" thing turns out to be just a parameterization of the general thing, you've found the right abstraction.

The table showing market, risk, and exit as the same pipeline with different vocabularies and labels — that's the payoff of getting the abstraction right.

## The Concern: Learning Splits Are a Hidden Protocol

Here is where I pause:

```scheme
(match outcome
  :noise (update (:noise-subspace observer) thought)
  _      (observe (:journal observer) residual outcome weight))
```

This is a routing decision baked into the observer. The noise subspace sees raw thoughts. The journal sees residuals. The subspace learns from Noise labels. The journal learns from Buy/Sell labels. These are two different data flows, two different label semantics, two different learning regimes, running through what you're calling "one pipeline."

It's not complected in the Clojure sense — the data flows are cleanly separated. But it is two concerns wearing one hat. The prediction concern and the noise-learning concern happen to share a struct, share a candle event, share a lifecycle. That's fine as long as you never need to vary them independently. The moment you want the noise subspace to learn at a different rate, or from a different label set, or to reset without resetting the journal — you'll wish they were separate values composed at the call site, not interleaved inside the observer.

My condition: make the learning step a composed function, not a method on the observer. The observer should be a value that the pipeline transforms, not an object that knows how to transform itself.

## The Concern: "Standard Facts" Braid Vocabularies

> "Currently calendar is exclusive to Narrative. It should be standard — every observer sees time."

I disagree with the mechanism, not the goal. If every observer sees calendar facts, you've created a shared dependency. When you change the calendar encoding, every observer changes. When you add a new standard fact, every observer's noise manifold shifts. You've braided vocabularies that were independent.

The proposal says: "If time doesn't matter for momentum, the momentum observer's noise subspace strips it." This is using a learning mechanism to compensate for a design choice. You're adding complexity (standard facts to all observers) and then adding more complexity (noise subspace must learn to ignore them) to handle the first complexity.

The simpler answer: let the generalist see calendar. It already sees everything. If momentum needs time context, give momentum a calendar fact explicitly. Don't create a category of facts that silently appear in every observer's vocabulary. Explicit is simple. Implicit is easy. They are not the same thing.

## The Noise Subspace: Clean Separation, One Question

Learning from Noise-labeled candles is geometrically clean. Non-events define the boring manifold. What survives projection is the unusual. This is a legitimate decomposition of the problem: separate what's always true from what's distinctively true right now.

But the proposal asks (question 1): should the noise subspace learn from ALL candles or only Noise-labeled? The answer matters, and it reveals whether the concept is "average" or "uninformative." These are different things. The average of all thoughts includes signal. The average of Noise-only thoughts excludes signal. You want the latter. The proposal already knows this:

> "Those thoughts are definitionally uninformative."

Good. Don't second-guess it. Learn from Noise only. The question answered itself.

## Memory vs Forgetting

> "No decay: The noise manifold accumulates across all regimes."

Start here. Always start with the simplest hypothesis that could work. Accumulation is a value — the subspace is the sum of everything boring the observer has ever seen. Decay is a policy — it requires choosing a rate, which means choosing a timescale, which means choosing what matters. You don't know what matters yet. You have 652k candles. Run it. If eigenvalues stabilize, accumulation wins. If they drift, you have evidence for decay. Don't add a knob before you have evidence the knob is needed.

Engram snapshots at regime boundaries are the most complex option. Complexity is a cost. Pay it when the simpler options fail, not before.

## Candidate Thoughts: Which Are Worth It

**Recency** — yes. Time-since-event is a genuine new dimension. It's cheap (counter), it varies across candles, and it's not captured by any current fact. "200 candles of nothing" is a thought no current fact encodes.

**Distance from structure** — yes, but only as scalars. You already have comparison pairs (close vs sma20). The scalar distance is the continuous version of the zone fact. It adds resolution without adding a new concept.

**Candle character** (doji, hammer, engulfing) — no. Named morphologies are pattern matching dressed as facts. You're encoding structure into named categories and then encoding the categories into vectors. The candle's OHLCV ratios (body/range, upper-wick/range, lower-wick/range) as scalars carry the same information without the taxonomy. Let the subspace find the patterns. Don't pre-name them.

**Velocity** (ROC of ROC) — marginal. You already have ROC acceleration in oscillators. Moving it to "standard" adds a shared dependency for something one module already computes. See my concern about standard facts above.

**Self-referential** — this is the most interesting and the most dangerous candidate. An observer encoding its own accuracy and confidence duration into its thought vector creates a feedback loop. The journal learns from thoughts that contain information about the journal's own performance. If recent accuracy is high, the thought says "I'm accurate," the journal learns "thoughts that say I'm accurate predict well," and you get a self-reinforcing loop that breaks the moment accuracy drops.

The idea is sound — meta-cognition is real information. But it must be consumed by a DIFFERENT observer or the manager, not by the observer itself. If observer A's self-assessment is a fact in observer B's vocabulary, that's composition. If observer A's self-assessment is a fact in observer A's own vocabulary, that's a cycle.

**Sequence count as scalar** — yes. The boolean "3+ consecutive up" loses information compared to the scalar "7 consecutive up." This is strictly more expressive for zero additional cost.

## Summary

The two-stage pipeline is a sound composition of existing primitives. The "observer as configuration" abstraction is the right one. The noise subspace learning from Noise-labeled candles is a clean separation of concerns.

Three conditions:

1. **Keep learning as composed functions, not observer methods.** The observer is a value. The pipeline is a function. Learning is a separate function that produces a new observer value. Don't let the observer know how to teach itself.

2. **Drop "standard facts" as a category.** Let each observer's vocabulary be explicit. The generalist sees everything by construction. Specialists see what they're configured to see. No implicit shared vocabulary that silently appears in every observer.

3. **Self-referential facts must not feed back into the same observer.** An observer's meta-state is a fact for the manager or for other observers. Never for itself.

Start with no decay. Start with Noise-only training. Start with recency, distance-as-scalar, and sequence-as-scalar. Measure. Add complexity only when measurement demands it.

The pipeline composes. Ship it with these conditions met.
