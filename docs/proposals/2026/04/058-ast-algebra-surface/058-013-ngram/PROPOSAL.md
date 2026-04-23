# 058-013: `Ngram` — n-Wise Adjacency + Bigram / Trigram Shortcuts

**Scope:** algebra
**Class:** STDLIB — **ACCEPTED (reframed 2026-04-18) + INSCRIPTION 2026-04-21**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## INSCRIPTION — 2026-04-21 — Shipped

All three forms landed.

- **Ngram:** [`wat-rs/wat/holon/Ngram.wat`](https://github.com/watmin/wat-rs/blob/main/wat/holon/Ngram.wat)
  - `(:wat::holon::Ngram (n :AST<i64>) (xs :AST<List<wat::holon::HolonAST>>) -> :AST<Result<wat::holon::HolonAST, wat::holon::CapacityExceeded>>)`
  - Slides a size-n window across `xs`, encodes each window with `:wat::holon::Sequential` (bind-chain from 058-009), bundles every window's compound into one composite holon via `:wat::holon::Bundle`.
- **Bigram:** [`wat-rs/wat/holon/Bigram.wat`](https://github.com/watmin/wat-rs/blob/main/wat/holon/Bigram.wat) — one-line shortcut: `` `(:wat::holon::Ngram 2 ,xs) ``
- **Trigram:** [`wat-rs/wat/holon/Trigram.wat`](https://github.com/watmin/wat-rs/blob/main/wat/holon/Trigram.wat) — one-line shortcut: `` `(:wat::holon::Ngram 3 ,xs) ``
- **Tests:** [`wat-rs/wat-tests/holon/Trigram.wat`](https://github.com/watmin/wat-rs/blob/main/wat-tests/holon/Trigram.wat) — two deftests covering the full chain (Ngram → Sequential → Permute + Bind). Participant window is present in the Trigram; unrelated atom is not.

### Result return type — inherited from Bundle

All three stdlib forms return `:AST<Result<wat::holon::HolonAST, wat::holon::CapacityExceeded>>` — the 2026-04-19 Bundle-Result slice forced every stdlib form that expands to Bundle to inherit its Result wrap. Callers either `match` explicitly or propagate with `:wat::core::try` (058-033). In the typical case where the input is well under capacity budget, the `Err` arm is unreachable; the type system still demands acknowledgment.

### Edge cases pinned

- `n <= 0` produces an empty bundle (zero vector).
- `n > xs.len()` produces an empty bundle (no window fits).
- Both paths return `Ok` with the zero-holon; no error.

Documented in `wat-rs/wat/holon/Ngram.wat` inline.

### What this inscription does NOT add

- **`Pentagram` / `Hexagram` / etc.** Users define `(:my::app::Pentagram xs) = (:wat::holon::Ngram 5 ,xs)` in their own namespace. The stdlib commits to Bigram + Trigram because those are the trading lab's proven shapes; higher-n graduates when a caller cites use.
- **Sliding-window-with-stride.** `Ngram` uses unit stride. Strided windowing (every-k-th n-gram) is userland composition via `:wat::core::take` / `:wat::core::drop` + Ngram.

---

## ACCEPTED with reframe + two named shortcuts — 2026-04-18

Ngram is stdlib. Its expansion uses the **bind-chain Sequential** from 058-009 (also reframed in the same pass). The proposal now ships **three stdlib forms**: `Ngram`, `Bigram`, `Trigram`.

### The three forms

```scheme
;; General n-wise adjacency. Sliding window of size n, each window
;; encoded as a bind-chain Sequential, all windows bundled.
(:wat::core::defmacro (:wat::holon::Ngram (n :AST<usize>) (xs :AST<List<wat::holon::HolonAST>>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Bundle
     (:wat::std::list::map
       (:wat::std::list::window ,n ,xs)
       :wat::holon::Sequential)))

;; Named shortcut for n=2 — pairs.
(:wat::core::defmacro (:wat::holon::Bigram (xs :AST<List<wat::holon::HolonAST>>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Ngram 2 ,xs))

;; Named shortcut for n=3 — triples.
(:wat::core::defmacro (:wat::holon::Trigram (xs :AST<List<wat::holon::HolonAST>>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Ngram 3 ,xs))
```

**Stdlib-as-blueprint logic:**
- `Ngram` demonstrates the general pattern (slide, Sequential-encode, bundle).
- `Bigram` and `Trigram` name the two universally common cases.
- Users write their own `:my::app::Pentagram`, `:my::app::Heptagram`, etc. in their own namespace by calling `(:wat::holon::Ngram 5 xs)` / `(:wat::holon::Ngram 7 xs)`. Datamancer 2026-04-18: *"A user once wants a 5-gram can call (that-thing 5) and give it name."*

### Why bind-chain Sequential matters here

Ngram windows are Sequential-encoded. Sequential's reframe (058-009 — bind-chain, not bundle-sum) flows directly into Ngram's expansion:

- `(:wat::holon::Trigram facts)` → `(:wat::holon::Ngram 3 facts)` → `(Bundle (map Sequential (window 3 facts)))`
- Each window becomes `Sequential([fact_i, fact_{i+1}, fact_{i+2}])` = `Bind(Bind(fact_i, Permute(fact_{i+1}, 1)), Permute(fact_{i+2}, 2))` — bind-chain compound, exactly what the trading lab's `indicator_rhythm` hand-rolls.

Under the earlier bundle-sum Sequential, Ngram produced soft superposition of windows — mathematically different, not matching production. The reframe corrects this.

### Production use

**Trading lab's `indicator_rhythm`** (`src/encoding/rhythm.rs`) — will migrate to stdlib forms:

```rust
// Before (hand-rolled trigrams):
facts.windows(3).map(|w| {
    Bind(Bind(w[0], Permute(w[1], 1)), Permute(w[2], 2))
}).collect()

// After (stdlib):
(:wat::holon::Trigram facts)
```

**Bigram pattern** — when the trading lab or other apps need pairwise compound encoding, `(:wat::holon::Bigram items)` gives a named form where the previous Chain proposal would have lived.

Datamancer 2026-04-18: *"I expect we will use this in the trading-lab — we just didn't have a useful tool yet."*

### Questions for Designers — resolved

- **Q1** (window encoding: Sequential or custom): RESOLVED — Sequential (bind-chain, per 058-009 reframe).
- **Q2** (edge cases — `n=0`, `n > length`, `xs=[]`): `n=0` is an error (empty window has no meaning); `n > length` produces an empty bundle (zero vector) per Bundle's empty-input behavior; `xs=[]` produces an empty bundle.
- **Q3** (specialized names `Bigram`/`Trigram`): RESOLVED — **ship both as stdlib macros** per the blueprint logic above. Users write higher-n names in their own namespace.
- **Q4** (stdlib dependencies): RESOLVED — `:wat::std::list::window` (sliding window combinator, iterator-method composition), `:wat::std::list::map` (core), `:wat::holon::Sequential` (this batch). All available.
- **Q5** (performance): Ngram(n) over a list of length k produces (k − n + 1) windows. At d=10,000, each window's Sequential encode is n − 1 Bind operations and n − 1 Permutes. Total: O(k · n) AST nodes, O(k · n) encode operations, O(k · n) cache entries if fully materialized. The cache absorbs most repeat work (identical windows across overlapping invocations share sub-computation). Document scaling; don't optimize preemptively.
- **Q6** (relationship to the trading lab's rhythm): RESOLVED — Trigram IS the trading lab's trigram construction. Migration follows once the wat-vm is live.

### What got rejected in the same pass

- **Chain (058-012)** — redundant with Bigram. Same expansion `(Ngram 2 xs)`. Reject; keep Bigram as the named form.
- The original bundle-sum Sequential expansion (058-009 initial draft) — corrected to bind-chain.

### What stays

Algebra stdlib inventory gains Bigram and Trigram as new macros, loses Chain. Net +1 stdlib form.

---

## Historical content (preserved as audit record)

**Original proposal dependency line:**
> Depends on: 058-009-sequential-reframing (window-encoding primitive), 058-012-chain (generalizes)

> **Updated 2026-04-18:** Dropped dependency on Then (058-011 REJECTED). The `n=2` special case expands to a bundle of binary Sequentials (equivalent to what Chain produces), not to `(Then ...)` calls.

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that encodes `n`-wise adjacency windows over a list of holons:

```scheme
(:wat::core::defmacro (:wat::holon::Ngram (n :AST) (holons :AST) -> :AST)
  `(:wat::holon::Bundle (n-wise-map encode-window ,n ,holons)))
```

Where `n-wise-map` is a regular stdlib function (not a macro) that slides a window of size `n` across `holons`, and `encode-window` encodes each window as a permutation-ordered Bundle (Sequential, specialized). The macro quasiquotes the call; `,n` and `,holons` splice in the argument ASTs.

### More concretely

```scheme
;; list-combinator helpers (regular stdlib functions, not macros)
(:wat::core::define (:wat::std::encode-window window)
  (:wat::holon::Bundle
    (map-with-index (:wat::core::lambda (t i) (:wat::holon::Permute t i)) window)))

(:wat::core::define (:wat::std::n-wise-map f n xs)
  ;; produces: (f xs[0..n]), (f xs[1..n+1]), (f xs[2..n+2]), ...
  ;; until the sliding window exhausts xs
  ...)

;; the macro itself — expands at parse time
(:wat::core::defmacro (:wat::holon::Ngram (n :AST) (holons :AST) -> :AST)
  `(:wat::holon::Bundle (:wat::std::n-wise-map :wat::std::encode-window ,n ,holons)))
```

The window-slicing combinator (`n-wise-map`) is a runtime list operation used inside the expansion — it is not itself a macro. The `Ngram` macro simply emits the canonical Bundle-over-n-wise-map call; Bundle, Permute, and the helpers do the actual work.

### Special cases

- `n = 1`: each window is a single holon; Ngram produces `(Bundle (list t0 t1 t2 ...))` — same as `(Bundle holons)`.
- `n = 2`: each window is a pair encoded as a binary Sequential; produces the same vector as `(Chain holons)`.
- `n = k`: each window is a `k`-tuple, permutation-encoded internally via Sequential, then all windows bundled.

### Semantics

Ngram captures "the n-sized adjacency structure of this list." It is to natural-language n-grams what Sequential is to positional encoding. A vocab module using Ngram asserts "the sliding-window view is what matters here, not the absolute positions."

## Why Stdlib Earns the Name

**1. Its expansion uses only existing core/stdlib forms.** Bundle, Permute are core; the window encoding decomposes into Bundle + Permute compositions. Ngram is a composition over primitives.

**2. It reduces ambiguity for readers.** `(Ngram 3 (list s1 s2 s3 s4 s5))` reads as "triplet-windowed encoding of these 5 stages." The expansion, written out, is a dense Bundle-of-Bundles-of-Permutes that requires the reader to infer the structure.

Both criteria met.

## Arguments For

**1. Classical n-gram structure is useful for many domains.**

Text, audio, event sequences, time series — any list where adjacent patterns matter — benefits from windowed encoding. The vocabulary of n-grams (bigrams, trigrams, 4-grams) is well-established.

**2. Generalizes Chain.**

Chain (058-012) is Ngram at `n=2`. Keeping both in stdlib gives readers a short name for the common case (Chain) and a parameterized name for the general case (Ngram). Analogous to how Sequential is Ngram with specific conventions.

Could Chain be deprecated in favor of `(Ngram 2 xs)`? Possibly, but `Chain` reads cleaner for the common case. Keep both.

**3. Bounded cache impact.**

Each window encoding is its own sub-AST. Caching happens at the window level. Two Ngrams over overlapping lists share windows automatically via the L1 cache — identical sub-windows produce identical vectors.

Example: `(Ngram 2 (list a b c d))` and `(Ngram 2 (list a b c e))` share the windows `(Sequential (list a b))` and `(Sequential (list b c))`. Different final outputs, but cached sub-computations reuse.

**4. Invariance properties.**

Ngram is shift-invariant on windows: moving a pattern within a longer list leaves the windows containing the pattern unchanged (even if the list-level position changes). This is the classical n-gram property that makes the encoding useful for sequence classification.

## Arguments Against

**1. Parameterization adds surface complexity.**

Ngram takes an integer `n` as its first argument, unlike Bundle/Chain which are unary over a list. Readers must remember the parameter order: "n comes first." Could be confusing if `n` is a computed value or passed through variable.

**Mitigation:** keyword argument or specialized names per `n` could solve this — `Bigram`, `Trigram`, `Quadgram`. But that proliferates names. Keeping one parameterized `Ngram` is cleaner than 5+ specialized forms.

**2. `n-wise-map` may not exist in the wat stdlib.**

The expansion depends on a sliding-window combinator. If unavailable, must define:

```scheme
(:wat::core::define (:wat::std::n-wise-map f n xs)
  (:wat::core::if (:wat::core::< (length xs) n)
      '()
      (:wat::core::cons (f (take n xs))
            (:wat::std::n-wise-map f n (:wat::core::rest xs)))))
```

Works but requires `take`, `length`, standard list combinators. Assumes these exist in the wat stdlib or become bundled additions.

**3. Edge cases: `n > length(holons)` or `n = 0`.**

What should `(Ngram 5 (list a b c))` produce? Options:
- Empty bundle (no windows fit) → zero vector.
- Degenerate to `Sequential` (just encode all items).
- Error.

Convention: empty bundle (zero vector), matches the mathematical n-gram definition. `n = 0` is undefined (document).

**4. Windowed encoding inside vs. outside.**

The proposal encodes each window as a Sequential-like position-permuted bundle, THEN bundles all windows together. An alternative: encode each window as Sequential (`(Sequential window)`), THEN bundle. Same operation, but using Sequential by name.

**Mitigation:** simplify the definition:

```scheme
(:wat::core::defmacro (:wat::holon::Ngram (n :AST) (holons :AST) -> :AST)
  `(:wat::holon::Bundle (:wat::std::n-wise-map (:wat::core::lambda (window) (:wat::holon::Sequential window)) ,n ,holons)))
```

Or, even more concise (once Sequential is a parse-time macro per 058-009):

```scheme
(:wat::core::defmacro (:wat::holon::Ngram (n :AST) (holons :AST) -> :AST)
  `(:wat::holon::Bundle (:wat::core::map :wat::holon::Sequential (:wat::std::n-wise-split ,n ,holons))))
```

Where `n-wise-split` produces the list of windows. Cleaner composition. Note that `Sequential` in the expansion is itself a macro — it is expanded in the same parse-time pass once `Ngram` is expanded.

## Comparison

| Form | Class | `n` | Description |
|---|---|---|---|
| `Concurrent(xs)` | STDLIB (058-010) | — | Order-insensitive bundle |
| `Then(a, b)` | STDLIB (058-011) | 2 (binary) | Pairwise directed |
| `Chain(xs)` | STDLIB (058-012) | 2 (sliding) | Pairwise transitions |
| `Ngram(n, xs)` | STDLIB (this) | n (sliding) | n-wise windows |
| `Sequential(xs)` | STDLIB (058-009) | — | Full position encoding |

Ngram is the generalized form; Concurrent, Then, Chain, and Sequential are specializations with specific values of `n` or specific encoding schemes.

## Algebraic Question

Does Ngram compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle of Bundles of Permutes; see FOUNDATION's "Output Space" section). Same dimensional space.

Is it a distinct source category?

No — it is a composition over Bundle and Permute with windowing. Stdlib.

## Simplicity Question

Is this simple or easy?

Conceptually simple (slide a window, encode each window, bundle). Implementation requires a sliding-window combinator, which may need to be added to stdlib first.

Is anything complected?

No. Ngram has one role: "encode the n-wise adjacency structure of a list." The parameter `n` controls window size; no other concerns mixed in.

Could existing forms express it?

Yes, once the sliding-window combinator is available. Pure composition.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib additions:**

```scheme
;; wat/std/sequences.wat

;; list combinator — regular stdlib function, not a macro
(:wat::core::define (:wat::std::n-wise-split n xs)
  (:wat::core::if (:wat::core::< (length xs) n)
      '()
      (:wat::core::cons (take n xs)
            (:wat::std::n-wise-split n (:wat::core::rest xs)))))

;; the macro itself — registered at parse time
(:wat::core::defmacro (:wat::holon::Ngram (n :AST) (holons :AST) -> :AST)
  `(:wat::holon::Bundle (:wat::core::map :wat::holon::Sequential (:wat::std::n-wise-split ,n ,holons))))
```

Depends on `take`, `length`, `map`, `rest` being available in the wat stdlib (standard list combinators). `Ngram` is registered at parse time (per 058-031-defmacro); every `(Ngram n xs)` invocation is rewritten to the canonical Bundle-of-Sequentials form before hashing, with `Sequential` itself further expanded by the same pass.

## Questions for Designers

1. **Window encoding: Sequential or custom?** The cleanest definition uses Sequential to encode each window. If 058-009 keeps Sequential as a stdlib form, this is clean. If Sequential is rejected (stays as variant), Ngram's internal window encoding inlines the Bundle+Permute pattern.

2. **Edge cases.** What does `(Ngram 0 xs)` produce? `(Ngram 5 (list a b c))`? `(Ngram 2 (list))`? Proposal: `n=0` is error, `n > length` is empty bundle (zero vector), `xs = (list)` is empty bundle. Confirm conventions.

3. **Specialized names for small `n`: `Bigram`, `Trigram`?** Pros: readable for the common cases. Cons: name proliferation. Recommendation: keep only `Ngram` as the parameterized form, and `Chain` as the `n=2` specialization (already in 058-012). Avoid `Bigram`/`Trigram` unless they earn distinct semantic intent beyond "Ngram with specific n."

4. **Stdlib dependencies.** `n-wise-split`, `take`, `length`, `map`, `rest` — these are standard list operations that Ngram depends on. Are all present in the current wat stdlib, or does this proposal need to bring them in as prerequisites?

5. **Performance.** An Ngram over a list of length `k` with window `n` produces `k-n+1` windows, each requiring a Sequential encoding. This is `O(k·n)` sub-AST construction and encoding, plus one top-level Bundle of `k-n+1` items. Acceptable for reasonable `k, n`; could be expensive for long lists. Document the scaling.

6. **Relationship to the generalist-observer's rhythm encoding.** The holon-lab-trading project uses an n-gram-like approach for indicator rhythms (bundled bigrams of trigrams). Is this proposal's `Ngram` the right primitive to replace that bespoke encoding, or is the trading-specific encoding subtly different?
