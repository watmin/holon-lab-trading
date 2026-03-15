# Holon Context: What the Literature Gets Wrong

> **If you are confused about how Holon works, read this file before anything else.**
> Then read the primers in `../algebraic-intelligence.dev/src/content/docs/blog/primers/`.
> The common VSA/HDC literature is deficient in specific ways that matter for implementation.
> Holon has solved several problems the field hasn't published solutions to.

---

## The Canonical Source

The definitive documentation lives at:

```
../algebraic-intelligence.dev/src/content/docs/blog/primers/
  series-001-000-vsa-primer.md        ← VSA/HDC introduction (what Holon builds on)
  series-001-001-atoms-and-vectors.md ← encoding stack: scalars, binding, bundling
  series-001-002-holon-ops.md         ← full algebra op reference
  series-001-003-memory.md            ← subspaces, engrams, EngramLibrary

../algebraic-intelligence.dev/src/content/docs/blog/story/
  series-003-005-engrams.md           ← how engrams were discovered (765ms → 3ms)
  series-005-001-the-spectral-firewall.md ← four-layer architecture, field attribution
  series-005-002-self-calibrating.md  ← self-calibrating thresholds (no magic numbers)
  series-005-003-the-residual-profile.md  ← striped encoding, attribution correctness
```

---

## Holon Is MAP VSA, Not BSC or HRR

Holon uses **MAP (Multiply Add Permute)** — bipolar vectors `{-1, 0, 1}`, element-wise
multiplication for binding, element-wise addition for bundling.

- **Bind** = element-wise multiply. Self-inverse: `bind(bind(A, B), A) ≈ B`.
- **Bundle** = element-wise majority vote (add, then sign).
- **Query/probe/search** = cosine similarity. One operation, three interpretations.

Do NOT confuse with BSC (XOR binding) or HRR (circular convolution). They have different
properties. MAP's self-inverse binding is what makes `unbind` and field attribution possible.

---

## The Hash-Function Codebook (Not In Literature)

Standard VSA requires a **pre-shared codebook** — atom vectors assigned once, distributed
to every node. Holon eliminates this entirely.

Atom vectors are derived deterministically from a hash function:
```
SHA-256(atom_string) XOR seed → RNG seed → bipolar vector
```

Same atom, same seed, same language implementation = identical vector, always, anywhere,
without coordination. The hash function IS the codebook. Nothing to distribute, version,
or sync.

**Implication for this lab:** Every encoded vector in holon-lab-trading lives in the same
vector space as every engram in the library. Load an engram minted on another machine,
same seed → same space → scoring works immediately.

**Constraint:** Different language runtimes produce different vectors (different RNGs).
Stay in Python (or Rust, or one language) per deployment. Don't mix.

---

## Scalar Encoding: Three Paths, Not One

String atomization is NOT the only path. Choosing the wrong path corrupts the geometry.

| Marker | Use for | Why |
|--------|---------|-----|
| String atom (default) | Categorical: port 80, protocol "TCP", IP as identifier | No proximity implied — "80" and "81" should be as different as "80" and "banana" |
| `LinearScale(value)` | Additive quantities: MACD, RSI, SMA cross | Equal absolute differences → equal similarity drop |
| `LogScale(value)` | Multiplicative quantities: price, volume, ATR | Equal ratios → equal similarity drop (10→100 same as 100→1000) |
| `TimeScale(ts)` | Timestamps | Circular decomposition: Monday 9am ≈ Tuesday 9am |

