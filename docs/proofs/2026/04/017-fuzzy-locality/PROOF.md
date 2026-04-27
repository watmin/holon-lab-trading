# Proof 017 — The fuzziness (locality-keyed coordinate cache via `coincident?`)

**Date:** opened 2026-04-27, shipped 2026-04-27.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/021-fuzzy-locality/explore-fuzzy-locality.wat`](../../../../wat-tests-integ/experiment/021-fuzzy-locality/explore-fuzzy-locality.wat).
Six tests; total runtime 35ms; all green first iteration.
**Predecessors:** **proof 016 v4** (the dual-LRU coordinate cache,
keyed by exact HolonAST identity). **wat-rs arc 068**
(`:wat::eval-step!`); arc 057 (typed HolonAST leaves with
locality-preserving Thermometer alongside quasi-orthogonal F64);
arc 023 (`coincident?` — the algebra-grid identity predicate).
**No new substrate work.** Pure consumer of arc 068 + `coincident?`
+ Thermometer.

---

## What this proof claims

Builder framing (2026-04-27, mid-victory-lap on proof 016 v4):

> "now... let's do the same.. but with thermometer values... i want
> to prove that we can have 1.95 and 2.05 be coincident in some
> holographic depth to short cut...
>
> this is the 'fuzzy-ness'... we used concrete values in the last
> run i believe... now show that we can use the substrate itself
> to shortcut"

Proof 016 v4 keyed the cache by **exact** HolonAST identity (arc
057's derive-Hash + derive-Eq). Two forms differing in any leaf
were distinct cache slots. The cache wins when two walkers
construct *the same form*; it doesn't help when they construct
*near* forms.

This proof keys the cache by `:wat::holon::coincident?` — the
substrate's cosine-based "are these the same point on the algebra
grid within sigma?" predicate. Two forms whose ENCODED VECTORS are
coincident hit the same cache slot, even when their HolonAST
structure is technically different.

The substrate-level claim being demonstrated:

**The holographic depth of a form has fuzzy-eligible coordinates
and exact-eligible coordinates. Fuzziness emerges deeper in the
chain.** The walker uses fuzzy lookup at every level; pre-β
coordinates miss because F64 leaves encode quasi-orthogonally;
post-β coordinates hit because Thermometer leaves encode
locality-preservingly. The cache short-circuits at the FIRST
coincident coordinate it finds.

That is what *"some holographic depth to short cut"* names.

---

## A — The mechanism

A function that wraps an f64 in a Thermometer-encoded Bind:

```scheme
(:wat::core::define
  (:my::indicator (n :f64) -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom "indicator")
    (:wat::holon::Thermometer n -100.0 100.0)))
```

A walker walks `(:my::indicator 1.95)`. The expansion chain has
three coordinates:

| Coord | WatAST shape | from-watast → HolonAST | Encoding flavor |
|----|----|----|----|
| 0 (call) | `(:my::indicator 1.95)` | `Bind(Atom("my::indicator"), F64(1.95))` | Quasi-orthogonal at the F64 leaf |
| 1 (post-β) | `(:wat::holon::Bind (Atom "indicator") (Thermometer 1.95 -100 100))` | `Bind(Atom("indicator"), Thermometer{1.95,-100,100})` | Locality-preserving at the Thermometer leaf |
| 2 (terminal) | (no WatAST — value HolonAST) | same Bind shape as coord 1 | Locality-preserving |

A walker walks `(:my::indicator 2.05)` independently:

| Coord | from-watast → HolonAST | Coincident with 1.95's coord? |
|----|----|----|
| 0 | `Bind(Atom("my::indicator"), F64(2.05))` | NO — F64(1.95) and F64(2.05) are quasi-orthogonal atoms |
| 1 | `Bind(Atom("indicator"), Thermometer{2.05,-100,100})` | YES — Thermometer locality + Bind cosine-preservation gives `cos ≈ 1 - 2·0.1/200 = 0.999` (well above the d=10000 σ=1 floor of 0.99) |
| 2 | same as coord 1 | YES |

So 2.05's walker misses at coord 0 but hits at coord 1. The cache
short-circuits at the first coincident coordinate; 2.05's walker
returns 1.95's terminal — *the "close enough" answer the
substrate already worked out for the neighborhood*.

That is THE FUZZY HIT (T2). The cache is locality-keyed; the
algebra grid is the agreement; the substrate does the matching.

---

## B — The dual decision: leaf encoding picks the depth

The substrate ships TWO scalar leaf encodings (arc 057):

- **F64** (typed leaf) — each unique f64 value is a distinct
  quasi-orthogonal atom. Two near-equal F64 leaves have cosine
  ≈ 0. Used when you want unique identity per value (e.g., a
  configuration parameter, a pointer, a hash).
- **Thermometer** (algebra primitive) — values along a `[min,max]`
  range encoded as a gradient. Two near-equal Thermometer values
  have cosine ≈ 1 − 2·|Δ|/range. Used when you want similar
  values to be similar coordinates.

The two encodings give consumers a knob: insert F64 or Thermometer
at the leaves, depending on what kind of similarity matters at
that point in the form.

In this proof's `:my::indicator`, the call site uses raw f64 (so
the call-form coord is F64-leaf orthogonal); the body wraps in
Thermometer (so the post-β coord is locality-preserving). That
asymmetry makes the holographic-depth shape work *because* the
substrate's per-leaf encoding choices are different.

This is the dual that the user has been pulling on across many
chapters of the BOOK — every binary representation hides a
continuum (Chapter 57), every "constant" hides a function
(Chapter 58), every leaf hides a choice between identity and
locality (this proof). Same pattern, named again at the
substrate's encoding layer.

---

## C — The cache primitive: linear scan + `coincident?`

`HashMap<HolonAST, V>` is exact equality (arc 057 + arc 058).
For fuzzy lookup we need linear scan with the substrate's
predicate:

```scheme
(define cache-lookup-fuzzy(cache, query):
  foldl entries :None (lambda acc entry:
    match acc:
      Some _ → acc
      :None  → if coincident?(query, entry.form-key)
                  then Some(entry.terminal)
                  else :None))
