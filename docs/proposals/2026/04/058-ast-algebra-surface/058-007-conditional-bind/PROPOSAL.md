# 058-007: `ConditionalBind` — 3-Argument Gated Binding

**Scope:** algebra
**Class:** ~~CORE~~ **REJECTED**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** conceptually adjacent to 058-006-resonance (both are per-dimension gating; both REJECTED)

---

## REJECTED from 058

**Reason — speculative, no production use.** ConditionalBind appears in the Holon Python library with four mode strings (`"positive"` / `"negative"` / `"nonzero"` / `"strong"`) — the unmistakable fingerprint of exploratory API exploration, not a settled primitive. No cited application in any challenge batch, the DDoS lab, or the trading lab. Its entry in `blog/primers/series-001-002-holon-ops.md` has no "Application:" citation.

**Also, the operation is half an abstraction.** ConditionalBind consumes a gate vector without proposing a gate-production mechanism. "Bind A to B only where context C is active" requires knowing which dimensions encode C — and there is no canonical way to derive that gate from a role atom. The classical VSA way to update a role in a composite is straightforward arithmetic with existing primitives:

```
person_new = Bundle(Subtract(person, Bind(old_age, role_age)),
                    Bind(new_age, role_age))
```

Subtract and Bind, both already in core/stdlib. No ConditionalBind required. No gate-derivation problem.

**Q3 of Round 2 reveals the same structural issue.** The more general primitive is `Select(x, y, gate)` — per-dim choose-between-two — but `Select` isn't proposed either, and a Select-plus-gate-derivation pair would be the honest abstraction. Neither exists; the classical update path doesn't need either.

**If real use emerges later**, propose with concrete motivation: which application needs gated binding, what gate-derivation mechanism accompanies it, and what couldn't be expressed via the classical Subtract+Bind+Bundle pattern. Until then, the algebra stays simpler without it.

The algebra core shrinks to 7 forms: Atom, Bind, Bundle, Blend, Permute, Thermometer, Orthogonalize.

See FOUNDATION-CHANGELOG for the 2026-04-18 rejection record.

---

## Historical content (preserved as audit record)

## The Candidate

A 3-argument core variant that conditionally applies binding based on a per-dimension gate vector:

```scheme
(:wat::algebra::ConditionalBind a b gate)
```

Semantically: at each dimension `i`, if `gate[i]` is "on" (positive), produce `bind(a, b)[i]`; if `gate[i]` is "off" (negative), produce `a[i]` unchanged.

### Operation (per-dimension)

For vectors `a, b, gate` in the algebra's ternary output space `{-1, 0, +1}^d` (typically dense-bipolar; see FOUNDATION's "Output Space" section):

```
ConditionalBind(a, b, gate)[i] = a[i] * b[i]  if gate[i] > 0
                                = a[i]         if gate[i] ≤ 0
```

Intuition: `gate` selects which dimensions of `a` get "modified by" `b` and which pass through unchanged.

### AST shape

```rust
pub enum HolonAST {
    // ... existing variants ...
    ConditionalBind(Arc<HolonAST>, Arc<HolonAST>, Arc<HolonAST>),
}
```

Three holon arguments. No scalar parameters.

## Why This Earns Core Status

**1. Per-dimension control of binding is not expressible in existing core forms.**

`Bind(a, b)` applies unconditionally across all dimensions — every index gets `a[i] * b[i]`. There is no way, in the current algebra, to say "bind `a` and `b` on some dimensions and leave `a` untouched on others."

Blend applies scalar weights uniformly. Orthogonalize computes a single projection coefficient. Resonance (058-006) is a filter, not a selector-for-bind. None of them produce the "bind here, don't bind there" semantics.

**2. It generalizes the role-filler pattern.**

Bind's canonical use is role-filler binding: `bind(role, filler)`. `ConditionalBind(structure, new-filler, role-gate)` says: "modify `structure` by binding in `new-filler` ONLY at the dimensions where the role-gate is positive." This lets you UPDATE a bundled structure at a specific role without decoding and re-encoding.

