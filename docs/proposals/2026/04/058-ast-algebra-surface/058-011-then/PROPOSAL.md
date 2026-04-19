# 058-011: `Then` — Binary Directed Temporal Relation

> **STATUS: REJECTED from project stdlib** (2026-04-18)
>
> `Then` is the 2-argument specialization of `Sequential`. Same positional encoding; same math; same vector; same canonical AST after macro expansion. No runtime specialization. No corresponding `:Then<T>` type annotation. Under the same test that rejected `Concurrent` (redundancy with Bundle under its enclosing context), Then is redundant with Sequential.
>
> The "a then b" thought is meaningful in vocab code — particularly when we return to the trading lab and need to express ordered candle pairs, indicator transitions, pattern-followed-by-pattern. When that time comes, userland defines it in its own namespace:
>
> ```scheme
> (:wat::core::defmacro (:my::vocab::Then (a :AST) (b :AST) -> :AST)
>   `(:wat::std::Sequential (:wat::core::vec ,a ,b)))
> ```
>
> Same mechanics. Users' namespace. Project stdlib stays lean.
>
> **Chain (058-012) was defined in terms of Then.** Post-rejection, Chain inlines the binary-Sequential pattern:
>
> ```scheme
> (:wat::core::define (:wat::std::Chain (xs :Vec<holon::HolonAST>) -> :holon::HolonAST)
>   (:wat::algebra::Bundle
>     (pairwise-map
>       (:wat::core::lambda ((a :holon::HolonAST) (b :holon::HolonAST) -> :holon::HolonAST)
>         (:wat::std::Sequential (:wat::core::vec a b)))
>       xs)))
> ```
>
> This proposal is kept in the record as an honest trace of the design process.

**Scope:** algebra
**Class:** REJECTED (was STDLIB; rejected 2026-04-18 as arity-specialization of Sequential with no runtime specialization)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that encodes "a, then b" — a DIRECTED binary sequence:

```scheme
(:wat::core::defmacro (:wat::std::Then (a :AST) (b :AST) -> :AST)
  `(:wat::algebra::Bundle (:wat::core::vec ,a (:wat::algebra::Permute ,b 1))))
```

The first holon passes through unchanged; the second is permuted by one step. The bundled result is a vector whose structure encodes "a comes first, b comes after." The permutation makes `(Then a b)` categorically distinct from `(Then b a)` — order matters. Expansion happens at parse time, so `hash(AST)` sees only the canonical Bundle-over-Permute form.

### Semantics

`Then` is the pairwise temporal relation. Two events, one after the other. The permutation asserts the directedness: without it, `Bundle(a, b) = Bundle(b, a)` and order is lost. With Permute on the second, "which came first" is preserved.

## Why Stdlib Earns the Name

**1. Its expansion uses only existing core forms.** Bundle is core, Permute is core.

**2. It reduces ambiguity for readers.** `(Then a b)` reads as "a, then b" — the temporal semantics are explicit. `(Bundle (list a (Permute b 1)))` is mechanically identical but requires the reader to recognize the pattern.

Both criteria met.

## Arguments For

**1. Binary directed sequence is the atomic unit of temporal reasoning.**

Many vocab operations want "A preceded B":
- Price rise THEN volume spike
- Signal THEN entry
- Observation THEN consequence

Having `Then` as a named form lets vocab code express these directly. Without it, every pair-wise temporal relation is an ad-hoc `(Bundle a (Permute b 1))`.

**2. Building block for `Chain` (058-012) and `Ngram` (058-013).**

Chain is "a, then b, then c, then d" — a walk of Then operations over a list. Ngram is "windowed Then over adjacent n-tuples." Both use Then as the primitive pairwise unit.

Having a named Then lets Chain and Ngram write:

```scheme
(:wat::core::defmacro (:wat::std::Chain (holons :AST) -> :AST)
  `(:wat::algebra::Bundle (pairwise-map :wat::std::Then ,holons)))
