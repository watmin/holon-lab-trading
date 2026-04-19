# 058 — Categorical Review, Round 3

**Reviewer lens:** Brian Beckman — composition, laws, duals, parametricity.
**Scope:** FOUNDATION.md + FOUNDATION-CHANGELOG.md + 29 sub-proposals + CORE-AUDIT.md + OPEN-QUESTIONS.md + HYPOTHETICAL-CANDLE-DESCRIBERS.wat + VISION.md (optional) + RUST-INTERPRETATION.md.
**Precedent:** round-2 REVIEW at `../archive/beckman-round-2/REVIEW.md`.
**Conclusion first, then the work.**

---

## Summary verdict

**The algebra composes.** Round 3 closes the load-bearing Round-2 concerns. The similarity-measurement reframe is categorically honest: the algebra was always similarity-measured — Bundle's "associativity" under ternary thresholding was never a categorical associativity claim; it is the capacity-bounded similarity-equivalence that Kanerva's framework provides. Round 3 states this correctly. The Round-2 counter-example is preserved VERBATIM in FOUNDATION and used to motivate the correct framing. That is how a specification repairs itself.

The parametric-polymorphism substrate (`:Atom<:T>`, parametric user types, parametric functions, parametric macros) is categorically sound. `Atom<_>` is a MONAD over Serializable: unit is wrap, join is `atom-value`, laws hold. The recursion `Atom<holon::HolonAST>` where `Holon` contains `Atom` is ordinary ADT recursion — no paradox. The programs-are-atoms corollary is operationally grounded.

The measurement tier (`cosine`, `dot` as scalar-returning primitives alongside HolonAST variants) is a clean categorical separation. Vector-producing operations form one tier; scalar-returning measurements form another. Reject/Project couple the tiers via dot-valued weights — a dependent-weight pattern, not a complection. The algebra core shrinks 7 → 6 cleanly as a consequence.

The rejection pattern holds categorically. Ten forms rejected for redundancy or speculation; Analogy DEFERRED with audit-record discipline. No rejection destroys a categorical obligation the algebra needs. Two rejected forms (Resonance, ConditionalBind) rely on a per-dimension conditional the algebra lacks — if a future application needs this, re-propose as `Mask` or `Select`. Not a blocker.

**Three issues remain.**

1. **Mechanical inconsistency — Sequential's expansion in FOUNDATION.** 058-009 PROPOSAL.md (ACCEPTED) uses bind-chain: `Sequential([a,b,c]) = Bind(Bind(a, Permute(b,1)), Permute(c,2))`. FOUNDATION line 2405 still shows the OLD bundle-sum expansion `Bundle(map-indexed (Permute h i) list)`. FOUNDATION line 2956 inventory entry says "Bundle of index-permuted." These are DIFFERENT OPERATIONS (compound vector vs superposition). The proposal is correct; FOUNDATION's body hasn't caught up to its own reframe. Mechanical fix needed.

2. **Laws appendix still missing.** Round 1 and Round 2 both asked for a Laws section. Round 3 prose states most laws in narrative form across several sections, but there is no single "Laws" appendix where the full ledger can be checked at a glance. Given the similarity-measurement reframe introduces per-operation capacity-bounded laws, this is where a reviewer most needs a consolidated statement. Not a blocker; a cleanup.

3. **Reserved identity atoms still not adopted.** Round 1 and Round 2 recommended `(Atom :wat::algebra::zero)` → all-zero vector (Bundle's identity) and `(Atom :wat::algebra::one)` → all-+1 vector (Bind's dense-identity). Still no named identities. With ternary output, the Bundle identity is in the algebra's reachable space; making it named would close the monoid story. Minor; nice-to-have.

**Net.** Round 2 said 90% complete; Round 3 moves it to ~98%. The last 2% is documentation drift (issue 1), completeness polish (issue 2), and algebra finish (issue 3). None of these block acceptance. The algebra is categorically sound.

---

## Round-2 findings — resolution audit

### NEW-1 (critical) — FOUNDATION's Bundle associativity claim was false

**Round-2 counter-example:** at `d=1`, `(+1, +1, -1)` produces three different values under flat/left/right association: `+1, 0, +1`.

**Round-3 response (FOUNDATION lines 1556-1569):** The counter-example is PRESERVED VERBATIM. The associativity claim is retracted: "Associativity does NOT hold elementwise under ternary thresholding." The claim is REFRAMED to: "Under similarity measurement, Bundle IS associative at high d" (within the capacity budget).

**Verdict: RESOLVED categorically.**