Without ConditionalBind, updating one role-filler pair in a bundle requires:
1. Decode the bundle (unbind with the role, cleanup)
2. Rebundle without that role
3. Bind the new filler
4. Bundle back

With ConditionalBind, the update is one operation: the gate isolates the relevant dimensions.

**3. It is a primitive of functional update in VSA.**

Distinct from the bind/unbind pair which is the reversible-combination primitive. ConditionalBind is the SELECTIVE-combination primitive. Different semantic role. The two together give the algebra both full and partial structural mutation.

## Operation Semantics in Detail

Example with `d=5`:

```
a    = [+1, -1, +1, -1, +1]
b    = [-1, +1, -1, +1, -1]
gate = [+1, +1, -1, +1, -1]     ; bind on 0, 1, 3; pass-through on 2, 4

bind(a, b) = [-1, -1, -1, -1, -1]

result[0] = bind[0] = -1   (gate on)
result[1] = bind[1] = -1   (gate on)
result[2] = a[2]    = +1   (gate off, pass-through)
result[3] = bind[3] = -1   (gate on)
result[4] = a[4]    = +1   (gate off, pass-through)

result = [-1, -1, +1, -1, +1]
```

## Arguments For

**1. Functional update without full decode.**

A bundle representing `{role1: filler1, role2: filler2, role3: filler3}` stored in a single vector. To change `filler2` without touching the others, a gate vector marks the dimensions corresponding to `role2`'s binding pattern. ConditionalBind modifies only those dimensions.

This is analogous to immutable record updates in functional languages: `(assoc record :role2 new-filler2)`. The gate acts as the "which key to update" selector.

**2. Composes with existing role-filler semantics.**

`Bind(role, filler)` produces a vector whose "signature" is the role. If `gate = Bind(role, any-filler)`, the gate's sign pattern indicates "dimensions modulated by this role." ConditionalBind then targets exactly those dimensions.

**3. One operation, one semantic.**

ConditionalBind is a single conceptual operation: "bind where the gate says so, else pass through." Not a composition of several concerns — it has one coherent role in the algebra.

**4. Implementation is cheap.**

```rust
pub fn conditional_bind(a: &Vector, b: &Vector, gate: &Vector) -> Vector {
    a.iter().zip(b.iter()).zip(gate.iter())
        .map(|((&ai, &bi), &gi)| {
            if gi > 0 { ai * bi } else { ai }
        })
        .collect()
}
```

O(d), three-input scan.

## Arguments Against

**1. Could be expressed via mask-and-combine if Mask exists.**

Given a `Mask(x, selector)` primitive:

```scheme
(:wat::core::define (:wat::std::ConditionalBind a b gate)
  (:wat::algebra::Blend (Mask (:wat::algebra::Bind a b) gate)          ; bound portion (where gate on)
         (Mask a (negate gate))          ; pass-through portion (where gate off)
         1 1))
```

But `Mask` is not currently in the algebra. And this decomposition introduces three operations to express what ConditionalBind does in one. The decomposition reveals the structure but is not simpler.

**2. Ternary gate interpretation.**

If `gate` has zeros (e.g., is the output of `Resonance`), what happens? Convention: `gate[i] > 0` triggers bind, else pass-through. Zero gates pass-through. This must be documented; it is not obvious from the name.

**3. Three-argument forms are visually heavier.**

All other core forms are binary or 4-argument with scalar weights. A 3-arg holon-holon-holon form is new territory. Readers must remember "first two are the bind operands, third is the gate."

**Mitigation:** consistent argument order (operands first, then control) is a learnable convention. The alternative — making it a chained composition — is less readable.

**4. Is this just a specialization too specific to warrant core status?**

ConditionalBind is narrow: "bind-or-passthrough based on a gate." A more general primitive would be "elementwise select between two vectors based on a gate":

```
Select(x, y, gate)[i] = x[i] if gate[i] > 0 else y[i]
```

