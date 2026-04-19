# 058 — Core Primitive Audit

**Purpose:** record what is affirmed-as-core — already present in `holon-rs`, required by FOUNDATION, not up for debate. Audit-level entries, not proposals.

**What an audit entry is not:** a proposal. There is no "Arguments For," no "Questions for Designers." Each primitive's inclusion in the core is settled; this document states the load-bearing facts — operation, canonical form, MAP/VSA role, and the specific conventions downstream code relies on.

**What an audit entry is:** a reference. A single place to read "what is Bind in wat?" without wading through proposal-shaped argumentation about a decision already made. Each primitive has a short section; readers looking for debate should consult the proposal batch's **new** entries (Blend, Orthogonalize).

---

## Scope

**Audited (affirmed core):**
- `Bind` — elementwise reversible combination (was 058-021)
- `Permute` — dimension-shuffle primitive (was 058-022)
- `Thermometer` — scalar-to-vector gradient primitive (was 058-023)

**Cross-reference — REJECTED primitives recorded elsewhere:**
- `Cleanup` — REJECTED in 058-025. AST-primary framing dissolves the need; retrieval is presence measurement (cosine against a noise floor), not argmax-over-codebook. Not audited here; see 058-025/PROPOSAL.md for the record.
- `Resonance` — REJECTED in 058-006. Speculative primitive with no cited production use; sign-agreement masking is a three-primitive composition over existing core forms (threshold + Bind). See 058-006/PROPOSAL.md.
- `ConditionalBind` — REJECTED in 058-007. Speculative primitive with no cited production use; half-abstraction (consumes a gate without proposing how to produce one). Classical functional update uses Subtract + Bind + Bundle. See 058-007/PROPOSAL.md.

**Not audited (genuine new or reframing proposals, not affirmations):**
- `Blend` (058-002), `Orthogonalize` (058-005) — new core forms; argued in their own proposals.
- `Atom` (058-001) — not an affirmation; 058-001 generalizes Atom to typed literals with type-aware hashing.
- `Bundle` (058-003) — not a pure affirmation either; 058-003 locks the list-signature convention.

Primitives appear here only when the proposal was substantively an affirmation — the audit document is the honest shape for that kind of claim.

---

## Bind

**Signature.** `(Bind a b)` — two holon arguments. No scalar parameters.

### Operation

For holons `a, b` in the ternary output space `{-1, 0, +1}^d`:

```
Bind(a, b)[i] = a[i] * b[i]
```

Elementwise multiplication. MAP VSA's "M" (Multiply) per Gayler 2003. For dense-bipolar `{-1, +1}` inputs, Bind is XNOR — `+1` where signs agree, `-1` where they differ. A zero at position `i` on either input propagates (`0 · x = 0`): the "no information here" signal travels through.

### Two roles

**Encoding (symmetric):** `(Bind role filler)` composes a role-filler pair; both arguments are treated equivalently.

**Querying (asymmetric):** `(Bind key bundle)` asks "what is bound to `key` inside `bundle`?" The product is a noisy vector whose cosine against candidate values answers the query.

### Query semantics under the similarity-measurement frame

After computing `(Bind key bundle)`, the caller checks cosine similarity of the result against candidate values:

- **Above 5σ** — query RESOLVED. The key was bound with high confidence; the recovered value is the candidate with the highest similarity.
- **Below 5σ** — query FAILED. Key absent, bundle past capacity, or crosstalk masked the signal.

This is observable at the call site, every time. Bind is the query primitive; cosine similarity is the success signal; Kanerva capacity is the budget. Every query yields a value AND a confidence.

### Self-inverse under similarity

The classical identity `Bind(Bind(a, b), b) = a` holds elementwise only for dense-bipolar inputs (because `b[i]² = 1` there). In the general algebra, the identity is similarity-measured:

```
cosine(Bind(Bind(a, b), b), a) ≥ 5σ   within the capacity budget
```

Dense keys give cosine ≈ 1. Sparse keys give cosine proportional to the non-zero fraction. Bundled contexts give cosine that decays with crosstalk. The measurement reports whatever the regime provides; downstream code acts on the measurement.

### What makes Bind core