```

Rather than inlining the permutation logic in each. Because `Then` is itself a macro, the expansion recurses — nested macros expand in turn until only algebra-core operations remain.

**3. Permute parameter makes temporal directionality explicit.**

`(Permute b 1)` is the one step of permutation that distinguishes "b in position 2" from "b in position 1." Consolidating this into `Then` hides the permutation count behind the operation name — readers don't need to remember "which permute index means 'next'."

**4. The expansion handles composition cleanly.**

`(Then (Then a b) c)` expands to `(Bundle (list a' b' c'))` where the outer structure captures that there are two stages. But temporal-chain semantics prefer FLAT walks — this is where Chain comes in (see 058-012). Then itself is the binary atom; Chain composes Then over arbitrary-length sequences.

## Arguments Against

**1. The permutation count is hardcoded to 1.**

Why 1? Because one permutation is enough to distinguish "first" from "second" for the bundle. But this is a convention, not a principle. A bigger permutation gap would also work (Permute b 2 or b 3 would also distinguish positions), just with different dimensional mixing.

**Mitigation:** convention-based hardcoding is fine for a stdlib form — it encodes the convention explicitly. Users who need different permutation schemes can write their own stdlib forms. Then is the common case.

**2. Asymmetric: only second argument is permuted.**

Could also be written as `(Bundle (Permute a 0) (Permute b 1))` — treat the first as position 0 and the second as position 1, both explicitly permuted. More symmetric, more verbose.

**Mitigation:** `Permute a 0` is an identity operation (no-op permutation). Writing it explicitly is redundant. The asymmetric form `(a, Permute b 1)` is operationally identical and cleaner.

**3. Is this just a special case of `Sequential`?**

`(Sequential (list a b))` with a 2-element list expands to `(Bundle (list a (Permute b 1)))` — the SAME as `(Then a b)`. So Then is "Sequential specialized to two arguments."

**Mitigation:** yes, and this is the point. Then communicates "binary pairwise temporal relation" semantically. Sequential communicates "positional encoding of an n-long list." Two different intents, same underlying mechanism at length 2. Keep both names; they serve different reader contexts.

The relationship:
- `(Then a b)` ≡ `(Sequential (list a b))` at length 2
- `(Chain (list a b))` ≡ `(Then a b)` at length 2
- `(Sequential xs)` ≡ `(Chain xs)` ? (see 058-012 — they might be different)

These equivalences at short lengths are natural; longer lengths reveal the distinct semantics.

**4. Bi-directional vs uni-directional.**

`Then` is uni-directional: `(Then a b) ≠ (Then b a)`. This is the point. But some applications want "a and b related, either direction" (pairwise association). That is not Then; it is `Concurrent` or `Pattern`. Clear distinction needed in documentation.

## Comparison

| Form | Class | Arity | Semantic intent | Expansion |
|---|---|---|---|---|
| `Bundle(xs)` | CORE | list | Superposition | primitive |
| `Concurrent(xs)` | STDLIB | list | Co-occurrence | `(Bundle xs)` |
| `Sequential(xs)` | STDLIB | list | Positional encoding | `(Bundle (list xs[i] permuted by i))` |
| `Then(a, b)` | STDLIB (this) | 2 | Pairwise temporal | `(Bundle (list a (Permute b 1)))` |
| `Chain(xs)` | STDLIB (058-012) | list | Pairwise-Then chain | `(Bundle (pairwise-map Then xs))` |
| `Ngram(n, xs)` | STDLIB (058-013) | list, n | n-wise adjacency | `(Bundle (n-wise-map Then-like xs))` |

Then sits at the center of the temporal stdlib — the binary atom. Chain, Ngram, Sequential build on it (or use similar Permute-based encoding).

## Algebraic Question

Does Then compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle's threshold of a permuted input; see FOUNDATION's "Output Space" section), same dimensional space. All downstream operations work.

Is it a distinct source category?

No — it is a 2-element specialization of Bundle + Permute composition. Stdlib, not a new algebraic operation.

## Simplicity Question

Is this simple or easy?

Simple. Two-argument binary form. One-line expansion. Clear semantics.

Is anything complected?

No. Then has a single role: "a, then b." It doesn't mix temporal semantics with other concerns.

Could existing forms express it?

Yes — `(Bundle (list a (Permute b 1)))`. Named form is for reader clarity.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — one macro, registered at parse time:

```scheme
;; wat/std/sequences.wat (or similar)
(:wat::core::defmacro (:wat::std::Then (a :AST) (b :AST) -> :AST)
  `(:wat::algebra::Bundle (:wat::core::vec ,a (:wat::algebra::Permute ,b 1))))
```

Registration is parse-time (per 058-031-defmacro): every `(Then ...)` invocation is rewritten to the canonical Bundle-over-Permute form before hashing.

## Questions for Designers

1. **Permutation count convention.** This proposal uses `(Permute b 1)`. Is 1 the right convention, or should it be a larger gap (e.g., 7, 13) for better dimensional decorrelation? Small permutations may not mix dimensions enough for downstream cleanup to distinguish positions. Should the stdlib form use a carefully-chosen constant, or always 1?

2. **Relationship to `Sequential` at length 2.** `(Then a b) = (Sequential (list a b))` if both use the same permutation scheme. Should they be enforced-equivalent at this length, or could their implementations diverge (different permutation choices)? Consistency seems valuable.

3. **Should Then also have a reverse form (`After(b, a) = Then(a, b)`)?** "A happens after B" is sometimes more natural than "B happens, then A." Same operation from the opposite reading. Worth a separate stdlib name, or too much alias proliferation?

4. **Chaining `Then` operations.** `(Then (Then a b) c)` creates a nested structure with TWO levels of permutation (b permuted once inside, the whole `(Then a b)` permuted once more when combined with c). Is this the intended recursive structure, or should `Chain` (058-012) handle multi-step chains flat? This proposal assumes `Chain` handles flat chains; nested Then is structurally meaningful but less common.

5. **Application to event sequences.** Vocab modules encoding event sequences (candle → indicator → signal → entry) would chain Thens. At what point does the recursive Then structure break down dimensionally? Small vectors (d=1024) may not support deep chains before cleanup fails. Worth noting in documentation.