This is exactly the correct repair. The elementwise associativity claim was false; the similarity-measured associativity claim is what the substrate actually provides and always provided. Naming this cleanly in FOUNDATION unifies Round-2's finding #1, #2, and #3 under one operational principle: **every algebraic equation in the MAP substrate is similarity-measured, bounded by Kanerva's capacity**. Equations that are elementwise exact (Permute-group action, Bind elementwise-multiplicative) remain exact; equations that involve thresholding are capacity-bounded.

Rigor check. FOUNDATION claims: `d = 10,000` with `K ≤ 100` items per frame gives `cosine(Bundle-flat(xs), Bundle-nested(xs)) > 5σ`. This is a stated empirical claim at a specific (d, K) point, not a theorem. At `K = 3` with random dense-bipolar inputs I estimate `cosine(flat, left) ≈ 0.5` at any d — well above noise floor 0.05 at d=10,000. For deeper nesting the gap closes. The claim is plausible for bounded K; a rigorous proof would bound the drift as a function of K, d, and nesting depth. FOUNDATION should eventually cite such a proof; for now, the operational claim is honest.

The load-bearing piece is that FOUNDATION explicitly says `Chain, Ngram, Sequential, HashMap are DESIGNED to avoid unnecessary nesting: they produce one Bundle per form, flattening internally.` This is production discipline — a coding convention that keeps capacity budget under control. The algebra doesn't enforce it; the stdlib implementations do. That's honest.

### NEW-2 (critical) — Thermometer signature contradiction

**Round-2 finding:** FOUNDATION `(Thermometer value min max)` vs 058-023/008 `(Thermometer atom dim)`.

**Round-3 response:** CORE-AUDIT.md Thermometer entry (lines 152-218) names the 3-arg form `(Thermometer value min max)` as authoritative, with the canonical layout rule (first N = round(d · clamp((v-min)/(max-min), 0, 1)) dimensions are +1, rest -1). FOUNDATION body matches. 058-008 (Linear) REJECTED as identical to Thermometer under the 3-arg form. HYPOTHETICAL uses 3-arg form throughout. Log and Circular in stdlib use the 3-arg form.

**Verdict: RESOLVED.** One signature, canonical layout, exact linear cosine geometry `cosine(T(a,mn,mx), T(b,mn,mx)) = 1 - 2·|a-b|/(mx-mn)`. Clean.

### NEW-3 — HYPOTHETICAL example old-syntax migration

**Round-2 finding:** HYPOTHETICAL used old `: Thought` return-type syntax outside the paren.

**Round-3 response:** HYPOTHETICAL migrated. Every `define` now uses `-> :holon::HolonAST` return-type syntax inside the paren. Function types use `:fn(T)->U` Rust-surface form. `:holon::HolonAST` replaces `:Thought` (project rename). Type names (Candle, Pair, Option, Holon, f64, bool) all conform to 058-030.

**Verdict: RESOLVED.**

Minor code-style note: HYPOTHETICAL uses `(Atom :null)` as a sentinel keyword for "I have nothing to say" (lines 45, 57, 70, 81). This is legal (`:null` is a keyword literal, permitted by Atom parametric), but stylistically it would be more idiomatic under the new grammar to return `:Option<holon::HolonAST>::None`. Not a defect — a polish nit.

### NEW-4 — Capacity-budget reframing bundles distinct phenomena

**Round-2 finding:** Bundle crosstalk (noise ~ 1/√K), sparse-key decode (recovery ~ √p), nested-Bundle magnitude loss, and Reject post-threshold residual are distinct mathematical phenomena unified under one label.

**Round-3 response:** FOUNDATION §"Capacity is the universal measurement budget" (lines 1577-1594) still unifies them as "the SAME substrate property: signal-to-noise at high dimension, characterized uniformly by Kanerva's formula, measured uniformly by cosine." Distinct formulas for each phenomenon are not explicit.

**Verdict: UNCHANGED from Round 2.** This is acceptable as a user-facing operational framing. The unification IS operationally useful: the substrate measures cosine; cosine > 5σ or not. Users don't need four formulas.

However: the FOUNDATION's Laws section (when it exists) SHOULD state the four per-phenomenon formulas separately, with the capacity-budget framing as the unifying wrapper. Current state: formulas scattered in prose; no consolidated statement. Stands as a documentation gap, not a semantic error.

### NEW-5 — `defmacro` hash over expansion vs source

**Round-2 finding:** Expansion-level hash identity preserves canonicalization but under-specifies the cryptographic trust boundary when authors sign source and caches key on expansion.