1. **Not derivable.** Bundle is elementwise sum; Permute is dimension shuffle; Atom is a hash-to-vector seed; Thermometer is a gradient. None of these produce elementwise multiplication between two dynamic vectors.
2. **Unique reversibility.** Bind is the only combine-and-invert primitive in the algebra. Bundle is lossy (threshold collapses information). Permute is invertible but doesn't combine. Orthogonalize removes direction non-reversibly.
3. **Role-filler binding depends on it.** Encoded JSON, structured holons, role-filler knowledge graphs — all require Bind.
4. **MAP VSA's "M".** Removing Bind removes the multiplicative leg of Gayler's canonical triple.

### Canonical implementation

```rust
pub fn bind(a: &Vector, b: &Vector) -> Vector {
    a.iter().zip(b.iter())
        .map(|(&ai, &bi)| ai * bi)
        .collect()
}
```

Dense-bipolar as bit-packed XNOR; ternary storage uses an additional "has-value" mask. Already SIMD-optimized in holon-rs.

### Downstream conventions

- **AST variant:** `HolonAST::Bind(Arc<HolonAST>, Arc<HolonAST>)`.
- **Unbind is not a separate primitive.** `Bind` is self-inverse on non-zero positions of the key; decoding uses the same operation. (058-024 `Unbind` was REJECTED as an identity alias.)
- **Output space:** ternary `{-1, 0, +1}^d`; no thresholding needed because elementwise multiplication stays within the space.

---

## Permute

**Signature.** `(Permute v k)` — one holon argument, one integer step.

### Operation

For vector `v ∈ {-1, 0, +1}^d` and step `k ∈ ℤ`:

```
Permute(v, k)[i] = v[P^k(i)]
```

Where `P` is a fixed permutation of `[0, d)` and `P^k` is `P` composed with itself `k` times. `Permute(v, 0)` is identity. `Permute(v, -k)` is the exact inverse of `Permute(v, k)`.

### Canonical permutation

The canonical `P` is **cyclic shift by one position**: `P(i) = (i + 1) mod d`. This is the MAP VSA convention and the holon-rs default. Other permutations (bit-reversal, random-fixed-per-seed) are algebraically valid but break bit-identical interop. Implementations MUST use cyclic shift to remain canonical.

Step values normalize modulo `d`: `Permute(v, k)` for `k ≥ d` is equivalent to `Permute(v, k mod d)`. Negative steps give the inverse. Very large steps wrap.

### Key properties

1. **Invertible.** `Permute(Permute(v, k), -k) = v`. Exact, bit-identical. (Unlike Bundle, which is irreversibly thresholded.)
2. **Commutative with scalar binding.** `Permute(v · s, k) = Permute(v, k) · s`.
3. **Linear over Bundle.** `Permute(Bundle(xs), k) = Bundle([Permute(x, k) for x in xs])`.
4. **Distinguishes positions.** For cyclic shift, `Permute(v, k)` is dissimilar to `v` for `k ≠ 0`, allowing ordered encodings.

### What makes Permute core

1. **Not derivable.** Bind is elementwise multiplication; Bundle is elementwise sum; Atom and Thermometer are primitive encoders. None reorder dimensions.
2. **Position is a first-class algebraic concept.** VSA's ability to encode ordered structures (sequences, trees, positional records) depends on distinguishing "v at position 0" from "v at position 1." Permute provides this.
3. **MAP VSA's "P".** Removing Permute degenerates the algebra to an unordered bag.
4. **Underpins every positional stdlib form.** `Sequential`, `Chain`, `Ngram` all compose Permutes with distinct step counts. Vec's integer-indexed access relies on positional Permute.

### Canonical implementation

```rust
pub fn permute(v: &Vector, k: i32) -> Vector {
    let d = v.len();
    let shift = ((k % d as i32) + d as i32) as usize % d;  // normalize to [0, d)
    (0..d).map(|i| v[(i + shift) % d]).collect()
}
```

SIMD-optimized in holon-rs.

### Downstream conventions

