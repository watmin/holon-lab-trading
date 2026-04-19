# Wat → Rust — The Compile Path

**Purpose:** conceptual sketch. A Rust program (the wat-to-rust compiler) consumes wat source and emits Rust source. Rustc compiles that Rust to a binary. The resulting binary is a wat program running at native speed with no interpreter overhead.

**Status:** seed document. Here to get the idea on disk. Iterate.

**Relation to other docs:**
- `FOUNDATION.md` — the algebra and kernel being implemented.
- `RUST-INTERPRETATION.md` — the INTERPRET path (wat source → wat-vm → interpreted).
- This document — the COMPILE path (wat source → Rust source → rustc → binary).

Two execution paths; one language. Both paths run the same wat program with the same semantics. The choice is deployment-tier: interpret for iteration and dynamic loads, compile for production throughput and static binaries.

---

## The Core Insight

The wat-vm already exists — it's a Rust binary that consumes wat. The observation is that a *second* Rust program can consume the same wat and produce **Rust source** instead of evaluating it. Then rustc compiles the emitted Rust into a binary. The chain:

```
  wat source  ─────►  wat-to-rust  ─────►  Rust source  ─────►  rustc  ─────►  binary
                    (Rust program)                              (stock)
```

Rust consumes wat. Rust produces Rust. Stock rustc finishes the job. No new language in the toolchain; Rust is both the host for the wat-vm and the target of the wat-to-rust compiler.

**The whole trading lab becomes expressible as a wat program.** `src/bin/wat-vm.rs` and its supporting modules (market observer, regime observer, broker, treasury, console, cache, database) re-express as wat. Run `wat-to-rust` on that wat source; get Rust source out; compile with rustc; get a binary that matches the current trading lab's behavior. Bootstrapping.

---

## Two Paths, One Semantics

```
                ┌─────────────────────────────────────────┐
                │                                         │
                │    wat source (keyword-path AST)        │
                │                                         │
                └──────────────┬──────────────────────────┘
                               │
                ┌──────────────┴──────────────┐
                │                             │
                ▼                             ▼
     ┌──────────────────┐          ┌──────────────────┐
     │  wat-vm          │          │  wat-to-rust     │
     │  (Rust binary)   │          │  (Rust binary)   │
     │                  │          │                  │
     │  Parses, type-   │          │  Parses, type-   │
     │  checks, freezes │          │  checks, emits   │
     │  symbol table,   │          │  Rust source.    │
     │  interprets.     │          │                  │
     └────────┬─────────┘          └────────┬─────────┘
              │                             │
              ▼                             ▼
       Runtime behavior              ┌──────────────────┐
       (fast iteration,              │  rustc           │
       dynamic eval, hot             │                  │
       reload, engram                │  Compiles the    │
       introspection)                │  emitted Rust.   │
                                     └────────┬─────────┘
                                              │
                                              ▼
                                       Native binary
                                       (production tier,
                                       no interpreter
                                       overhead, static
                                       link, smaller
                                       memory footprint)
```

The two paths share: the parser, the resolver, the type checker, the static symbol table. They diverge at the end: interpret walks the AST against the symbol table; compile emits Rust source that does the same thing.

---

## What the Compiler Emits

### Algebra operations — direct Rust calls

A wat call to `(:wat/algebra/Bind x y)` emits a direct call into the `holon-rs` primitives:

```scheme
  ;; wat
  (:wat/algebra/Bind
    (:wat/algebra/Atom :open-price)
    (:wat/algebra/Thermometer (:wat/std/get c :open) 0 100000))
```

```rust
// emitted Rust
holon::kernel::primitives::bind(
    vm.atom_vector(&Atom::Keyword("open-price")),
    scalar_encoder.thermometer(get(c, "open"), 0.0, 100_000.0),
)
```

No interpreter dispatch, no symbol-table lookup, no HolonAST enum match. The `:wat/core/` forms expand inline; the `:wat/algebra/` forms become direct Rust function calls.

### Kernel primitives — crossbeam + std::thread

```scheme
(:wat/kernel/make-bounded-queue :Candle 1)
```

```rust
crossbeam::channel::bounded::<Candle>(1)
```

```scheme
(:wat/kernel/spawn :my/app/observer-loop candle-rx result-tx state)
```

```rust
std::thread::spawn(move || {
    my_app::observer_loop(candle_rx, result_tx, state)
})
```

Kernel primitives are a thin wrapper over std + crossbeam. The emitted Rust looks like what a human would write.

### Stdlib macros — already compiled at parse

By the time the wat-to-rust compiler sees the AST, `defmacro` expansion has already run (same startup pipeline as the interpret path). `(:wat/std/Subtract a b)` has already become `(:wat/algebra/Blend a b 1 -1)` in the AST. The compiler never sees macro aliases; it only emits calls to core forms.

### User `define`s — Rust functions

```scheme
(:wat/core/define (:my/app/process (c :Candle) -> :Holon)
  (:wat/algebra/Bind
    (:wat/algebra/Atom :open-price)
    (:wat/algebra/Thermometer (:wat/std/get c :open) 0 100000)))
```

```rust
pub fn process(c: &Candle) -> Holon {
    holon::kernel::primitives::bind(
        vm.atom_vector(&Atom::Keyword("open-price")),
        scalar_encoder.thermometer(get(c, "open"), 0.0, 100_000.0),
    )
}
```