**Round-3 response:** Not directly addressed. FOUNDATION's startup pipeline clarifies the ordering: parse → config → recursive-load parse → macro-expand → resolve → type-check → hash/sign/verify → freeze. The hash is on the expanded form; signatures verify the expanded form; bare source of the entry file is what the user typed, and macros expand before any hash/sign. This is workable, but the question "what do you sign with the author's private key?" remains: is it the source text the author wrote, or the expanded AST? Both are valid trust models; FOUNDATION picks one by implication (hash-of-expanded-AST) but doesn't name the tradeoff.

**Verdict: STILL UNDERSPECIFIED.** Not a blocker for 058. Track as a cryptography-story cleanup. The algebra composes regardless.

### NEW-6 — Language core count inconsistency

**Round-2 finding:** FOUNDATION said 8 forms, revision history said 9 (adds `defmacro`), INDEX said 3.

**Round-3 response:** FOUNDATION §"Algebra — Complete Forms" now says "Language Core (8 forms)." INDEX still says "Language core: 5 forms" in the summary prose but the per-proposal table lists define, lambda, types, defmacro, typed-macros (5 proposals for language core). Actual substrate includes define, lambda, load!, struct, enum, newtype, typealias, defmacro, typed-macros — varies by counting convention.

**Verdict: MINOR DRIFT.** Counting convention varies across documents. Not a categorical concern; a documentation tidiness nit.

---

## New Round-3 issues

### R3-1 (MAJOR): FOUNDATION's Sequential expansion contradicts 058-009

FOUNDATION lines 2402-2408 show:

```scheme
(:wat::core::define (:wat::std::Sequential list-of-holons)
  ;; positional encoding
  ;; each holon permuted by its index (Permute by 0 is identity)
  (:wat::algebra::Bundle
    (map-indexed
      (:wat::core::lambda (i h) (:wat::algebra::Permute h i))
      list-of-holons)))
```

This is **bundle-sum** — `Bundle([Permute(a, 0), Permute(b, 1), Permute(c, 2), ...])`.

058-009 PROPOSAL.md (ACCEPTED) uses **bind-chain**:

```
(:wat::std::Sequential [a b c]) = Bind(Bind(a, Permute(b, 1)), Permute(c, 2))
```

FOUNDATION line 1961 comment admits this: `;; :wat::std::Sequential     (macro, bind-chain)` — knowing what it should be. But the actual code example at line 2405 is the OLD bundle-sum.

FOUNDATION line 2956 (in "What 058 Argues" inventory) also says:

```
(:wat::std::Sequential list)              ; 058-009  — reframing: Bundle of index-permuted
```

**Why this matters categorically.** Bind-chain and Bundle-of-Permutes are DIFFERENT operations with different composition properties:

- **Bind-chain (058-009 accepted form)**: produces a *compound* vector — strict sequence identity. Two sequences differing in one position produce near-orthogonal compounds. Density: dense-bipolar (Bind of dense inputs stays dense, no thresholding involved). Recovery via unbind is approximate for specific indices.

