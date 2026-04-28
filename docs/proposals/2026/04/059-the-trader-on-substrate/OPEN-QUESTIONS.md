# 059 — Open questions

Questions this umbrella holds that **don't have answers yet**.
Phase 2's iteration is how most of them get resolved. Some are
substrate-level questions for /gaze or for new arcs.

## Phase-2 questions (resolved empirically through the playground)

### Q1 — What thoughts produce Grace?

Proposal 056's specific encoding (indicator-rhythm + bigrams of
trigrams) was placeholder. The substrate-native trader's actual
thoughts are open. The designer-subagent protocol resolves this:
each round, voice subagents propose thoughts in their philosophical
lens; the playground runs them; labels accumulate at coordinates;
the labels tell us which voices are right when.

**Voices to consult** (one per subagent, no cross-talk per the o.g.
wat protocol):

- **Wyckoff** — accumulation/distribution, volume on rallies vs
  declines, springs and upthrusts. *"What is this market accumulating
  right now?"*
- **Seykota** — trend persistence, selection over prediction. *"Is
  the market in a trend strong enough to follow?"*
- **Van Tharp** — expectancy, R-multiples, position sizing. *"Is the
  risk-reward worth taking?"*
- **Hickey** — simplicity, values-not-places, composition integrity.
  *"Is this thought composing cleanly without complecting concerns?"*
- **Beckman** — monoidal coherence, algebraic closure. *"Does this
  thought compose with itself and its siblings under bind/bundle?"*

### Q2 — How do we recognize "this coordinate tends toward Grace"?

The labeling discipline. BOOK chapters 45 (*The Label*), 46 (*The
Proof*), 55 (*The Bridge*), 56 (*Labels as Coordinates*), 57 (*The
Continuum*), 62 (*The Axiomatic Surface*), 65 (*The Hologram of a
Form*), 66 (*The Fuzziness*) carry the framework. But the
operational distillation — *how the lab uses labels-at-coordinates
to choose which thoughts advance* — hasn't been written down as a
single discipline doc.

**Action before Phase 2:** spawn a subagent to read those chapters
and produce `LABELING-DISCIPLINE.md` in this umbrella. That doc
becomes the operational guide for Phase 2.

### Q3 — Per-leaf encoding choices: when F64 vs Thermometer?

Per chapter 66, the substrate offers two scalar leaf encodings:
F64 (quasi-orthogonal; identity per value) and Thermometer
(locality-preserving; values-near-each-other-near-each-other).
The choice picks the depth at which fuzziness emerges in the
expansion chain.

**Open:** for which kinds of thoughts does the consumer want
Thermometer at the leaf vs F64? Per indicator? Per indicator AND
per delta? Per regime fact? Phase 2's iteration answers this
indicator-by-indicator. The first round's voices likely converge
on Thermometer-everywhere (locality is what we want for cache
sharing); subsequent rounds may differentiate.

### Q4 — Phase labeler placeholder vs rewrite?

`wat/encoding/phase-state.wat` is the existing phase labeler.
Phase 1's gate-1 uses it as-is. Phase 2 may surface that the
labeler's output isn't the right shape for the new substrate's
thought structure. Until Phase 2 surfaces a need, **don't
rewrite preemptively.**

## Substrate-level questions (might surface during the build)

### Q5 — Conservation invariant assertion mechanism

Slice 2's treasury work asserts the conservation invariant every
candle. Where it lives is open:

- **(a)** `debug_assert!` in Rust (catches in debug builds; silent
  in release).
- **(b)** A wat-tests-integ property test that runs over N candles
  (catches in tests; silent in production runtime).
- **(c)** A new substrate ward — runtime invariant primitive.

Per the user's call (BACKLOG B-5: *new wards only if we need them*):
**default to (a) or (b); only file (c) if neither suffices.**

### Q6 — Status panel rendering primitive

Slice 5's terminal status panel needs a glanceable, rendered-every-N-
candles table. Whether the lab's existing rendering infrastructure
suffices, or whether a small new wat helper is wanted, surfaces in
slice 5. **Don't preemptively design.**

## Architectural questions (defer until they bite)

### Q7 — Lambda support for thoughts?

Per arc 068 phase 3, bare lambdas step to `StepTerminal HolonAST::Atom`;
closure-bearing functions refuse with `NoStepRule`. Phase 2's
designer voices may produce thoughts that want closures (e.g., a
Hickey-style higher-order combinator). When they do, file the
substrate arc; until then, defer.

### Q8 — Multi-walker concurrency in production

Chapter 66's walker cooperation works through HashMap value passing
in proofs 016 v4 + 017. This umbrella's runtime is also single-
process; the wat-vm's parallel workers (broker grid) cooperate via
the L2 cache. Whether the cache cooperation actually scales linearly
with thread count under real load is empirical; falls out of slice
3's measurement. Defer.

### Q9 — Engram library integration

Per Chapter 55's bridge: *"the engram library, when it lands, gives
the reckoner per-bucket exemplars — 'I have seen something like this
1,243 times; of those, 67% labeled Buy.'"* This umbrella does NOT
ship the engram library; the reckoner runs without it. Future arc.

## What this file is for

When a question gets answered (empirically by Phase 2 or by a new
arc's work), update the entry with the resolution. Don't delete —
the question + the answer is the lineage.

When new questions surface during slicing, add them here. The
umbrella's questions are the umbrella's living spec.
