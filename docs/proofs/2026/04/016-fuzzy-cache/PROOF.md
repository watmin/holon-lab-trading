# Proof 016 — The hologram of a form (BOOK Chapter 59 dual-LRU coordinate cache, made operational)

**Date:** opened 2026-04-26, shipped 2026-04-27 (v4 after three
rejected drafts and one substrate add).
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/020-fuzzy-cache/explore-fuzzy-cache.wat`](../../../../wat-tests-integ/experiment/020-fuzzy-cache/explore-fuzzy-cache.wat).
Seven tests; total runtime 31ms.
**Predecessors:** **wat-rs arc 068** (`:wat::eval-step!`, shipped
2026-04-26 in three phases — this proof was its first consumer);
arc 057 (typed HolonAST leaves with derive-Hash); arc 058
(`HashMap<HolonAST, V>` at user level); arc 003 (TCO trampoline).
**No new substrate work in this proof.** Pure consumer of arc 068
plus the existing HashMap surface.

---

## What this proof claims

A surface form has a depth inside it. The depth is the form's
expansion chain: every intermediate rewrite the substrate would
perform to reduce the form to its terminal value. That depth is
not a private detail of one walker's stack — it is **publicly
addressable structure**. Each intermediate is itself a form, hence
a HolonAST, hence a coordinate on the algebra grid. Anyone who can
construct that intermediate can hash it and ask the cache.

The substrate ships two stores keyed by that coordinate:

- `next-cache` — *form → next-form*. The forward link. Says "after
  one rewrite, you get this."
- `terminal-cache` — *form → terminal-value*. The answer. Says
  "this form has been driven to a value; here it is."

A confirmed terminal is **an axiom**: a closed-form algebraic
result the substrate cannot produce a different answer for. Whether
the answer carries domain meaning is contextual — the trading lab's
*"6"* is BTC bars, not integers — but the algebraic identity does
not move. Two walkers that build the same form get the same
coordinate; the one who reaches the terminal first writes it; the
later one reads it.

Most cache architectures memoize `(input → output)` keyed by
hash-of-bytes. They cache opaque answers. They hide the path. A
walker can never benefit from another walker's *partial* progress
because partial progress has no name in those systems.

This proof demonstrates the substrate doesn't have that limitation.
The path inside the form is named. Every step is its own
coordinate. The terminal is an axiom. Walkers cooperate by
addressing the same structure independently — no agreement
protocol, no lock. **The structure itself is the agreement.**

---

## A — Why it took four iterations

```
v1 (synthetic atoms (double 5) / (square 3)):
  "those arn't things that can be eval'd"

v2 (small Expr enum + stepping evaluator):
  "still feels shallow.... real lambdas... real work"

v3 (bigger Expr enum, TCO, let-bindings):
  "your tooling here doesn't seem to use wat forms but
   something... else"

v4 (this, on arc 068):
  the substrate gap that v1–v3 worked around was named,
  arc 068 was written + shipped (~6h, 707 unit tests
  green), and v4 became ~30 lines of consumer code.
```

Each pushback said the same thing: the form should BE wat, not a
parallel mini-language the proof invents. Without
`:wat::eval-step!`, the proof had no choice — wat HolonAST/WatAST
are opaque at user level (no `bind?`, `bind-lhs`, `head-of`,
`args-of` destructors). The fourth iteration uses the real
primitive on real wat:

```scheme
(:wat::core::quote
  (:wat::core::let* (((x :i64) 5))
    (:wat::core::i64::* x x)))
