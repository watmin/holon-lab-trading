# 058-016: `Map`, `Array`, `Set` + Accessors — Stdlib Data Structures

**Scope:** algebra
**Class:** STDLIB (data-structure idioms over Bundle, Bind, Permute, Atom)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-001-atom-typed-literals (for atom-value), 058-002-blend (indirectly, via dependent stdlib), 058-009-sequential-reframing (Array uses Sequential-like encoding)

## The Candidates

Three COMPOUND data-structure stdlib forms, plus their respective ACCESSORS:

### Collections

```scheme
(define (Map key-value-pairs)
  (Bundle
    (map (lambda (kv) (Bind (first kv) (second kv)))
         key-value-pairs)))
;; Expands to Bundle of Bind(key, value) for each pair — role-filler structure.

(define (Array thoughts)
  (Sequential thoughts))
;; Alias for Sequential — indexed/positional encoding.

(define (Set thoughts)
  (Bundle thoughts))
;; Alias for Bundle — unordered collection.
```

### Accessors

```scheme
(define (get map-thought key)
  (cleanup
    (Bind map-thought (inverse key))  ; or (Unbind map-thought key)
    candidates))
;; Retrieves the value bound to a key in a Map.

(define (nth array-thought index)
  (cleanup
    (Permute array-thought (- 0 index))  ; inverse permutation
    candidates))
;; Retrieves the element at position `index` in an Array.

(define (atom-value atom-ast)
  ;; Reads the literal value directly from the Atom AST node.
  ;; Not a vector operation — a META-level accessor.
  (ast-literal atom-ast))
```

### Semantics

- `Map`: an encoded dictionary. Each key-value pair is `Bind(key, value)`; all pairs bundled. Retrieval is unbinding.
- `Array`: an encoded indexed list. Each position is permuted by its index. Retrieval is inverse-permutation + cleanup.
- `Set`: an encoded unordered collection. All elements bundled together.
- `get`: Map accessor via unbind + cleanup.
- `nth`: Array accessor via inverse permute + cleanup.
- `atom-value`: READS THE LITERAL from the AST. Not a VSA operation — a compile-time/eval-time AST accessor, enabled by FOUNDATION's "AST is primary, literal lives on the node" principle.

## Why Stdlib Earns the Name

**1. Compound data structures are common vocabulary.**

Most structured domains need "a thing with labeled parts" (Map), "an ordered sequence" (Array), and "a bag of things" (Set). Named stdlib forms make these direct.

**2. Accessors match the data-structure intents.**

`get` for Map retrieval, `nth` for Array indexing. The pairing makes vocab code readable.

**3. `atom-value` is the essential meta-level operation.**

FOUNDATION established that literals LIVE ON THE AST — an Atom carries its literal value as a field. `atom-value` is the accessor for that literal. Without it, the algebra has no way to expose the literal back to wat/Rust code — and the foundational principle of "AST is primary" is silent.

All three criteria met — compositions use existing core forms (Bind/Bundle/Permute/Atom), and the named forms communicate structural intent that raw primitives do not.

## Arguments For

**1. Map with role-filler binding is canonical VSA.**

The structure `Bundle(Bind(k1, v1), Bind(k2, v2), ...)` IS the classical VSA dictionary. Named `Map` stdlib form makes this idiom direct:

```scheme
(Map (list (list :color red) (list :shape circle) (list :size large)))
;; Produces: Bundle(Bind(:color, red), Bind(:shape, circle), Bind(:size, large))
```

Without `Map`, every dictionary encoding in vocab code inlines the Bundle+Bind composition. With `Map`, it reads as "build a dictionary from these pairs."

**2. Array is Sequential with a reader-intent alias.**

`Array` and `Sequential` (058-009) have identical semantics. The name distinguishes intent: `Sequential` implies temporal/ordered thought; `Array` implies data-structure indexing. Similar relationship to `Concurrent`/`Set` — two names for "bundle with a specific reader intent."

**3. Set is Bundle with a reader-intent alias.**