Then `ConditionalBind(a, b, gate) = Select(Bind(a, b), a, gate)` — stdlib.

**Counter:** Select is even more general and might be the right primitive. But Select introduces a different concept: "choose between two precomputed vectors." ConditionalBind is idiomatic (update vs. preserve); Select is mechanical (branch on gate). Both could coexist; ConditionalBind is the higher-level idiom.

See Question 3 below.

## Comparison

| Form | Operation | Gate role |
|---|---|---|
| `Bind(a, b)` | uniform elementwise product | none |
| `Blend(a, b, w1, w2)` | uniform weighted sum | none |
| `Resonance(v, ref)` | per-dim: keep `v` if agree, else `0` | implicit (sign of `ref`) |
| `ConditionalBind(a, b, gate)` | per-dim: bind if gate on, else `a` | explicit gate argument |

ConditionalBind is the only core form that takes an EXPLICIT per-dimension control vector as a separate argument.

## Algebraic Question

Does ConditionalBind compose with the existing algebra?

Yes. Inputs and output live in the ternary output space `{-1, 0, +1}^d`. Bind and pass-through both preserve the ternary alphabet (bind of two non-zero ternary inputs produces `±1`; zero inputs inherit zero per FOUNDATION's "Output Space" section). All downstream operations work unchanged.

Is it a distinct source category?

Yes — it introduces "per-dimension conditional computation based on a separate control input." No other core form has an explicit per-dimension control argument.

## Simplicity Question

Is this simple or easy?

Simple. One rule: gate positive → bind, else pass-through.

Is anything complected?

No. The form has a single semantic role. The gate is a first-class argument, not a hidden parameter.

Could existing forms express it?

Not with the current core set. A widened set including `Mask` or `Select` could, but those are separate proposals.

## Implementation Scope

**holon-rs changes** (~15 lines):

```rust
pub fn conditional_bind(a: &Vector, b: &Vector, gate: &Vector) -> Vector {
    a.iter().zip(b.iter()).zip(gate.iter())
        .map(|((&ai, &bi), &gi)| {
            if gi > 0 { ai * bi } else { ai }
        })
        .collect()
}
```

**HolonAST changes:**

```rust
pub enum HolonAST {
    // ... existing variants ...
    ConditionalBind(Arc<HolonAST>, Arc<HolonAST>, Arc<HolonAST>),
}
```

Encoder evaluates all three arguments, then applies the per-dimension rule.

## Questions for Designers

1. **Is functional update at this granularity the right level?** ConditionalBind enables "update one role's binding in a bundled structure." Is this the kind of operation the algebra should expose, or is it too close to imperative thinking?

2. **Gate semantics: sign-based or magnitude-based?** Convention in this proposal: `gate[i] > 0` triggers bind. Alternatives: `gate[i] == +1` (strict), or `|gate[i]| > threshold`. Strict sign-based is simplest; consistent with ternary vector conventions (zero in the gate means "no signal here," which falls into the `≤ 0` pass-through branch).

3. **Should `Select(x, y, gate)` be the more general primitive instead?** `Select` is lower-level ("choose x or y per dimension"); ConditionalBind is higher-level idiom. Case for Select: more primitive, enables more derived operations. Case for ConditionalBind: captures the common case (update via bind) without requiring composition. Which belongs in core?

4. **Relationship to `Resonance` (058-006).** Both are per-dimension operations with one vector as a "control." Should they share a conceptual category in FOUNDATION — "gated/masked operations"? Would make the algebra more organized.

5. **Ternary gate handling.** If `gate` is produced by `Resonance` (can contain zeros), the rule "gate > 0 → bind, else pass-through" means zero dimensions pass through. Is this the right default, or should zeros have distinct behavior (e.g., output zero)?

6. **Holon's precedent.** Does the holon library have a direct analog to ConditionalBind, and if so, what does it call it? The name here is descriptive but could align with existing terminology (e.g., `bind_masked`, `selective_bind`).