Keyword path → Rust module + function name. `:my/app/process` becomes `my_app::process`. `:wat/std/HashMap` is the user-facing name for a type that in Rust is `std::collections::HashMap`; the compiler knows the mapping.

### Types — Rust structs / enums / aliases

```scheme
(:wat/core/struct Candle [open : :f64] [high : :f64] [low : :f64] [close : :f64])
```

```rust
pub struct Candle {
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
}
```

The four `:wat/core/` type-declaration forms (`struct`, `enum`, `newtype`, `typealias`) map to the obvious Rust form. Keyword types (`:f64`, `:i64`, `:bool`) are already the Rust primitive names — no translation needed.

---

## Bootstrap — wat-vm in wat

If the compile path works, the wat-vm itself can be written in wat. Today's `src/bin/wat-vm.rs` (≈840 lines), the market-observer module, the regime-observer module, the broker module, the treasury, the Console/Cache/Database programs — all expressible as wat programs.

Run `wat-to-rust` on that wat source. Get Rust source. Compile with rustc. The resulting binary behaves identically to today's hand-written trading lab. Self-hosting.

The payoff: every change to the wat-vm is a change to **wat source**, not to Rust source. New kernel primitives, new stdlib programs, new algebra operations — all authored in wat, compiled through wat-to-rust, hitting production at the performance tier of native code. The handwritten Rust ossifies to the compiler itself (wat-to-rust) and the `holon-rs` algebra primitives. Everything else moves up into wat.

---

## What This Enables

- **Production deployments at native speed.** No interpreter overhead, static link, smaller memory footprint, easier sandboxing.
- **Inspectable output.** The emitted Rust is readable — a human can code-review the compiled form of a wat program. Diff two runs. Audit trails at the Rust level.
- **Same language, two tiers.** Authors write wat. Development runs interpret (fast iteration, hot reload, eval). Production runs compile (throughput, binary size). No syntactic or semantic difference — just deployment choice.
- **Portable distribution.** A wat program + wat-to-rust + rustc = binary anywhere Rust supports (x86, ARM, embedded, WASM eventually). No wat-vm interpreter to port; the compiler generates platform-native Rust.
- **Bootstrap loop.** Improvements to the wat-vm authored in wat, compiled through itself. Each cycle raises the abstraction of what's hand-written in Rust.

---

## What This Costs

- **A compiler to maintain.** The wat-to-rust compiler is another Rust program parallel to the wat-vm. Both must agree on parser, type checker, symbol table, signing — they share the frontend, then diverge.
- **Cryptographic identity story needs extension.** A wat program's signed hash is stable. The emitted Rust hash is DIFFERENT (different whitespace, different naming translation). Two layers of signing: signed wat (the authored artifact), signed binary (the deployed artifact). Contract: the binary corresponds to the wat if and only if wat-to-rust run on the signed wat produces this binary's source. Reproducible builds matter.
- **Dynamic eval is lost in the compiled binary.** The interpret path supports `(:wat/kernel/eval ast)` against the static symbol table. A compiled binary has no interpreter available — eval either goes away in the compiled form (compile-time pragma disables it) or the binary links in a mini-interpreter for eval calls only (choose per deployment).
- **Hot reload is lost in the compiled binary.** Interpret path can reload code on the fly; compile path is statically linked. Production accepts this. Development stays on interpret.

---

## Open Questions

- **Emit target.** Does the compiler emit `src/` files that rustc consumes, or does it drive rustc as a library and emit in-memory? Former is simpler and inspectable; latter is tighter feedback loop.
- **Optimization level.** Does the compiler emit optimized Rust (inline everything, specialize for known types, eliminate redundant `Arc::clone`) or just "correct" Rust and let rustc optimize? Start with correct; optimize later.
- **Eval in compiled binaries.** Keep eval available in compiled binaries (at the cost of linking a mini-interpreter)? Or disable it (tighter binary, narrower semantic)? Likely a deployment flag.
- **Signed-binary verification.** What's the trust chain? `sha256(wat) → sha256(emitted-rust) → sha256(binary)` — who verifies each link? Reproducible builds with pinned rustc + pinned wat-to-rust would give bit-identical binaries from identical wat input. Worth the ops cost?
- **Share frontend with wat-vm.** The parser, resolver, type-checker, macro-expander are the same in both paths. Extract as a shared crate consumed by both wat-vm and wat-to-rust? Yes, eventually — both paths drift otherwise. Up-front work or evolutionary.
- **Naming the compiler.** `wat-to-rust`? `watc`? `watrc`? `holonc`? The name will stick; pick deliberately.

---

## Where This Document Goes Next

This is a seed. Things that would graduate content from here into sibling documents:

- **A concrete translation table** — every `:wat/core/`, `:wat/algebra/`, `:wat/std/`, `:wat/kernel/` form mapped to its Rust emission template. When complete, this becomes `WAT-TO-RUST-EMISSION.md` (a reference like `RUST-INTERPRETATION.md`).
- **A worked example** — re-expressing one trading lab module (say, the market observer) as wat, showing the emitted Rust side-by-side with the hand-written Rust. Motivating evidence that the bootstrap works.
- **Integration with the wat-vm frontend** — once the shared crate idea firms up, this document references it by name.

Iterate.

---

*the machine compiles itself.*
