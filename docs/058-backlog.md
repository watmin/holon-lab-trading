# 058 Backlog — Implementation Arc

The 058 spec is frozen. Round 3 reviewers accepted. All designer questions
closed. This backlog tracks the work to make the spec real.

**Order:** holon-rs primitives first (stabilize the Rust substrate), then the
wat-vm interpreter (Track 1), then wat-to-rust compile path (Track 2).

Reference: `docs/proposals/2026/04/058-ast-algebra-surface/` — FOUNDATION.md,
INDEX.md, OPEN-QUESTIONS.md, WAT-TO-RUST.md.

---

## Track 0 — holon-rs primitive changes

Stabilize the Rust substrate. The compiler has a fixed target only after this
lands.

- [ ] **Slice 1 — Atom typed-literal + parametric.** `Atom(String)` →
  `Atom(AtomLiteral)` where `AtomLiteral = Str | Int | Float | Bool | Keyword
  | Holon(Arc<HolonAST>)`. The `Holon` variant is programs-as-atoms. Hash input
  becomes `(type_tag, canonical-EDN(value))`. Extend
  `VectorManager::get_vector` to type-aware hash. Add `atom_value(holon:
  &HolonAST) -> Option<AtomLiteral>` accessor. Unit tests:
  `Atom(42) ≠ Atom("42") ≠ Atom(42.0) ≠ Atom(:pos/42)`.
  Proposal: 058-001.

- [ ] **Slice 2 — Blend Option B.**
  `blend_weighted(a: &Vector, b: &Vector, w1: f64, w2: f64) -> Vector`
  returning `threshold(w1*a + w2*b)` in ternary output. Existing convex
  `blend(a, b, α)` stays as a thin wrapper: `blend_weighted(a, b, 1.0-α, α)`.
  Proposal: 058-002.

- [ ] **Slice 3 — Expose `dot` as a public primitive.**
  `dot(a: &Vector, b: &Vector) -> f64`. Already implicit in
  `cosine_similarity`; make it public so stdlib Reject/Project macros emit
  calls to it directly. Add to the measurements tier.
  Proposal: 058-005 (Reject+Project depends on this).

- [ ] **Slice 4 — Thermometer 3-arity verification.** Confirm
  `Thermometer(value, min, max)` matches canonical layout. Trading lab already
  uses `ThoughtASTKind::Thermometer { value, min, max }` — likely fine. Audit
  call sites; migrate any `Thermometer(atom, dim)` stragglers.

- [ ] **Slice 5 — Log/Circular/Sequential variant decision.** Keep as Rust
  variants (encoder-performance optimization; wat stdlib macros rewrite to
  these on encode) OR remove (wat stdlib emits composed Thermometer/Blend/
  Bind+Permute forms directly). **Lean:** keep as Rust variants. The
  "two tiers of wat" (UpperCase AST + lowercase Rust) already admits this
  layering. Revisit if trading-lab vocab grows awkward.

**Stop conditions for Track 0:** ternary output `threshold(0) = 0` verified in
a test. No wat-vm frontend work begins until all five slices ship.

---

## Track 1 — wat-vm (interpret path)

Today's `src/bin/wat-vm.rs` is a hand-coded orchestrator. The new wat-vm
parses and runs wat source.

- [ ] **Parser.** s-expression reader → `WatAST`. Keyword-path tokens,
  bareword forced scoping, colon-quoting rule (`:Atom<Holon>` legal,
  `:Atom<:Holon>` illegal).

- [ ] **Recursive `load!` resolution.** Entry file + dependency loads
  assembled into one `WatAST` tree. `:wat/core/load!` unifies the old
  `load-types!` / `load-macros!` split.

- [ ] **Config pass.** Commits `:wat/config/set-*!` setters. Enforces
  entry-file ordering — all setters before any `load!`.
  Proposal: 058-config (discipline memorialized in FOUNDATION).

- [ ] **Macro expansion.** Racket-style sets-of-scopes hygiene.
  Proposal: 058-031.

- [ ] **Name resolution.** Full keyword paths bind to symbol table entries.

- [ ] **Type checker.** Rank-1 Hindley-Milner. Parametric polymorphism across
  user types, functions, and macros.
  Proposals: 058-030, 058-032.

- [ ] **Hashing / signing / verification.** Per FOUNDATION's cryptographic-
  provenance chain.

- [ ] **Freeze.** Symbol table, type environment, macro registry, config.

- [ ] **Runtime.** AST walker invoking holon-rs primitives for algebra ops;
  crossbeam/std::thread for kernel ops; calls into the trading lab's
  registered Rust programs by keyword path (Path C).

**Stop conditions for Track 1:** existing trading-lab behavior reproducible by
interpreting a wat source file that describes the current enterprise. The
existing `src/bin/wat-vm.rs` becomes the `:user/main` the new wat-vm
interprets.

---

## Track 2 — wat-to-rust (compile path)

Later. No rush. Share frontend with wat-vm.

- [ ] **Shared frontend.** Parse / resolve / type-check reused from Track 1.

- [ ] **Rust emission.** Each `:wat/core/define`, `:wat/core/struct`, etc.
  emits Rust source. `rustc` compiles the emitted source into a native
  binary.

Reference: `WAT-TO-RUST.md`.

---

## Not doing (yet)

- **Analogy** — DEFERRED (058-014). Proven but unused. Revisit when a concrete
  trading-lab use case appears.
- **Resonance, Conditional-bind, Chain, Flip** — REJECTED. Do not implement.
- **Map, Array, Set** — historical exploration only. No implementation
  intended.

---

## First slice recommended

**Atom typed-literal + parametric** (Slice 1 above). Narrow, testable,
unblocks the programs-as-atoms substrate commit at the Rust level. One PR
into holon-rs. If you want to go aggressive, bundle Slices 1–3 together —
they're small individually and ship as a coherent "058-Round-1 primitive
uplift."