```

O(N) per lookup. The trade vs. byte-keyed HashMap is exactly
what buys locality. For production scale, a future arc could
combine SimHash bucketing (BOOK Chapter 55) with this fuzzy
predicate to amortize lookup cost. v1 demonstrates the
substrate's coincident? as the matcher; doesn't optimize.

The walker is identical in shape to proof 016 v4 except for the
single line where lookup is fuzzy instead of byte-exact:

```scheme
((cached :Option<wat::holon::HolonAST>)
 (:exp::cache-lookup-fuzzy cache form-key))   ;; v5: fuzzy
;; vs proof 016:
;;  (:wat::core::get cache.terminal form-key)  ;; v4: exact
```

One-line change at the consumer; the substrate's `coincident?`
does all the new work.

---

## D — The six tests

| # | Test | What it demonstrates |
|---|------|----------------------|
| T1 | `(:my::indicator 1.95)` reaches expected post-β terminal | Sanity: chain bottoms out at `Bind(Atom("indicator"), Thermometer{1.95,-100,100})`. |
| T2 | **THE FUZZY HIT** | A walks 1.95 first; cache fills. B walks 2.05; B's terminal IS coincident with A's expected (1.95-flavored) terminal — *not* B's own 2.05-flavored one, because B never computed it. The cache wins via algebra-grid identity. |
| T3 | distant value 8.5 misses fuzzy | `\|Δ\|=6.55 / R=200 = 3.3% > 0.5% tolerance`. Not coincident. C fires its own chain; C's terminal is the 8.5-flavored Bind, NOT A's 1.95 one. Locality is bounded. |
| T4 | post-β coords ARE coincident (direct) | Build the two post-β HolonASTs by hand; assert `coincident?` returns true. The substrate-level claim the cache rides on. |
| T5 | **pre-β coords are NOT coincident** | The holographic-depth claim, made load-bearing. Pre-β HolonASTs (with F64 leaves) at 1.95 vs 2.05 are quasi-orthogonal; `coincident?` returns false. Fuzziness emerges DEEPER, not at the surface. |
| T6 | N walkers populating neighborhoods | Three walkers at 3.0/6.0/9.0 populate. Walker at 3.05 HITS 3.0's entry. Walker at 5.0 MISSES both 3.0 and 6.0 (between, outside both neighborhoods). Locality forms NEIGHBORHOODS; the cache's effective bucket size is `tolerance/range`. |

T2 + T5 together are the proof's load-bearing pair. T2 shows the
fuzzy hit happens. T5 shows it happens *only at the right depth*.

---

## E — Numbers

- **6 tests passing**, 0 failing, **all green first iteration**.
- **Total runtime**: 35ms; per-test 3-8ms. T6's three-walker
  population takes 8ms (three full chains + two queries).
- **Same chassis as proof 016 v4** — eval-step! driver + walker;
  the only architectural change is the cache's lookup primitive
  (linear scan + `coincident?` instead of HashMap exact get).

---

## F — Composition with prior arcs and proofs

- **Arc 023 (`coincident?`):** the algebra-grid identity predicate
  used as the cache-lookup matcher.
- **Arc 057 (typed HolonAST leaves):** F64 leaf vs Thermometer
  leaf is the structural difference that picks fuzzy depth.
- **Arc 058 (HashMap polymorphism):** unchanged here — we deliberately
  bypass HashMap for the fuzzy case. v4's exact-equality cache used
  arc 058; v5 swaps in a Vec for the fuzzy case.
- **Arc 068 (`eval-step!`):** the same stepping primitive as v4.
  Phase 3 added holon-constructor step rules; this proof exercises
  them at every walk.
- **Proof 016 v4 (the dual-LRU coordinate cache):** the chassis
  this proof modifies. v4 demonstrates exact identity at every
  coordinate. v5 demonstrates fuzzy identity at fuzzy-eligible
  coordinates.

---

## G — Honest scope

This proof confirms:
- A locality-keyed coordinate cache built on `coincident?` works
  on real wat forms walked via arc 068.
- The holographic-depth claim is real: pre-β F64 leaves miss
  fuzzy lookup; post-β Thermometer leaves hit. The walker doesn't
  need to know which depth has the fuzz — it tries fuzzy lookup
  at every level and short-circuits on the first hit.
- Locality is BOUNDED: distant values don't pull from each other's
  neighborhoods. Locality forms neighborhoods of size
  `tolerance·range`.
- N walkers populating distinct values build distinct
  neighborhoods; in-neighborhood queries hit, between-neighborhood
  queries fall through to fresh computation.

This proof does NOT confirm:
- **Sub-linear lookup at scale.** O(N) per lookup. For 1M entries
  that's prohibitive. SimHash bucketing (BOOK Chapter 55) would
  combine cleanly with `coincident?` to make the lookup O(1)
  average — out of scope here.
- **Locality across complex algebraic structures.** This proof's
  forms have ONE Thermometer leaf at depth 1. A form with Bundles
  of many Thermometers, or Permuted nested structures, may have
  different locality behavior at deeper compositions. Future
  proofs may sweep that surface.
- **σ-tuned tolerance per use case.** Tolerance comes from
  `coincident_floor = σ/√d`. At d=10000, σ=1, that's 0.01 (so
  cosine > 0.99). The trading lab may want tighter or looser; the
  substrate exposes a `coincident_sigma_fn` per arc 024. Not
  exercised here.
- **Multi-thread fuzzy walker cooperation.** Same constraint as
  v4 — the cache supports it (zero-Mutex), the test doesn't
  exercise threading.

---

## H — The thread

- BOOK Chapter 55 — *The Bridge* — names the two oracles AND
  names SimHash as the cache-key for fuzzy match. This proof is
  the SimHash-less first-cut of that idea.
- BOOK Chapter 57 — *The Continuum* — every binary hides a
  continuum. Same shape: every leaf hides a choice between
  identity and locality.
- BOOK Chapter 59 — *42 IS an AST* — names the dual-LRU
  coordinate cache. This proof keys the cache by coincidence
  instead of structural identity.
- BOOK Chapter 65 — *The Hologram of a Form* — names the
  property: every step is a coordinate, the terminal is an axiom.
  This proof adds that *some* of those coordinates are
  fuzzy-eligible neighborhoods, not points.
- Arc 023 — `coincident?`.
- Arc 057 — typed leaves (F64 quasi-orthogonal vs Thermometer
  locality).
- Arc 068 — `eval-step!`.
- **Proof 016 v4** — the exact-identity coordinate cache.
- **Proof 017 (this)** — the locality-keyed coordinate cache.

---

## I — What this means for the trading lab

The user's running framing for the lab: indicator rhythms,
candle-window evaluators, regime classifications — all become
forms where the *exact* numeric values don't matter, only the
*neighborhood* of values matter for the decision boundary. RSI
0.71 and 0.75 should produce the same trade signal; the cache
should help two thinkers asking that question once, not twice.

Proof 017 is what makes that work:

1. Express the indicator as a wat form whose scalar arg is wrapped
   in Thermometer (not F64) at the appropriate depth.
2. Walk via `:wat::eval-step!`; record terminals via `coincident?`
   lookup.
3. Two thinkers landing in the same neighborhood share the
   already-computed answer.
4. Locality is bounded; distant queries get their own fresh
   computation; the neighborhood structure emerges naturally
   from the substrate's encoding choices.

**No bucketing scheme. No quantization. No Mutex. The substrate's
`coincident?` IS the bucketing — and it's the same predicate the
algebra grid uses for "same point" everywhere else in the system.**

PERSEVERARE.