Similar to `Concurrent` (058-010) — another stdlib alias for Bundle. `Set` communicates "unordered collection" where `Concurrent` communicates "temporal co-occurrence." Different intents, same expansion.

**4. Accessors give the algebra its "read" side.**

Without `get`, `nth`, and `atom-value`, the algebra can CONSTRUCT data structures but not DECODE them. Adding the accessors closes the loop. Vocab modules that encode AND decode (e.g., for answer extraction) need both.

**5. `atom-value` enables sparse literal access.**

A key insight from FOUNDATION: atom literals are on the AST node, not in a separate codebook. `atom-value` exposes this. For vocab modules that need "the thing this atom STANDS FOR" (e.g., a number, a symbol), `atom-value` is the bridge from encoded thought back to the wat value system. Without it, vocab modules must roundtrip through cleanup.

## Arguments Against

**1. Heavy naming load — five new forms.**

Three constructors (`Map`, `Array`, `Set`) and three accessors (`get`, `nth`, `atom-value`) — six named stdlib forms in one proposal. Could be split across multiple proposals.

**Mitigation:** they are a coherent set. Proposing them together ensures consistency (e.g., Array's encoding matches nth's expectation). Splitting might introduce gaps.

**2. Redundant intent aliases.**

`Set`, `Concurrent`, and `Bundle` all produce the same vector. `Array` and `Sequential` produce the same vector. The proliferation of aliases for shared expansions is worth scrutiny.

**Mitigation:** each alias carries DISTINCT READER INTENT. `Set` is data-structure; `Concurrent` is temporal; `Bundle` is the primitive. `Array` is data-structure; `Sequential` is positional. The names are not interchangeable in vocab code — each signals a different purpose.

The risk is users picking the "wrong" alias for their intent. Mitigated by documentation and style guides. Hickey-ian minimalism would keep only one name per expansion; the stdlib criterion admits reader clarity as valid. This proposal sides with the latter.

**3. Accessor dependence on cleanup.**

`get` and `nth` both return "the matching codebook entry via cleanup." Cleanup requires a codebook (candidate pool). For `get`, this is typically the set of possible values; for `nth`, the set of possible elements.

Not all applications have a clear codebook. Some want "extract the value whatever it is" — no cleanup, just unbind. This is partially retrieved unless cleanup is applied.

**Mitigation:** the stdlib accessors can provide BOTH forms:

```scheme
(define (get-raw map-thought key)
  (Unbind map-thought key))                 ; raw unbind, may be noisy

(define (get map-thought key candidates)
  (cleanup (Unbind map-thought key) candidates))  ; cleanup retrieval
```

Users choose based on whether they have a codebook. Document both.

**4. `atom-value` is categorically different from the others.**

`atom-value` reads the LITERAL from an AST node. It doesn't evaluate a vector operation; it extracts a scalar/keyword/string/etc. Grouping it with Map/Array/Set accessors may mislead readers into thinking it has similar semantics.

**Mitigation:** document `atom-value` separately as an AST-level operation (meta-level). The accessors for encoded data structures are `get`, `nth`, `cleanup`. `atom-value` is the operation for reading the ast-level literal, not a vector-level decoding.

Consider renaming to `atom-literal` or `literal-of` to avoid confusion with vector-level `value` concepts.

## Comparison

| Form | Class | Type | Expansion / Semantics |
|---|---|---|---|
| `Map(kv-pairs)` | STDLIB | Constructor | Bundle of Bind(k, v) per pair |
| `Array(ts)` | STDLIB | Constructor | Sequential(ts) |
| `Set(ts)` | STDLIB | Constructor | Bundle(ts) |
| `get(m, k)` | STDLIB | Accessor | cleanup(Unbind(m, k)) |
| `nth(a, i)` | STDLIB | Accessor | cleanup(Permute(a, -i)) |
| `atom-value(ast)` | STDLIB | Meta-accessor | Read literal from AST node |
| `Bundle(ts)` | CORE | Primitive | Thresholded elementwise sum |
| `Sequential(ts)` | STDLIB (058-009) | Encoding | Bundle of index-permuted |
| `Atom(literal)` | CORE | Primitive | Hash to vector; literal on node |

