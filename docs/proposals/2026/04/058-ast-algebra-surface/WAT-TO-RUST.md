# Wat → Rust — The Compile Path

> **STATUS: RETIRED 2026-04-21.** The conceptual sketch below is preserved
> as historical record — the seed of an idea that looked load-bearing in
> Chapter 10's FOUNDATION landing. It isn't anymore.
>
> **Why retired.** The INTERPRET path (wat source → wat-vm → evaluated)
> shipped and proved out across arcs 001–010 in wat-rs. Rust-interop — the
> one concrete need that motivated the compile path — was paved differently
> and better: the `#[wat_dispatch]` proc-macro (arc 002, `wat-macros/` crate)
> plus the `:rust::*` sibling namespace (BOOK Chapter 18 — *The Host*) let
> wat reach into Rust crates directly. Wat is a hosted language on Rust the
> way Clojure is hosted on the JVM. The boundary is `:rust::<crate>::<Type>`
> at the source level and annotated `impl` blocks at the Rust side. No
> source-to-source compiler needed for the capability this doc was
> originally chasing.
>
> **What the compile path would still hypothetically add.** Native binary
> emission with no interpreter overhead. That's genuine — the wat-vm is
> still an interpreter with lookup tables, pattern matching on variants,
> and boxed values. A compile path could emit a tighter binary. But:
>
> - **No caller has cited the need.** Stdlib-as-blueprint discipline
>   (wat-rs `docs/CONVENTIONS.md`): substrate ships when a real consumer
>   demands it. This one has none.
> - **The INTERPRET path's performance profile is sufficient** for every
>   workload that's been tried — DDoS line-rate packet inspection, the
>   trading lab's 100k-candle benchmarks, arc 007's self-hosted testing
>   loop. Arc 001's L1/L2 caching, arc 003's TCO trampoline, arc 004's
>   bounded-queue streams, the zero-Mutex concurrency architecture — each
>   closed a specific performance concern.
> - **If a caller does surface**, the wat-vm's established pipeline (parse
>   → resolve → check → freeze → interpret) has the structure a source-to-
>   source compiler would reuse. The sketch below stays honest about the
>   shape, so that work is recoverable.
>
> **What to read instead.**
> - For Rust-interop: `RUST-INTERPRETATION.md` on the INTERPRET path +
>   wat-rs's `docs/arc/2026/04/002-rust-interop-macro/` for `:rust::*` +
>   `#[wat_dispatch]` as they actually shipped.
> - For performance discipline: wat-rs's `docs/ZERO-MUTEX.md`.
>
> The sketch below remains unchanged from its 2026-04 original for anyone
> who wants the framing.
>
> ---

**Purpose:** conceptual sketch. A Rust program (the wat-to-rust compiler) consumes wat source and emits Rust source. Rustc compiles that Rust to a binary. The resulting binary is a wat program running at native speed with no interpreter overhead.

**Status:** ~~seed document. Here to get the idea on disk. Iterate.~~ RETIRED (see banner above).

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

A wat call to `(:wat::algebra::Bind x y)` emits a direct call into the `holon-rs` primitives:

```scheme
  ;; wat
  (:wat::algebra::Bind
    (:wat::algebra::Atom :open-price)
    (:wat::algebra::Thermometer (:wat::std::get c :open) 0 100000))
```

```rust
// emitted Rust
holon::kernel::primitives::bind(
    vm.atom_vector(&Atom::Keyword("open-price")),
    scalar_encoder.thermometer(get(c, "open"), 0.0, 100_000.0),
)
```

No interpreter dispatch, no symbol-table lookup, no HolonAST enum match. The `:wat::core::` forms expand inline; the `:wat::algebra::` forms become direct Rust function calls.

### Kernel primitives — crossbeam + std::thread + wat-vm runtime

```scheme
(:wat::kernel::make-bounded-queue :Candle 1)
```

```rust
crossbeam::channel::bounded::<Candle>(1)
```

```scheme
(:wat::kernel::spawn :my::app::observer-loop candle-rx result-tx state)
```

```rust
std::thread::spawn(move || {
    my_app::observer_loop(candle_rx, result_tx, state)
})
```

```scheme
(:wat::kernel::select receivers)
```

```rust
// emitted as a crossbeam Select block over the receiver list:
{
    let mut sel = crossbeam::channel::Select::new();
    for rx in &receivers { sel.recv(rx.inner()); }
    let op = sel.select();
    let i = op.index();
    match op.recv(receivers[i].inner()) {
        Ok(v)  => (i, Some(v)),
        Err(_) => (i, None),
    }
}
```