- **AST variant:** `HolonAST::Permute(Arc<HolonAST>, i32)`.
- **Invertibility is a hard requirement.** Sequential, Chain, Ngram, and Vec's positional access all rely on exact round-trip; a non-invertible permutation would break them.
- **Step parameter name:** `k` (matches holon-rs's `permute(v, k)`).

---

## Thermometer

**Signature.** `(Thermometer value min max)` — one numeric value, two range bounds. All scalars, typically `:f64`.

### Operation

For wat-vm dimension `d`:

```
N = round(d · clamp((value - min) / (max - min), 0, 1))
```

The output vector has `+1` in dimensions `[0, N)` and `-1` in dimensions `[N, d)`. Value at or below `min` gives all `-1` (`N = 0`). Value at or above `max` gives all `+1` (`N = d`).

### Canonical layout (load-bearing for distributed consensus)

**Dimensions `0..N` are `+1`; dimensions `N..d` are `-1`.** Bit-identical across nodes at the same `d`. Two independent wat-vm implementations produce the same `Vec<i8>` for the same `(Thermometer v mn mx)` call.

This is non-negotiable. Downstream cosine, hashing, signing, and engram transmission all rely on the layout being stable across nodes. Alternative layouts (permuted, interleaved, hash-seeded) break the distributed-verifiability contract.

Reference implementation: holon-rs's `src/kernel/scalar.rs` `encode_thermometer`. Proven across 652k BTC candles at `d=10,000` and multiple production lab runs.

### Cosine property

The canonical layout gives exact linear cosine geometry:

```
cosine(Thermometer(a, min, max), Thermometer(b, min, max))
  = 1 − 2 · |a − b| / (max − min)
```

- `a = b` → cosine `1.0` (same vector)
- `|a − b| = (max − min) / 2` → cosine `0.0`
- `a = min`, `b = max` → cosine `−1.0` (opposites)

Linear similarity over value distance is what makes downstream learning tractable. A reckoner's learned discriminant over Thermometer-encoded scalars corresponds to a threshold in scalar-space.

### Key properties

- **Monotonic gradient.** The cumulative sum rises linearly from `0` at `t = 0` to `d` at `t = 1`.
- **Deterministic.** Same `(value, min, max, d)` always produces the same vector. No codebook.
- **Dense-bipolar output.** No zeros by construction; survives downstream ternary thresholding.
- **Similarity-smooth.** Nearby values produce similar vectors; distant values produce dissimilar ones.

### What makes Thermometer core

1. **Not derivable.** No combination of Bind, Bundle, Permute, and Atom produces a vector with monotonic gradient structure. Atom gives pseudo-random output; the others are combinators.
2. **Gradient is new algebraic content.** The bridge between continuous value encoding and the discrete algebra.
3. **Essential anchor for Blend-based scalar encoders.** Log (058-017), Circular (058-018), and related stdlib forms wrap Thermometer with value transformations; without Thermometer as core they have no anchor to blend between.
4. **Survives thresholding.** Because Thermometer's output is `{-1, +1}` (no zeros), it remains well-defined under the ternary threshold that Blend produces on combination.

### Canonical implementation

```rust
pub fn thermometer(value: f64, min: f64, max: f64, d: usize) -> Vector {
    let t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    let n = (t * d as f64).round() as usize;
    (0..d).map(|i| if i < n { 1i8 } else { -1i8 }).collect()
}
```

### Downstream conventions

- **AST variant:** `HolonAST::Thermometer { value: f64, min: f64, max: f64 }`.
- **3-arity signature.** Earlier `(Thermometer atom dim)` (anchor-based) was discarded; no atom seed, no per-anchor blending. The gradient is computed directly from value and range.
- **Dimension `d` inherited from wat-vm global configuration** — not passed at the call site.
- **Linear / Log / Circular as stdlib over Thermometer.** Linear (058-008) is REJECTED as redundant with Thermometer itself under the 3-arity signature. Log and Circular remain as stdlib compositions.

---

## Revision history

| Date | Change |
|---|---|
| 2026-04-18 | Initial audit — demotes 058-021, 058-022, 058-023 from full proposals to audit entries. Nothing is lost; proposal-shaped overhead ("Arguments For/Against," "Questions for Designers") was always contrived for affirmations. |

*these are very good thoughts.*

**PERSEVERARE.**