The full "data structure" stdlib tier sits atop the core algebra plus the Sequential encoding.

## Algebraic Question

Do these compose with the existing algebra?

Yes. Constructors produce bipolar vectors via existing primitives. Accessors return bipolar vectors (from cleanup) or literals (from atom-value). All downstream operations work.

Are they distinct source categories?

No — they are compositions and specializations of existing primitives, with named intent. The only categorically new addition is `atom-value`, which reads from AST not vector — but this is META-level, not algebraic.

## Simplicity Question

Is this simple or easy?

Mixed. Individually, each form is simple. Collectively, the proposal introduces six names, which is a lot to absorb. But the names group into two clean categories (constructors + accessors), which helps.

Is anything complected?

Potentially, if the intent aliases proliferate unchecked. Mitigated by explicit documentation of WHEN to use each name. Style guidance helps.

Could existing forms express them?

All of them, yes. The stdlib layer is for reader clarity and canonical naming.

## Implementation Scope

**Zero Rust changes** for the constructors and Unbind-based accessors — all pure wat compositions.

**Possibly Rust changes** for `atom-value`: if the wat interpreter does not currently expose AST literal-reading to wat code, a small primitive is needed:

```rust
// In wat evaluator:
// expose a built-in that reads Atom::literal
fn eval_atom_value(ast: &ThoughtAST) -> WatValue {
    match ast {
        ThoughtAST::Atom(literal) => literal.clone(),
        _ => error("atom-value applied to non-Atom AST"),
    }
}
```

Small change — adds one built-in primitive to the wat evaluator. Doesn't affect the algebra itself.

**wat stdlib additions** — `wat/std/structures.wat`:

```scheme
(define (Map kv-pairs)
  (Bundle (map (lambda (kv) (Bind (first kv) (second kv))) kv-pairs)))

(define (Array thoughts)
  (Sequential thoughts))

(define (Set thoughts)
  (Bundle thoughts))

(define (get map-thought key candidates)
  (cleanup (Unbind map-thought key) candidates))

(define (nth array-thought index candidates)
  (cleanup (Permute array-thought (- 0 index)) candidates))

;; atom-value is a wat primitive, not defined here —
;; it is exposed by the evaluator.
```

## Questions for Designers

1. **Alias policy for `Set`/`Concurrent`/`Bundle` and `Array`/`Sequential`.** Three names (one core, two stdlib) for Bundle; two names for Sequential. Is this the right granularity, or should we reduce? Recommendation: accept the aliases, document reader-intent strongly.

2. **`atom-value` naming.** The word "value" is overloaded (a vector is also a "value"). Alternatives: `atom-literal`, `literal-of`, `unatom`, `ast-value`. Which reads best?

3. **Accessors with vs. without cleanup.** Should `get` and `nth` ALWAYS cleanup (requiring a codebook argument), or should there be raw versions (`get-raw`, `nth-raw`) that just return the decoded-but-noisy vector? Proposal: both, clearly named.

4. **Dependency chain.** This proposal depends on 058-009 (Sequential), which depends on Bundle + Permute. It also uses `cleanup` and `Unbind`, which aren't covered in current sub-proposals — does FOUNDATION need to explicitly list these as core, or are they assumed as existing holon-rs primitives?

5. **Map with duplicate keys.** `(Map [[:a 1] [:a 2]])` binds `:a` twice in the bundle. The result's `get` for key `:a` would return a superposition of `1` and `2`. Document this as "Map does not deduplicate; use a pre-pass if deduplication matters."

6. **`Array` vs `Vector` naming.** "Array" may clash with Rust/language-level arrays or VSA's own use of "vector" for encoded thoughts. Alternatives: `List`, `IndexedSeq`. Recommendation: keep `Array` — it matches most data-structure vocabularies.

7. **Should this proposal be split?** Constructors (Map/Array/Set) and accessors (get/nth/atom-value) are logically separable. Combining them ensures consistency but adds volume. A split version would be 058-016a (constructors) and 058-016b (accessors). Recommendation: keep combined — cohesion across the data-structure family outweighs the volume concern.