```scheme
(:wat::kernel::HandlePool::new "cache" handles)
(:wat::kernel::HandlePool::pop pool)
(:wat::kernel::HandlePool::finish pool)
```

```rust
// HandlePool<T> ships in the runtime support crate — the compiler
// emits direct calls to it. The runtime crate is linked into every
// compiled wat binary.
watvm_runtime::HandlePool::new("cache", handles)
pool.pop()
pool.finish()
```

The `signals` parameter the kernel passes to `:user::main` is populated by an OS-signal handler installed at startup:

```rust
// emitted as part of the main shim — not visible in wat source:
static SIGNALS_TX: OnceCell<QueueSender<Signal>> = OnceCell::new();

extern "C" fn handler(sig: libc::c_int) {
    let s = match sig {
        libc::SIGINT  => Signal::SIGINT,
        libc::SIGTERM => Signal::SIGTERM,
        _ => return,
    };
    if let Some(tx) = SIGNALS_TX.get() { let _ = tx.send(s); }
}

fn main() {
    let (stdin_rx, stdout_tx, stderr_tx) = watvm_runtime::stdio();
    let (signals_tx, signals_rx) = crossbeam::channel::unbounded::<Signal>();
    SIGNALS_TX.set(signals_tx).unwrap();
    unsafe {
        libc::signal(libc::SIGINT,  handler as _);
        libc::signal(libc::SIGTERM, handler as _);
    }
    user::main(stdin_rx, stdout_tx, stderr_tx, signals_rx);
}
```

Kernel primitives are a thin wrapper over `std` + `crossbeam` + a small `watvm_runtime` support crate (HandlePool, stdio bootstrap, signal shim). The emitted Rust looks like what a human would write.

### Stdlib macros — already compiled at parse

By the time the wat-to-rust compiler sees the AST, `defmacro` expansion has already run (same startup pipeline as the interpret path). `(:wat::std::Subtract a b)` has already become `(:wat::algebra::Blend a b 1 -1)` in the AST. The compiler never sees macro aliases; it only emits calls to core forms.

### User `define`s — Rust functions

```scheme
(:wat::core::define (:my::app::process (c :Candle) -> :holon::HolonAST)
  (:wat::algebra::Bind
    (:wat::algebra::Atom :open-price)
    (:wat::algebra::Thermometer (:wat::std::get c :open) 0 100000)))
```

```rust
pub fn process(c: &Candle) -> Holon {
    holon::kernel::primitives::bind(
        vm.atom_vector(&Atom::Keyword("open-price")),
        scalar_encoder.thermometer(get(c, "open"), 0.0, 100_000.0),
    )
}
```

Keyword path → Rust module + function name. `:my::app::process` becomes `my_app::process`. `:wat::std::HashMap` is the user-facing name for a type that in Rust is `std::collections::HashMap`; the compiler knows the mapping.

### Types — Rust structs / enums / aliases

```scheme
(:wat::core::struct Candle [open : :f64] [high : :f64] [low : :f64] [close : :f64])
```

```rust
pub struct Candle {
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
}
```

The four `:wat::core::` type-declaration forms (`struct`, `enum`, `newtype`, `typealias`) map to the obvious Rust form. Keyword types (`:f64`, `:i64`, `:bool`) are already the Rust primitive names — no translation needed.

---

## Programs Are Userland — Implementation Language Is Free

FOUNDATION's "Programs are userland" section names the conformance contract: a program is any function that (1) is named by keyword path in the static symbol table, (2) takes its handles as parameters, (3) returns final state as its return value, (4) observes the drop cascade, (5) does not create self-pipes, (6) uses `:wat::kernel::HandlePool` for any client handles it exposes.

The compile path makes this orthogonality concrete. Three ways a program enters the binary:

### Path A — wat-authored, compiled

A wat `define` becomes a Rust `pub fn` per "What the Compiler Emits" above. The emitted source goes into `src/<module>.rs`; rustc includes it in the binary.

### Path B — wat-authored, interpreted

Same `define`, but the wat-vm loads the AST at startup and walks it at call time. The interpret path. No compilation step. Useful for development; the compile path is the production-tier.

### Path C — Rust-authored, registered by keyword path

The trading lab's `market_observer_program`, `regime_observer_program`, `broker_program`, `treasury_program` are hand-written Rust. They conform to the six rules. They get registered with keyword paths at startup:

```rust
// in the app's startup manifest — linked into the binary:
watvm_runtime::register_program(
    KeywordPath::parse(":project::trading::program/MarketObserver"),
    Arc::new(|args| {
        // argument unpacking + cast to typed signature
        let (rx, tx, cache, vm, scalar, console, db, obs, i, ri) = unpack(args);
        market_observer_program(rx, tx, cache, vm, scalar, console, db, obs, i, ri)
    }),
);
```

