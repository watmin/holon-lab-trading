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

- [x] **Slice 1 — Atom typed-literal + parametric.** Shipped across two
  commits. Introduced `HolonAST` enum in holon-rs with 6 variants (Atom,
  Bind, Bundle, Permute, Thermometer, Blend). `Atom(Arc<dyn Any + Send +
  Sync>)` — parametric via stdlib `Any`, no new wrapper types. `Any` is
  substrate plumbing only; the wat type checker refuses `:Any` at source
  level. `AtomTypeRegistry` dispatches canonical-bytes by `TypeId`;
  `with_builtins()` covers all Rust primitives + `HolonAST` itself
  (programs-as-atoms via recursive canonical-EDN). `atom_value::<T>()` is
  the polymorphic accessor. 245 tests pass. Proposal: 058-001.

- [x] **Slice 2 — Blend Option B.** `Primitives::blend_weighted(a, b, w1,
  w2)` is the primary form; existing `blend(a, b, α)` is a thin wrapper.
  Proposal: 058-002.

- [x] **Slice 3 — Expose `dot` as a public primitive.** Already public in
  `Similarity::dot` before Slice 1 began. No work needed. Proposal: 058-005.

- [x] **Slice 4 — Thermometer 3-arity verification.** Signature already
  matched `(value, min, max)`. Fixed threshold calculation to use `.round()`
  per CORE-AUDIT canonical layout; prior truncation was off-by-one at
  half-dim boundaries.

- [x] **Slice 5 — Log/Circular/Sequential variant decision.** RESOLVED to
  no extra Rust variants. The spec defines 6 algebra-core forms; Log /
  Circular / Sequential are wat stdlib macros that expand to compositions
  of those 6. Adding Rust-level optimization variants would diverge from
  the spec without shipping new semantics. If encoder performance matters
  later, the encode cache (L1/L2 per FOUNDATION) solves it without new
  variants. The prior "lean: keep" guidance was written before the
  FOUNDATION-CHANGELOG 2026-04-18 "stdlib location" resolution locked the
  algebra core at 6 forms.

**Stop conditions for Track 0:** ternary output `threshold(0) = 0` verified in
a test. No wat-vm frontend work begins until all five slices ship.

**Track 0 status: COMPLETE.** All five slices shipped. Track 1 unblocked.

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