**For trading:** prices and ATR → `LogScale`. Indicator differences (MACD, SMA cross) →
`LinearScale`. Hour-of-day, day-of-week → `LinearScale` on sin/cos of the angle (already
decomposed). Volume regime ratio → `LogScale` (it's multiplicative).

Encoding a price as a string atom loses all ordering. Encoding a protocol name with
`LinearScale` implies TCP and UDP are numerically adjacent. Both are wrong.

---

## What `encode_walkable` Actually Does

`HolonClient.encode_walkable(data)` traverses the data structure and applies the full
atomize → bind → bundle stack:

1. Walk the dict: each key is a role atom, each value gets the appropriate scalar encoding.
2. Bind each key-value pair: `bind(role_vec, value_vec)`.
3. Bundle all bound pairs into one document vector.

A `LinearScale(x)` wrapper tells the encoder to use linear scalar encoding for that value
instead of string atomization. Same for `LogScale`. Pass a plain Python `list` and it
uses positional encoding (order matters). Pass a list of `LinearScale` items and each
element is magnitude-encoded before positional binding.

**Key property:** `{"sma_short": LinearScale(45000.0)}` and `{"sma_short": LinearScale(45100.0)}`
produce vectors with high cosine similarity. `{"sma_short": "45000"}` and
`{"sma_short": "45100"}` are as different as `{"sma_short": "banana"}`. Use the wrappers.

---

## Role-Filler Binding Is Non-Negotiable

Without binding, structural information is destroyed:
- `{"dst_port": 80}` and `{"src_port": 80}` look identical (same atom "80" in the bundle).
- With binding: `bind(role("dst_port"), atom("80"))` ≠ `bind(role("src_port"), atom("80"))`.

The DDoS lab measured this directly: naive atom bundling (no binding) → F1=0.368.
With role-filler binding → F1=1.000. **This is not a subtle difference.**

`encode_walkable` handles binding automatically. If you're manually constructing vectors
with `bundle([atom(v) for v in values])` without binding, you're doing it wrong.

---

## OnlineSubspace: Score First, Update Second

CCIPCA online PCA. Updates one vector at a time, O(k×dim) cost.

**Critical bug to avoid:** Do NOT score a vector after updating the subspace with that
same vector. The vector partially explains itself → artificially low residual → threshold
calibrates wrong → 100% false positive rate at test time.

The correct order, always:
```python
residual = subspace.residual(vec)   # 1. score with pre-update state
subspace.update(vec)                 # 2. then update
is_anomalous = residual > subspace.threshold
```

`subspace.update(vec)` returns the residual computed before the update — use that return
value if you want to score and update in one call.

---

## What `threshold` Is (Self-Calibrating)

`subspace.threshold` is NOT a fixed constant. It is:
```
running_mean(residuals) + sigma_mult × running_stddev(residuals)
```

It tracks the stream. If the stream gets noisier, the threshold rises. `sigma_mult`
(default 3.5) controls sensitivity. This is the self-calibrating property — no magic
numbers to tune per dataset.

**Implication:** Warm the subspace up on representative data before using `threshold`
for decisions. Until the subspace has seen enough samples to estimate the residual
distribution, the threshold is unstable. Typical: 50–200 samples to stabilize.

---

## Engrams Are Not Prototypes

Standard HDC memory systems store **class prototypes** — a single representative vector
per class. Holon engrams store a **learned subspace** — the k-dimensional manifold that
a stream of vectors occupies.

| | Prototype | Engram |
|---|---|---|
| What is stored | One centroid vector | k principal components + mean + threshold state |
| Matching | Cosine similarity to centroid | Reconstruction residual against manifold |
| Why better | — | Catches non-radial anomalies that are close to the centroid but off-manifold |
| Field attribution | Not possible | `anomalous_component` → unbind with role vectors |

A prototype can miss a "centroid chimera" — a vector that averages to be close to the
centroid but has wrong field combinations. The subspace catches it because the off-manifold
direction is what matters, not distance from center.

---

## Two-Tier Matching in EngramLibrary

`library.match(vec, top_k=3)` runs a two-tier filter:

**Tier 1 — Eigenvalue pre-filter** (cheap, O(k×n)):
Rank engrams by eigenvalue energy. Higher energy = broader pattern = plausible candidate.
Returns top `prefilter_k` (default 10).

**Tier 2 — Full residual scoring** (expensive, O(k×dim) per candidate):
Compute reconstruction residual against stored subspace. Return top-k sorted ascending.

Lower residual = better match. A residual near zero means the probe vector lies on the
engram's learned manifold. High residual = no match.

If your library has fewer engrams than `prefilter_k`, tier 1 is skipped.

---

## The Anomalous Component and Field Attribution

```python
anomalous = subspace.anomalous_component(vec)  # vec - reconstruct(vec)
```

This is a full-dimensional vector (not a scalar). Because encoding uses role-filler
binding, you can unbind it to find which fields drove the anomaly:

```python
role_vec = client.get_vector("macd_hist")
unbound = client.unbind(anomalous, role_vec)
surprise = np.linalg.norm(unbound)   # higher = more anomalous in this field
```

High norm → that field contributed significantly to the out-of-manifold direction.
This is algebraic explainability: no separate explainer, no approximation, no SHAP.
The explanation is in the geometry because the encoding was built from reversible operations.

This is what `FeatureDarwinism` uses. The `surprise_profile` in an `Engram` is this
dict, pre-computed at mint time.

---

## Magnitude + Direction: Always Use Both

From batch 018 (spectral firewall experiments):

| Signal alone | Known attack min | Unknown attack max | Gap |
|---|---|---|---|
| Spectrum (eigenvalue shape) | 0.936 | 0.944 | −0.008 (**wrong direction**) |
| Alignment (subspace direction) | 0.338 | 0.276 | +0.062 |
| Combined | 0.321 | 0.262 | **+0.059** (100% accuracy) |

Eigenvalue spectrum alone can rank unknown attacks *higher* than known ones.
Direction alone works but costs more. Combined = 100% accuracy at 75% compute savings.

`library.match()` uses residual (direction-aware). `library.match_spectrum()` uses
eigenvalue shape. For the highest confidence matching, use both.

---

## NaN Residuals → Deny, Never Permit

If the subspace hasn't converged yet (too few samples) or the encoding produces a
degenerate vector, `residual()` can return NaN.

**Default to deny.** If you can't compute a score, the request/signal does not pass.
Treating NaN as "low residual" (permit) opens an attack surface. Found this the hard
way in the spectral firewall: NaN → RateLimit was wrong; NaN → Deny is correct.

---

## Feature Weighting: Scale the Scalar, Don't Filter the Vector

To weight a field's contribution to the encoding, **scale the scalar value before
encoding**, not after. Multiplying `LinearScale(value * weight)` is the correct approach.

Do NOT try to scale the final vector components — the geometry doesn't work that way.
Do NOT try to zero out dimensions after encoding — that's not how superposition works.

A weight of 0.0 effectively removes a field (contributes near-zero energy to the bundle).
A weight of 2.0 doubles the field's scalar influence on the encoding.

---

## Dimension Selection

Kanerva recommends ≥10,000 for comfortable orthogonality guarantees. Holon experiments
validated 4,096 for simpler structured data (fewer fields, bounded vocabularies).

For the trading domain (~15 indicator fields, numeric values):
- **4,096** is the right starting point. Fast, small memory footprint.
- Go to 16,384 if you see cosine similarity collisions between unrelated market states.

The knee in k (subspace components) is found empirically:
- Plot residual CV vs k.
- The point where adding more k stops reducing residual is the right k.
- For structured data with ~15 fields: k=32 is typically the knee.

---

## Bipolar Cosine Is Not 1.0 for Identical Vectors

MAP bipolar vectors live in `{-1, 0, 1}^D`. Because zeros contribute 0 to the dot product
but 0² = 0 still in the L2 norm, `dot(v, v) / norm(v)² < 1` whenever the vector has zeros.

```
v = [1, -1, 0, 1, ...]
dot(v, v) = count of non-zero elements   ← not D
norm(v)²  = count of non-zero elements   ← same! so cosine IS 1...
```

Actually it IS 1.0 mathematically. The issue in practice: `encode_walkable` bundles
multiple bound vectors, and the result is a *majority-vote bundle*, not a single atom.
After bundling, the components partially cancel and the resulting vector is **not a unit
vector in the ±1 sense**. So cosine(v, v) still equals 1.0 mathematically — but
`dot(v, v) / (norm(v) * norm(v))` in floating point may differ from 1.0 due to the
int8 representation.

**Practical rule:** Do not assert `cosine == 1.0` for identical hypervectors.
Instead assert `np.array_equal(v1, v2)` for exact identity. Use cosine only for
*relative* comparison between different vectors (which is higher/lower), not as an
absolute similarity score.

---

## What This Lab Proves

The holon Python library (no modifications) can encode OHLCV market data into a
geometrically meaningful vector space, learn market-regime manifolds via `OnlineSubspace`,
mint persistent pattern memories via `EngramLibrary`, and autonomously refine them
through a 2-phase feedback loop.

If something seems hard to do with the public API, the answer is almost certainly in
the primers. The library is more capable than it first appears. The primitives compose.