The wat-vm — both interpreter and compiler — sees `:project::trading::program/MarketObserver` in the symbol table. A wat call to `(:wat::kernel::spawn :project::trading::program/MarketObserver ...)` dispatches into the Rust function on either path. The compile path emits a direct call; the interpret path invokes the registered function pointer.

### What this means for `:wat::std::program::Console` and `:wat::std::program::Cache`

The two stdlib programs are Path-C programs that happen to live in the runtime support crate:

```rust
// watvm_runtime/src/programs.rs — ships with the compiler and linker:
pub fn console_program(output: QueueSender<String>, num_producers: usize) 
    -> (HandlePool<ConsoleHandle>, ConsoleDriver) { ... }

pub fn cache_program<K, V>(
    name: &str,
    capacity: usize,
    num_clients: usize,
    can_emit: Box<dyn Fn() -> bool + Send>,
    emit: Box<dyn Fn(CacheStats) + Send>,
) -> (HandlePool<CacheHandle<K, V>>, CacheDriver) { ... }
```

Compile-path emission for these calls is a direct call into the runtime crate. The interpret path looks them up in the kernel-registered program table. Users authoring new stdlib programs would do the same: write Rust in a sibling crate, register the keyword path, share the compilation output.

### What this means for `Database`, `telemetry`, `rate-gate`

All three are **userland**. An app that wants them ships them itself:

- Trading lab: `src/programs/stdlib/database.rs`, `src/programs/telemetry.rs`. Registered under `:project::trading::program/Database`, `:project::trading::telemetry/emit-metric`, `:project::trading::rate-gate`. The names are the app's choice, not the wat-vm's.
- Another app (say, a DDoS detector): probably wants different schemas, different telemetry format, maybe no database at all. Ships its own programs under `:ddos-lab::program/...`.

The wat-vm does not ship Database. Does not ship a telemetry format. Does not ship a rate gate. Apps supply those, Rust-authored or wat-authored, registered by keyword path.

---

## Bootstrap — wat-vm in wat

If the compile path works, the wat-vm's orchestration layer can be written in wat. Today's `src/bin/wat-vm.rs` (≈840 lines) — the counting, pooling, wiring, candle-stream loop, shutdown cascade — is all keyword-path-dispatched calls and queue management. Expressible as a wat `:user::main`.

Run `wat-to-rust` on that wat source. Get Rust source. Combine with the runtime support crate (Console/Cache/HandlePool/stdio/signals), the algebra primitives from `holon-rs`, and the app's Rust-authored programs (Market Observer, etc.). Compile with rustc. The resulting binary behaves identically to today's hand-written trading lab. Self-hosting at the orchestration tier.

**What stays hand-written Rust:**
- `holon-rs` algebra primitives (the bind/bundle/permute/threshold kernel).
- `watvm_runtime` support (HandlePool, stdio bootstrap, signal shim, Console program, Cache program).
- `wat-to-rust` (the compiler itself).
- App-specific performance-critical programs (Market Observer, etc.) — until an author chooses to re-express them in wat.

**What moves up into wat:**
- `:user::main` for every app — counting, wiring, spawn, shutdown cascade.
- App-specific userland macros and functions.
- New stdlib macros (Subtract, Chain, HashMap, etc.) authored in wat.
- Experimental program graphs — authors prototype in wat, migrate to Rust if they need the performance.

The line between hand-written Rust and wat moves over time as authors choose. Nothing forces the migration; the six-rule contract is all that's required.

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
- **Dynamic eval is lost in the compiled binary.** The interpret path supports `(:wat::kernel::eval ast)` against the static symbol table. A compiled binary has no interpreter available — eval either goes away in the compiled form (compile-time pragma disables it) or the binary links in a mini-interpreter for eval calls only (choose per deployment).
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

- **A concrete translation table** — every `:wat::core::`, `:wat::algebra::`, `:wat::std::`, `:wat::kernel::` form mapped to its Rust emission template. When complete, this becomes `WAT-TO-RUST-EMISSION.md` (a reference like `RUST-INTERPRETATION.md`).
- **A worked example** — re-expressing one trading lab module (say, the market observer) as wat, showing the emitted Rust side-by-side with the hand-written Rust. Motivating evidence that the bootstrap works.
- **Integration with the wat-vm frontend** — once the shared crate idea firms up, this document references it by name.

Iterate.

---

*the machine compiles itself.*