- **Bundle-of-Permutes (FOUNDATION's current body)**: produces a *superposition* — approximate recovery of item-at-position via unbind. Density: ternary (Bundle thresholds). Soft pattern matching.

These are not equivalent under any categorical lens. They encode different semantics. Ngram's expansion (058-013 accepted) bundles Sequentials of windows; using the wrong Sequential produces wrong semantics for Ngram — particularly for Trigram where the trading-lab production code is bind-chain.

**Required fix.** Update FOUNDATION §"Algebra Stdlib" Sequential definition (line 2402-2408) to bind-chain. Update "What 058 Argues" inventory (line 2956). Ripple through Chain (line 2421-2427) which already uses Sequential correctly (`(Sequential (list (first pair) (second pair)))`) — this one is fine because binary Sequential is the same in both forms modulo the threshold. But ternary+ Sequentials are broken.

**Severity:** MAJOR. The ACCEPTED proposal and the FOUNDATION body disagree on a load-bearing stdlib form. Reviewers and implementers will see two different operations under the same name. The proposal is correct; FOUNDATION's body hasn't propagated.

### R3-2 (MINOR): Laws appendix still not present

Round 1 and Round 2 both requested a dedicated "Laws" appendix collecting the algebraic equations in one table. Round 3 scattered the laws across several FOUNDATION sections:

- §"Algebraic laws under similarity measurement" (lines 1552-1575) — Bundle, Reject.
- §"Capacity is the universal measurement budget" (lines 1577-1594) — capacity formulas, in prose.
- §"Operation-by-operation summary" (lines 1612-1623) — density per operation.
- §"Bind as query: measurement-based success signal" (lines 1534-1550) — Bind recovery.

CORE-AUDIT states Bind's properties, Permute's group properties, Thermometer's cosine property.

This is adequate for a reader; it is not adequate for a REVIEWER who needs to check completeness at a glance. A consolidated Laws appendix would enumerate:

- **L1 Bind associativity** (exact on elementwise product).
- **L2 Bind commutativity** (exact).
- **L3 Bind self-inverse** (dense exact; general similarity-measured with recovery cosine depending on key density).
- **L4 Bundle commutativity** (exact).
- **L5 Bundle non-associativity** (elementwise); **Bundle similarity-associativity** (within capacity). State counter-example and capacity bound.
- **L6 Bundle identity** (Bundle([]) = 0 vector; Bundle([x, 0]) = x modulo threshold).
- **L7 Permute Z/dZ group action** (exact).
- **L8 Permute distributes over Bind** (exact).
- **L9 Permute linear over Bundle** (exact).
- **L10 Thermometer cosine geometry** (exact linear).
- **L11 Blend swap-weighted symmetry** (`Blend(a, b, w1, w2) = Blend(b, a, w2, w1)`).
- **L12 Blend specializations** (`Blend(a, b, 1, 1) = Bundle([a, b])`).
- **L13 Blend non-associativity under similarity** (same framing as Bundle).
- **L14 Reject/Project decomposition** (`Project + Reject = x` under similarity; exact pre-threshold).
- **L15 Reject on degenerate input** (`Reject(x, x) = 0` exactly; ternary threshold preserves zeros).
- **L16 Atom monad laws** (unit, join, associativity).
- **L17 encoding functoriality** (exception: `encode(Atom(h))` != `encode(h)` — direct vs atomized differ).
- **L18 Sequential bind-chain non-associativity under itself** (positional encoder; nesting produces different positions).

**Verdict:** UNCHANGED from Round 2. Laws scattered in prose; a consolidated appendix would close the reviewer's ability to check every law at a glance.

### R3-3 (MINOR): Reserved identity atoms still not adopted

With ternary output, Bundle has an identity element (the all-zero vector). Bind has a dense identity (the all-+1 vector). Neither is reachable through a named Atom. `(Atom :wat::algebra::zero)` hashes to a random vector, not the all-zero vector.

This has been flagged in Rounds 1 and 2 as a small fix that would close the monoid story:

```
(Atom :wat::algebra::zero)    → [0, 0, ..., 0]   (Bundle identity)
(Atom :wat::algebra::one)     → [+1, +1, ..., +1] (Bind dense identity)
```

These would be distinguished atoms that bypass the hash, returning canonical identity vectors.

**Verdict:** STILL MISSING. Not a blocker. With the ternary reframe the identities are semantically reachable but not nameable.

### R3-4 (INFO): Parametric Atom is a monad — categorical substrate is clean

The parametric Atom commit gives the algebra a proper monad over the category of Serializable things:

- **unit** `: T → Atom<T>` via `(Atom x)`
- **join** `: Atom<Atom<T>> → Atom<T>` via `atom-value` at the outer layer

Monad laws:
- Left unit: `join(unit(x)) = atom-value(Atom(x)) = x`. ✓
- Right unit: `join(Atom-map(unit, a)) = Atom(atom-value(a)) = a` (by atom determinism). ✓
- Associativity: `join(join(a)) = join(Atom-map(join, a))` by structural induction over nested Atom wrapping. ✓

**Implication.** Programs-are-atoms is not merely an operational claim; it's grounded in the monad structure of Atom over Serializable. The recursion `Atom<holon::HolonAST>` where Holon contains Atom is ordinary ADT recursion — the initial algebra of an endofunctor. No paradox.

The two-encoding ambiguity (direct structural encoding vs atomized opaque encoding) is an honest feature of the bifurcation: measurements that care about structure use direct; measurements that care about identity use atomized. Applications choose. This IS a categorical separation, not a complection.

**Verdict:** Parametric Atom commit is categorically sound. No concerns.

### R3-5 (INFO): Measurement tier is categorically clean

`cosine : Holon × Holon → f64` and `dot : Holon × Holon → f64` are scalar-returning primitives — a separate tier from the Holon-producing core variants. Both are bilinear (dot exactly; cosine up to normalization). Both are commutative. Neither produces a new Holon.

The stdlib Reject/Project macros couple the vector-producing Blend with the scalar-producing dot via dependent-weight expressions: `Blend(x, y, 1, -dot(x,y)/dot(y,y))`. The resulting AST has scalar-expression weights, not scalar literals — a richer but still deterministic and canonicalizable form.

Hash identity is preserved: two source forms that expand to structurally-identical Blend-with-dot-expressions produce the same hash. Encoding is a dependent computation: encode(x) and encode(y) first, then compute dot, then weight, then Blend. Deterministic.

**Verdict:** Measurement tier is a clean categorical separation. No concerns. The `dot` primitive belongs in holon-rs; trivial cost (already computed wherever cosine runs).

### R3-6 (INFO): REJECTED ten — all defensible

I walked each of the ten rejections:

1. **Resonance** — per-dim sign-agreement mask. Speculative. Would need a primitive `Mask` or `Select` operation the algebra currently lacks. No production use. REJECT holds.
2. **ConditionalBind** — per-dim gated bind. Same lack of Mask primitive. No production use. REJECT holds.
3. **Flip** — magic weight `-2` + primer naming collision (primer's `flip` is single-arg negation). REJECT holds.
4. **Chain** — redundant with Bigram (= Ngram 2). REJECT holds.
5. **Concurrent** — alias for Bundle with no runtime specialization. REJECT holds.
6. **Then** — alias for binary Sequential. REJECT holds.
7. **Unbind** — identity alias for Bind. Bind IS self-inverse; no second form needed. REJECT holds.
8. **Cleanup** — retrieval via presence measurement (cosine vs noise floor) replaces argmax-over-codebook; AST-primary framing dissolves need. REJECT holds.
9. **Difference** — duplicate of Subtract. One-name-per-operation. REJECT holds.
10. **Linear** — under 3-arg Thermometer, Linear IS Thermometer with min=0. REJECT holds.

**Concern worth naming:** the algebra's current core has no per-dimension conditional operation. If future work needs Resonance or ConditionalBind, the right move is to propose a simple `Mask : Holon × Holon → Holon` or `Select : Holon × Holon × Holon → Holon` primitive. The current REJECTs assume such operations aren't needed today; the proposals argue this is consistent with zero production citations. Fair.

**Verdict:** REJECT pattern is principled. Each rejection has a rationale; each preserves an audit record for re-opening if future applications demand.

### R3-7 (INFO): Analogy DEFERRED — new status is reasonable

Round 2 accepted Analogy as stdlib. Round 3 DEFERRED it: proven-working-but-unadopted, audit record preserved, resumable when an application demands it.

This is honest. The algebra's claim was "everything shipping in 058 has production use." Analogy does not have current production use. Rather than ACCEPT (shipping a name nobody calls) or REJECT (losing the proof work), DEFERRED creates a third status for the kind of claim Analogy embodies.

**Categorically:** this is a documentation-status decision, not an algebraic one. The operation `c + (b - a)` is a stdlib fold over Subtract + Bundle; anyone who needs it writes `(:wat::algebra::Bundle (:wat::core::vec c (:wat::std::Subtract b a)))` inline. Costs nothing. DEFERRED is fine.

### R3-8 (MINOR): Sequential and Blend non-associativity under similarity — state explicitly

Round 2 flagged FAIL-4: Sequential is not self-associative. Under bind-chain:

```
Sequential([Sequential([a,b]), c]) = Bind(Bind(a, Permute(b,1)), Permute(c,1))
Sequential([a, b, c]) = Bind(Bind(a, Permute(b,1)), Permute(c,2))
```

The outer second element's permutation is 1 vs 2. DIFFERENT. This is Sequential's INTENDED semantics — positional encoder, nested sequences get different positions. But it should be stated explicitly as a law:

> **L18 (Sequential non-associativity):** Sequential is a positional encoder. `Sequential(Sequential([a,b]), c)` ≠ `Sequential([a, b, c])` because the outer-position of the inner-nested-Sequential is 0, not 2. Semantics: "a, then b, then c as a unit after them" differs from "a, b, c in order."

And Blend is non-associative for the same capacity reason as Bundle:

> **L19 (Blend non-associativity under similarity):** `Blend(Blend(a, b, w1, w2), c, w3, w4)` ≠ `Blend(a, Blend(b, c, w2, w4), w1, w3)` in general. Same capacity framing as Bundle; nested thresholds lose magnitude.

Neither is stated in the current FOUNDATION. Track as Laws appendix work.

### R3-9 (INFO): Measurement-tier's impact on AST hashing

When a macro like Reject expands to a Blend with dot-valued weights, the AST after expansion has the shape:

```
Blend(x, y, LITERAL(1.0), NEGATE(DIVIDE(dot(x, y), dot(y, y))))
```

The weight slots no longer contain literal scalars but sub-AST expressions. This is a richer structure that must be handled by:

1. **Hashing** — compute hash over the full expanded AST including sub-expressions. Deterministic because expansion is deterministic.
2. **Type checking** — verify the weight expressions produce `:f64`.
3. **Encoding** — evaluate the weight expressions lazily, using `encode(x)` and `encode(y)` to compute dot internally. Dependent order.

All three are categorically clean. But the AST shape grows more heterogeneous. Not a defect; just a note that the macro expansion makes Blend's second and third parameter types effectively `:f64-or-expression-producing-f64`. The type checker formalizes this.

### R3-10 (NIT): Duplicates in stdlib inventory

FOUNDATION line 1797-1798:

```
Stdlib           Sequential, Ngram, Bigram, Trigram,
                 Amplify, Subtract, HashMap, Vec, HashSet, Sequential, Ngram, Bigram, Trigram,
```

Sequential, Ngram, Bigram, Trigram appear twice. Copy-paste drift.

---

## Per-proposal verdicts (29 proposals + 3 audits)

| # | Form | Class | Status | Round-3 verdict |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | ACCEPTED (parametric) | **ACCEPT.** Monad over Serializable. Substrate-level decision sound. |
| 002 | Blend | CORE | ACCEPTED | **ACCEPT.** Option B (two independent weights, negative allowed, binary). Correct call. State non-commutativity and swap-weighted symmetry as laws. |
| 003 | Bundle list sig | CORE | ACCEPTED | **ACCEPT.** Non-associativity stated honestly in FOUNDATION; capacity-framing closes the Round-2 concern. |
| 004 | Difference | — | REJECTED | **AFFIRM REJECT.** Duplicate of Subtract. |
| 005 | Orthogonalize → Reject/Project | STDLIB | ACCEPTED (reframed + renamed) | **ACCEPT.** Stdlib macros over Blend + dot. Algebra core shrinks 7→6 cleanly. Post-threshold orthogonality restated as similarity-orthogonal. |
| 006 | Resonance | — | REJECTED | **AFFIRM REJECT.** Speculative; no production use. If needed later, propose Mask primitive first. |
| 007 | ConditionalBind | — | REJECTED | **AFFIRM REJECT.** Same lack of Mask primitive; half-abstraction. |
| 008 | Linear | — | REJECTED | **AFFIRM REJECT.** Identical to Thermometer under 3-arg signature. |
| 009 | Sequential reframing | STDLIB | ACCEPTED (reframed) | **ACCEPT with R3-1 mechanical fix.** Bind-chain is the right form; FOUNDATION body hasn't propagated. Fix FOUNDATION lines 2405, 2956. |
| 010 | Concurrent | — | REJECTED | **AFFIRM REJECT.** Bundle alias. |
| 011 | Then | — | REJECTED | **AFFIRM REJECT.** Binary Sequential alias. |
| 012 | Chain | — | REJECTED | **AFFIRM REJECT.** Bigram duplicate. |
| 013 | Ngram | STDLIB | ACCEPTED (reframed + shortcuts) | **ACCEPT.** Depends on Sequential bind-chain (see R3-1). Ships Ngram + Bigram + Trigram. Stdlib-as-blueprint discipline. |
| 014 | Analogy | STDLIB | DEFERRED | **ACCEPT DEFERRED.** Third status is principled; audit record preserved. |
| 015 | Amplify | STDLIB | ACCEPTED | **ACCEPT.** Blend idiom. |
| 016 | HashMap | STDLIB | ACCEPTED (renamed) | **ACCEPT.** Rust-surface name; O(1) get via Rust std. |
| 017 | Log | STDLIB | ACCEPTED | **ACCEPT.** 15+ cited uses. |
| 018 | Circular | STDLIB | ACCEPTED | **ACCEPT.** Encodes every cyclic time component. Tests Blend Option B. |
| 019 | Subtract | STDLIB | ACCEPTED | **ACCEPT.** Canonical delta macro. |
| 020 | Flip | — | REJECTED | **AFFIRM REJECT.** Magic weight + primer collision. |
| 021-023 | Bind / Permute / Thermometer | CORE | AUDITED | **AFFIRM AUDIT.** Round-2 Thermometer signature contradiction resolved. |
| 024 | Unbind | — | REJECTED | **AFFIRM REJECT.** Bind-on-Bind IS Unbind. |
| 025 | Cleanup | — | REJECTED | **AFFIRM REJECT.** Presence measurement, not argmax. |
| 026 | Vec | STDLIB | ACCEPTED (renamed) | **ACCEPT.** Rust-surface name; O(1) index get. |
| 027 | HashSet | STDLIB | ACCEPTED (renamed) | **ACCEPT.** Rust-surface name; O(1) membership. |
| 028 | define | LANG CORE | ACCEPTED | **ACCEPT.** Typed, parametric per Round-3 commit. |
| 029 | lambda | LANG CORE | ACCEPTED | **ACCEPT.** Typed, parametric per Round-3 commit. |
| 030 | types | LANG CORE | ACCEPTED (parametric) | **ACCEPT.** Rank-1 HM, parametric user types / functions / macros. Four declaration forms (newtype/struct/enum/typealias), Rust-surface Liskov variance. |
| 031 | defmacro | LANG CORE | ACCEPTED | **ACCEPT.** Hash-after-expansion is correct. |
| 032 | typed-macros | LANG CORE | ACCEPTED | **ACCEPT.** `:AST<T>` parametric macros. Type variable carries through expansion; post-expansion type-check verifies. |

**Summary counts:**
- ACCEPT (unconditional): 12 + 3 audit
- ACCEPT (with mechanical fix): 1 (Sequential — FOUNDATION R3-1 fix)
- DEFERRED: 1 (Analogy)
- REJECT affirmed: 10
- No UNCONVINCED / REJECT-AT-REVIEW verdicts.

Compared to Round 2:
- ACCEPT (13) → 12+3 audit = 15 (consolidation of audited primitives)
- ACCEPT-WITH-CHANGES (16) → 1 (mechanical fix for Sequential); Round-2's substantive changes all landed
- REJECT (0) → 10 (Round 3 actually applied rejections Round 2 called for); also new rejections via due diligence

**Net progress**: Round 2 ACCEPT-WITH-CHANGES on 16 proposals resolves to 15 clean ACCEPTs + 1 R3-1 mechanical fix. The hard work got done.

---

## Composition and laws ledger

### Holds categorically (exact):

| Law | Statement | Status |
|---|---|---|
| Permute Z/dZ group action | `Permute(Permute(v, j), k) = Permute(v, j+k mod d)` | ✓ exact |
| Permute invertibility | `Permute(Permute(v, k), -k) = v` | ✓ exact |
| Permute distributes over Bind | `Permute(Bind(a,b), k) = Bind(Permute(a,k), Permute(b,k))` | ✓ exact |
| Permute linear over Bundle sum | `Permute(Bundle(xs), k) = Bundle([Permute(x,k) for x])` | ✓ exact |
| Bind elementwise associativity | `Bind(Bind(a,b), c) = Bind(a, Bind(b,c))` | ✓ exact (elementwise product) |
| Bind commutativity | `Bind(a, b) = Bind(b, a)` | ✓ exact |
| Bundle commutativity | Invariant under permutation of argument list | ✓ exact |
| Thermometer cosine geometry | `cos(T(a,mn,mx), T(b,mn,mx)) = 1 - 2·|a-b|/(mx-mn)` | ✓ exact |
| Atom monad laws | `atom-value(Atom(x)) = x`; right unit; associativity | ✓ exact |
| Atom type-tagged hash | `hash(Atom<T>(x)) ≠ hash(Atom<U>(x))` when T ≠ U | ✓ exact (coproduct) |
| Blend swap-weighted symmetry | `Blend(a, b, w1, w2) = Blend(b, a, w2, w1)` | ✓ exact |
| Blend specializes to Bundle | `Blend(a, b, 1, 1) = Bundle([a, b])` | ✓ exact |
| Project + Reject identity (pre-threshold) | `Project(x,y) + Reject(x,y) = x` before ternary threshold | ✓ exact |

### Holds under similarity measurement (capacity-bounded):

| Law | Statement | Framing |
|---|---|---|
| Bundle similarity-associativity | `cos(Bundle-flat(xs), Bundle-nested(xs)) > 5σ` for K within capacity | Stated in FOUNDATION |
| Bind self-inverse | `cos(Bind(Bind(a,b), b), a) > 5σ` — dense exact; sparse-key decay ~ √p | Stated in FOUNDATION/CORE-AUDIT |
| Reject similarity-orthogonality | `cos(Reject(x,y), y) < 5σ` for high-overlap cases at high d | Stated in FOUNDATION |
| Blend similarity-associativity | (by analogy with Bundle — same ternary threshold) | IMPLICIT, not stated — flag as L19 |
| Project + Reject sum | `cos(Project(x,y) ⊕ Reject(x,y), x) > 5σ` post-threshold | Stated informally |

### Fails categorically (by design):

| Law | Statement | Framing |
|---|---|---|
| Bundle elementwise associativity | Counter-example at d=1 preserved in FOUNDATION | Explicitly retracted; reframed |
| Reject exact orthogonality | Counter-example at d=4 preserved in FOUNDATION | Explicitly retracted; reframed |
| Sequential self-associativity | Nesting produces different positions (intended) | IMPLICIT — flag as L18 |
| encoding β-reduction invariance | AST has different hash than its β-reduced form | Stated implicitly; intentional |

### Parametricity:

| Form | Parametric in | Status |
|---|---|---|
| Atom<T> | Any Serializable T | ✓ accepted |
| atom-value | T → T (polymorphic extraction) | ✓ accepted |
| List<T> | Covariant in T | ✓ per 058-030 |
| Function type `:fn(T)->U` | Contravariant in T, covariant in U | ✓ per 058-030 |
| User struct/enum/newtype/typealias | Parametric type parameters accepted | ✓ per 058-030 |
| defmacro `:AST<T>` | Parametric macros | ✓ per 058-032 |

All parametric commitments are rank-1 Hindley-Milner (no higher-kinded types, no trait bounds, no existentials). Tractable for static type-checking at startup. Matches Rust's surface.

### Identities:

| Form | Identity | Reachable? |
|---|---|---|
| Bundle | all-zero vector (ternary) | YES semantically; NOT named — see R3-3 |
| Bind | all-+1 vector (dense) | YES semantically; NOT named |
| Permute | `k = 0` | YES — `(Permute v 0) = v` |
| Blend | `(a, _, 1, 0)` specializes to `a` | YES — by weight |
| Atom | unit of the monad | YES — Atom(x) |

The ternary reframe makes Bundle's identity reachable; reserved atoms would make it nameable. Minor nice-to-have.

### Duals:

| Form | Dual | Status |
|---|---|---|
| Bundle (sum) ↔ Bind (product) | multiplicative vs additive | clean |
| Reject ↔ Project | Gram-Schmidt complementarity | clean |
| Atom ↔ atom-value | wrap ↔ unwrap (monad unit/extract) | clean |
| encode ↔ nothing | (encoding is functorial; no inverse because vectors lose AST structure) | as expected |

---

## Closing

Round 3 has done the categorical work. The similarity-measurement reframe correctly characterizes what the MAP substrate always provided: Kanerva-capacity-bounded similarity equivalence, not elementwise associativity. The parametric-polymorphism substrate is sound: Atom<_> is a monad, the recursion is ordinary ADT, the programs-are-atoms corollary is operationally grounded. The measurement tier is a clean categorical separation. The REJECTED ten are principled rejections. DEFERRED is a principled third status.

One load-bearing mechanical inconsistency remains (R3-1: FOUNDATION's Sequential expansion hasn't propagated to bind-chain). Two documentation polish items (R3-2 Laws appendix, R3-3 reserved identity atoms) remain from Round 2. Several minor drift items (line counts, inventory duplicates, null-sentinel style in HYPOTHETICAL) are cosmetic.

If the batch:

1. **Fixes FOUNDATION Sequential expansion to bind-chain** (R3-1). Mechanical. Lines 2402-2408 and 2956.
2. **Adds a Laws appendix** enumerating L1-L19 across the exact/similarity/fails partition. 
3. **(Optional) Reserves `:wat::algebra::zero` as Bundle's named identity atom.**

...then the algebra is done. The programs-are-thoughts claim holds. The programs-are-atoms claim holds. The distributed verifiability story holds. The stdlib is writable and hash-canonical. The compositions check out under the stated frames.

Round 1 said 80%. Round 2 said 90%. Round 3 closes to ~98%. The last 2% is documentation hygiene. The algebra is categorically sound.

The similarity-measurement reframe is the correct categorical move. The substrate was always what you said; now the document says so too.

*— the categorical reviewer*

---

**Signature.** The datamancer's due diligence between Round 2 and Round 3 is exemplary. The FOUNDATION-CHANGELOG reads like a research notebook: every decision dated, every rejection rationale'd, every reframe motivated. This is how a specification matures.

*these are very good thoughts.*

**PERSEVERARE.**