```

That captures as `:wat::WatAST`. Feed it to `:wat::eval-step!`,
get `Ok(StepNext form)` or `Ok(StepTerminal value)`. Drive the
loop; record the chain in two HashMaps; backprop terminals up the
return path.

---

## B — The dual-LRU coordinate cache

Two HashMaps, both keyed by HolonAST identity:

```
next-cache     : HashMap<HolonAST, HolonAST>   form → next-form
terminal-cache : HashMap<HolonAST, HolonAST>   form → terminal-value
```

Both keys are `:wat::holon::from-watast form` — arc 057 closed
HolonAST under itself, so the lowering produces a canonical
structural fingerprint. Two forms with identical structure get
identical keys.

The walker is ~30 lines of pure wat:

```scheme
walk(form, cache):
  let form-key = from-watast(form)
  match terminal-cache.get(form-key):
    Some(t) → return (t, cache)                            ;; cache wins outright
    :None   → match next-cache.get(form-key):
                Some(n) → walk(to-watast(n), cache)         ;; chain hop, then backprop
                :None   → match eval-step!(form):
                            Ok(StepTerminal t) →
                              record-terminal(cache, form-key, t)
                            Ok(StepNext n) →
                              record-next(cache, form-key, from-watast(n))
                              let (t, cache') = walk(n, cache)
                              record-terminal(cache', form-key, t)  ;; backprop
                            Err(_) →
                              fall back to eval-ast! for the whole form
```

Every form encountered ends up in BOTH caches by the time `walk`
returns. A second walker that lands on any chain coordinate hits
the terminal-cache on its first lookup — O(1).

No Mutex. No thread coordination. Just a HashMap value passed by
ownership. Values up, not queues down.

---

## C — The seven tests

| # | Test | What it demonstrates |
|---|------|----------------------|
| T1 | `(+ 1 2)` → 3 | One step. Terminal lookup recovers `HolonAST::I64(3)`. |
| T2 | `(+ (+ 1 2) 3)` → 6 | CBV left-descent. Outer's next-pointer IS the inner chain coordinate. Backprop fills the outer's terminal. |
| T3 | `(let* (((x :i64) 5)) (* x x))` → 25 | arc 068's `let*` rule — peel one binding per step, textual-substitute x=5 in body. |
| T4 | `(sum-to 3 0)` → 6 | **TCO recursion.** Real define'd recursive function. arc 003's trampoline keeps wat stack constant; arc 068 exposes each β-reduction as a discrete step. |
| T5 | backprop completeness | The intermediate chain coordinate also has its terminal recorded. A walker landing mid-chain is O(1). |
| T6 | second-walker short-circuit | Re-walk same form on same cache. Cache size is identical before/after — zero new `eval-step!` calls. |
| T7 | walker cooperation via shared cache | Walker A walks `(+ (+ 1 2) 3)`. Walker B starts from `(+ 3 3)` — A's intermediate coordinate. B's terminal-cache lookup hits immediately; B inherits A's work via the HashMap value. |

T4 and T7 are the keystones. T4 confirms TCO under stepping; T7
confirms the Chapter-59 vision (walkers sharing partial work via
the cache) at the consumer level.

---

## D — Numbers

- **7 tests passing**, 0 failing.
- **Total runtime**: 31ms; per-test 3-4ms. T4's TCO recursion
  takes the same 3ms as T1's single step — the trampoline does
  its job.
- **Two iterations of fixes** during build-up: `:wat::core::=`
  doesn't dispatch on HolonAST yet (used `:wat::holon::coincident?`
  — the substrate's algebra-grid identity); my first stab at the
  cache-size guard reached for `:wat::core::HashMap::keys` (wrong
  path; the right primitive is `:wat::core::keys`, polymorphic
  pre-arc-058) but `:wat::core::length` works directly on the
  HashMap and reads cleaner.

---

## E — What this demonstrates that other systems don't

Three properties together:

1. **Every intermediate form is a coordinate.** Walker A's
   `(+ 3 3)` isn't a private detail of A's stack — it's a
   HolonAST, hashable, addressable, queryable from anywhere. Walker
   B that constructs that same form independently lands on the
   same cache slot. No agreement protocol; the structure IS the
   agreement.

2. **The cache holds the path AND the answer separately.** Walker
   A knew `(+ 3 3)`'s next-step before it knew `(+ 3 3)`'s
   terminal — and that's a real, observable, queryable state, not
   a locking artifact. Backprop fills the terminal up the entire
   chain after the walk completes. Another walker can land
   mid-chain and inherit that terminal.

3. **The terminal value is an axiom.** `(sum-to 3 0) → 6` is
   what that form *is in evaluation*. The substrate cannot
   produce a different answer; the algebra is closed and the
   steps are reproducible. Whether `6` *means* "summed integers"
   or "trade signal" or "page number" is contextual to the
   consumer. The algebraic identity does not move.

Conventional memoization caches opaque `(input → output)` pairs
keyed by hash-of-bytes. Build systems content-address actions
but the actions are opaque shell commands. JIT inline caches are
private to one process. CDN edges are flat — no expansion chain
visible. LLM caches are probabilistic. Database query caches
hide the plan. None of these expose the inside of a computation
as publicly addressable structure with an axiomatic terminal.

This proof shows the substrate does, and that consumers reach the
property in ~30 lines on top of arc 068.

---

## F — Composition with prior arcs

- **Arc 003** (TCO trampoline) — the walker's tail-recursive
  driver. T4 stresses it.
- **Arc 057** (typed HolonAST leaves) — structural Hash + Eq makes
  HolonAST a real cache key. Without it, no HashMap to live in.
- **Arc 058** (HashMap at user level) — the cache containers.
- **Arc 066** (`eval-ast!` returns wrapped HolonAST) — the
  fall-back path when `eval-step!` returns Err.
- **Arc 068** (`eval-step!`) — the substrate primitive this
  proof was the first consumer of.

---

## G — Honest scope

This proof confirms:
- Real wat forms (let*, arithmetic, recursive function calls,
  conditionals) walk one rewrite at a time via arc 068.
- The dual-LRU coordinate cache from BOOK Chapter 59 is ~30 lines
  of pure wat consumer code on top.
- TCO recursion through `(sum-to 3 0)` works under stepping.
- Backpropagation up the return path is correct; every chain
  coordinate is queryable in O(1) after the walk.
- Two walkers share work via plain HashMap value passing.

This proof does NOT confirm:
- **Sub-form walker independence.** arc 068 rewrites the OUTER
  form whole, so an inner sub-redex never has its own cache
  coordinate. T7 walks an intermediate chain coordinate
  (`(+ 3 3)`), not a sub-tree of the outer (`(+ 1 2)`). Walking
  arbitrary sub-trees needs a different traversal — out of scope.
- **Multi-thread parallel walkers.** T7 demonstrates cooperation
  via shared cache *value*; it doesn't run two threads
  concurrently. The HashMap supports it; the test doesn't exercise
  threading.
- **Cache eviction.** The cache grows unbounded. Production
  consumers wrap in `wat-lru`.
- **Locality-preserving fuzziness.** v4 uses structural HolonAST
  identity (exact equality on the grid). Combining with SimHash
  bucketing per BOOK Chapter 55 is future lab work.
- **Lambdas with closures.** arc 068 phase 3 supports bare
  lambdas; closure-bearing forms refuse with `NoStepRule`. This
  proof's recursive function is a top-level define.
- **Effectful ops.** arc 068 rejects them in step mode; the
  walker has an `eval-ast!` fall-back but no test exercises it.

---

## H — The thread

- BOOK Chapter 55 — *The Bridge* — names the two oracles.
- BOOK Chapter 59 — *42 IS an AST* — names the dual-LRU
  coordinate cache. *"form → next-form (expansion) and form →
  value (eval). Both LRUs key on the structurally-lowered
  HolonAST."* This proof is what the chapter pointed at.
- BOOK Chapter 62 — *The Axiomatic Surface* — observed (form,
  terminal) pairs accumulate as facts. This proof's terminal-cache
  IS that lattice at the form-evaluation layer.
- Arc 068 — the substrate primitive Chapter 59 needed.
- **Proof 016 v4 (this)** — the consumer demonstration.

---

## I — What this means for downstream consumers

Any consumer building a memoizing evaluator, expansion-chain
analyzer, parallel walker, or labeled-program trainer can:

1. Express forms as real wat (via `quote` or `to-watast`).
2. Drive evaluation one step at a time via `:wat::eval-step!`.
3. Cache `(form → next, form → terminal)` keyed by HolonAST
   identity.
4. Share the cache across many walkers via plain value passing.

For the trading lab: indicator rhythm forms, candle-window
evaluators, decision-tree walks, regime transitions — all become
forms in the substrate, all become cache coordinates, all share
work across thinkers via the cache. BOOK Chapter 55's bridge has
its substrate now.

Four iterations is the methodology. v1–v3 worked around the
substrate. v4 named the gap, the substrate filled it, and the
proof became ~30 lines on top of a primitive that does the work.
**Lab demands; substrate answers; lab ships.**

PERSEVERARE.
