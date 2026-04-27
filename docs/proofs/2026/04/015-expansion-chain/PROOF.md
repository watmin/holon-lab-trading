# Proof 015 — Expansion Chain (the two lookup primitives)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/019-expansion-chain/explore-expansion.wat`](../../../../wat-tests-integ/experiment/019-expansion-chain/explore-expansion.wat).
Six tests demonstrating the two distinct lookup primitives and
their independent evolution through evaluation phases. Total
runtime: 27ms.
**Predecessors:** chapters 39 (the budget), 40 (the DAG), proof
014 (depth honesty). This proof makes explicit a substrate model
the book has been describing for many chapters.
**No new substrate arcs.** Pure consumer using HashMap (proof 005's
Registry primitive) for the two caches.

---

## What this proof claims

Builder framing (2026-04-26):

> "we have stated in the book many times... two kinds of lookup
> structures... 'does this form terminate' and 'what is this
> form's terminal value' — both of these require the recursive
> expansion... we can be in a state where the next form is known
> /but the terminal value isn't/"

The substrate's evaluation model has TWO independent lookup
queries:

```
lookup-next(state, form)     → :Option<HolonAST>   ; the next-step
lookup-terminal(state, form) → :Option<HolonAST>   ; the answer
```

They evolve INDEPENDENTLY as evaluation progresses. The
intermediate state — `next` known, `terminal` unknown — is
real, observable, and load-bearing. This proof makes it
explicit on disk.

---

## A — The three phases of evaluation memoization

**Phase 1 — Forward expansion.** As the evaluator walks one
rewrite step at a time, it records `(form_i → form_{i+1})` in
the next-cache. After this phase: `lookup-next` answers; the
chain is walkable forward.

**Phase 2 — Terminal recognition.** Eventually the chain reaches
a primitive value (a leaf). The evaluator records
`(primitive_form → primitive_value)` in the terminal-cache.
Only the leaf has a terminal recorded; the interior of the
chain still has `lookup-terminal = :None`.

**Phase 3 — Terminal backpropagation.** For each form in the
chain, the evaluator records `(form → terminal_value)` in the
terminal-cache. Now `lookup-terminal` is O(1) for any form in
the chain — the answer is cached at every position, not just
the leaf.

| Phase | next-cache | terminal-cache | What's queryable |
|-------|------------|----------------|------------------|
| 0 (empty) | empty | empty | nothing |
| 1 (first step recorded) | `{form_0 → form_1}` | empty | next of form_0; nothing else |
| 1 (full chain) | `{form_0 → form_1, form_1 → form_2}` | empty | all next-pointers; no terminals |
| 2 (leaf recognized) | (same) | `{form_2 → form_2}` | next as before; terminal only on leaf |
| 3 (backpropagated) | (same) | `{form_0 → form_2, form_1 → form_2, form_2 → form_2}` | both queries O(1) for all forms |

**The intermediate state (Phase 1, before Phase 3) is the
load-bearing observation.** Memoization passes through this
state every time. Scheme, Common Lisp, Clojure all evaluate
this way under the hood — but their substrates don't model the
state explicitly. Wat does.

---

## B — Why this matters

Most language runtimes treat memoization as an opaque
optimization: "the cache stores results; cache miss → recompute;
cache hit → return cached." This collapses the two queries
into one ("did we compute this already?") and hides the
intermediate state.

The substrate's model surfaces both queries as separate
operations. This:

- Makes evaluation phase explicit ("we have next but not terminal
  yet" is queryable).
- Lets consumers route differently on each query ("if you only
  need the next-step, save a computation; if you need the
  terminal, walk").
- Models partial evaluation honestly — a function whose recursive
  expansion takes a long time has next-pointers fillable
  incrementally; the terminal isn't required to begin caching.
- Composes with proof 008's soundness gate (the next-pointer
  is a structural fact; the terminal value is a domain fact;
  they can be soundness-checked separately).

The substrate isn't inventing a new paradigm here. It's naming
a pattern the implementations of every memoizing evaluator
internally rely on — and exposing the named pattern as a
first-class primitive distinction.

---

## C — The six tests

| # | Test | What it demonstrates |
|---|------|----------------------|
| T1 | empty-cache-both-none | Both lookups return `:None` for unrecorded forms; substrate doesn't fabricate. |
| T2 | **THE INTERMEDIATE STATE** | After one `record-next`: `lookup-next = Some`, `lookup-terminal = :None`. The load-bearing observation. |
| T3 | full-chain-no-terminals | Phase 1 fully recorded for 3-form chain; all next-pointers present; no terminals yet. |
| T4 | leaf-terminal-recognized | Phase 2: leaf has terminal; interior of chain still `:None`. |
| T5 | terminals-backpropagated | Phase 3 complete: all forms have terminal recorded; `lookup-terminal` O(1) for any form. |
| T6 | two-chains-no-interference | Two independent chains in same cache; each terminal retrievable; no cross-contamination. |

T2 is the load-bearing test. The substrate explicitly supports
the state where `next-cache.has(form) && !terminal-cache.has(form)`.
Other tests verify the model holds across the full evaluation
phase progression.

---

## D — Numbers

- **6 tests passing**, 0 failing
- **Total runtime**: 27ms
- **Per-test runtime**: 3-4ms each
- **All six tests passed first iteration.**

---

## E — How this composes with prior proofs

- **Proof 005 (Receipts):** the Registry primitive (HashMap
  keyed by hex(bytes)) IS the substrate of the next-cache and
  terminal-cache. Same algebra; different roles.
- **Proof 008 (Soundness Gate):** can be applied to either
  query — "does this form's next-step satisfy our axioms?" or
  "does this form's terminal satisfy our axioms?" Two distinct
  soundness measurements depending on which question is asked.
- **Proof 010 (Causal Time):** the receipt's `(claim_time, anchor)`
  tuple is structurally similar to a (form, terminal) pair — both
  are claims that the substrate verifies via consistency checks.
- **Proof 014 (Depth Honesty):** verified that arbitrary-depth
  walks through capacity-bounded trees retrieve cleanly. This
  proof complements: even if the depth is reachable, the substrate
  needs the two-cache model to memoize the walk.

---

## F — Honest scope

This proof confirms:
- The substrate's two lookup primitives can be modeled in wat
  using existing HashMap + struct primitives.
- The intermediate state (next known, terminal not) is real and
  observable.
- The three evaluation phases progress as the book describes.
- Multiple chains coexist in one cache without interference.

This proof does NOT confirm:
- An actual evaluation engine that performs the expansion
  automatically. Tonight's tests record next-steps and terminals
  manually; a real evaluator would do it via recursive `eval`.
- Cache eviction policies (LRU, etc.). The substrate's HashMap
  grows unboundedly; production code wraps it in `wat-lru`.
- Concurrent updates to the cache. Tonight's tests are
  single-threaded.
- Performance at scale (millions of cached entries). Proof 013
  showed scaling at 500 receipts; this proof's cache shape would
  scale similarly.

What it DOES confirm: the model the book has been describing
for chapters is implementable on the substrate's primitives,
and the load-bearing intermediate state is observable in real
test code.

---

## G — The thread

- Chapter 39 — the budget (per-level capacity, depth is free)
- Chapter 40 — the DAG (Merkle DAG of computational intermediates)
- Proof 005 — Registry (HashMap as content-addressed lookup)
- Proof 010 — Causal Time (causal anchors as cited evidence)
- Proof 014 — Depth Honesty (capacity-bounded walks at the boundary)
- **Proof 015 (this) — Expansion Chain (two lookup primitives, intermediate state)**

This proof completes the substrate's evaluation-model story:
- Depth (proof 014): recursive structure walks reliably.
- Two queries (proof 015): the substrate's evaluator surfaces
  `next?` and `terminal?` as distinct first-class operations.
- Memoization phases (proof 015): the model captures partial
  evaluation honestly.

---

## H — What this means for downstream consumers

Any consumer building a wat-based evaluator or memoizer can:

1. Use HashMap as the cache substrate (proof 005's Registry).
2. Maintain TWO caches (next-cache + terminal-cache) instead of
   conflating them.
3. Route queries on cache state explicitly — "we have next,
   need terminal" is a real signal that should drive a
   continue-evaluation decision.
4. Compose with proof 008's soundness gate to verify either
   the structural step OR the terminal value, depending on
   which is being asked.

The substrate's distinction makes the consumer's evaluator
honest about its internal state. No more "did we compute this
already?" → answer is binary; ask the correct question.

PERSEVERARE.
