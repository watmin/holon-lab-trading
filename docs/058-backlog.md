# 058 Backlog — Post-Presence-Proof

**Status:** Living. Each work unit that grows beyond a line or two spawns
its own backlog document.

**Spec source:**
`docs/proposals/2026/04/058-ast-algebra-surface/`
— FOUNDATION.md, VISION.md, FOUNDATION-CHANGELOG.md.

**Prior backlog:** `docs/archive/058-backlog.md` — Tracks 0/1/2 through
Phase 1 completion (2026-04-19 morning).

---

## Where we are

**Phase 1 complete; programs-as-holons operational.** wat-rs ships the
full startup pipeline, 30+ threads with zero Mutex, real Ed25519 crypto
at `signed-load!` / `eval-signed!`, parametric `:Atom<T>`, the six
algebra-core forms, `:wat::core::quote` / `:wat::core::atom-value` /
`:wat::core::let*` / `:wat::core::presence`, config-committed
`noise_floor`, `EncodingCtx` attached at freeze. The vector-level
proof runs end-to-end:

```
$ echo watmin | wat-vm presence-proof.wat
None
Some
watmin
```

372 tests green; zero warnings.

---

## Why this backlog exists

The 058 spec describes a language broader than wat-rs currently
implements. The gap is the runtime surface users need to write
trading-lab-class programs — specifically, concurrent programs that
compose drivers. Closing that gap is what this backlog tracks.

**Direction settled in conversation (2026-04-19 afternoon):**

- **wat is the primary language.** Both application programs AND
  drivers are expressed in wat source.
- **Drivers are a kind of wat program** — ones that own resources,
  expose pipe-based protocols, run on their own thread.
- **wat-to-rust compiles drivers into Rust artifacts** for FFI. The
  compile path serves driver production, not deployment of the whole
  program — applications keep running through the wat-vm interpreter.
- **Hand-written Rust drivers are the escape hatch** — when wat can't
  express a foreign resource (SQLite bindings, raw OS I/O), the user
  writes Rust directly. Same calling convention as a wat-to-rust
  compiled driver; callers can't tell the difference.
- **wat programs invoke drivers by keyword path over pipe pairs.**
  The ABI is the pipe protocol. The callee's origin (wat-compiled or
  hand-written Rust) is hidden.

Before designing the driver model in detail, we build out the rest of
the spec'd substrate. The driver model sub-proposals come after —
informed by running the stdlib through the kernel primitives.

---

## The queue (in order)

### Step 0 — retrofit inventory

Survey 058 against wat-rs. Produce a prioritized list with dependency
ordering. This document is the inventory's opening summary; detailed
per-form coverage lives in the step backlogs below as each spawns.

- [x] This document written (2026-04-19).
- [ ] Append a per-form status table below as implementation proceeds.

### Step 1 — kernel primitives (full 8 of 8)

FOUNDATION specifies eight kernel primitives. wat-rs ships three
(`stopped`, `send`, `recv`). Remaining: `spawn`, `select`, `try-recv`,
`drop`, `join`, `make-bounded-queue`, `make-unbounded-queue`, plus
`HandlePool` as a supporting structure.

Typed pipe values need to be generalized — currently wat-rs has
`Value::crossbeam_channel__Sender<String>` / `Receiver<String>` hard-coded
for stdio; the driver model needs pipes over arbitrary `T`.

Spawns off: `docs/backlog-kernel-primitives.md` when this step starts.

- [ ] Typed pipe values over arbitrary T
- [ ] `(:wat::kernel::make-bounded-queue :carries :T :capacity N)`
- [ ] `(:wat::kernel::make-unbounded-queue :carries :T)`
- [ ] `(:wat::kernel::spawn <fn> <args>)` — for wat-authored functions
  initially; driver-spawn arrives in Step 6
- [ ] `(:wat::kernel::try-recv rx)`
- [ ] `(:wat::kernel::select (rxs...))`
- [ ] `(:wat::kernel::drop handle)`
- [ ] `(:wat::kernel::join handle)`
- [ ] `:wat::kernel::HandlePool` — the deadlock-guarding bulk handle
  allocator
- [ ] `:wat::kernel::Signal` enum + signals queue + `:user::main`'s
  fourth parameter (spec'd but not implemented)

### Step 2 — `:Option<T>` + `match` form

FOUNDATION treats `:Option<T>` as a needed runtime primitive; Phase 1
deferred it. Unblocks:

- Graceful `recv` EOF (recv returns `:Option<T>`; `:None` on disconnect
  replaces `ChannelDisconnected`)
- `match` destructuring, which subsequently unblocks user-defined enum
  destructuring end-to-end
- Stdlib forms that want `maybe-X` ergonomics

Spawns off: `docs/backlog-option-match.md` when this step starts.

- [ ] `Value::Option<Value>` + Some/None constructors
- [ ] `(:wat::core::match ...)` form with exhaustiveness check
- [ ] `recv` returns `:Option<T>` (migration of all existing callers)
- [ ] `try-recv` returns `:Option<T>`

### Step 3 — stdlib algebra macros

Spec'd in 058-001..020 (accepted subset). Each is a `defmacro` that
expands to algebra-core compositions. Implementation = wire them into
the frozen macro registry at startup.

Spawns off: `docs/backlog-stdlib-algebra.md` when this step starts.

- [ ] `Sequential`, `Bigram`, `Trigram`, `Ngram` (058-009/013)
- [ ] `Linear` (058-008)
- [ ] `Log` (058-017)
- [ ] `Circular` (058-018)
- [ ] `Amplify` (058-015)
- [ ] `Subtract` (058-019)
- [ ] `Reject`, `Project` (the Gram-Schmidt pair — from 058-005's
  reframe)

### Step 4 — stdlib data structures + list combinators

FOUNDATION's structural retrieval regime. `HashMap`, `Vec`, `HashSet`
with `get`, `nth`, `member?` — plus the list combinators (`map`,
`filter`, `fold`, `pairwise-map`, `n-wise-split`, etc.). These are the
backing for most real userland programs.

Spawns off: `docs/backlog-stdlib-data.md` when this step starts.

- [ ] `:wat::std::HashMap<K,V>` + `get` / `contains?`
- [ ] `:wat::std::Vec<T>` + `nth` / `length`
- [ ] `:wat::std::HashSet<T>` + `member?`
- [ ] List combinators: `map`, `filter`, `fold`, `reduce`, `range`,
  `take`, `drop`, `reverse`, `pairwise-map`, `n-wise-split`, `zip`

### Step 5 — stdlib programs (Console + Cache)

FOUNDATION's two stdlib-exception programs. The trading lab already has
the Rust implementations (`src/programs/stdlib/console.rs`,
`cache.rs`). This step ports them to register with the wat-vm runtime
so wat source can invoke `(:wat::kernel::spawn
:wat::std::program::Console ...)` — which is the first real test of
the driver pattern with Rust-authored drivers, even before wat-to-rust
lands.

Spawns off: `docs/backlog-stdlib-programs.md` when this step starts.

- [ ] Driver registry: `Rust fn + keyword path → spawn target`.
  Registered at wat-vm startup before freeze.
- [ ] Typed pipe-value machinery complete enough to hold `CacheRequest`,
  `CacheResponse`, `Vec<T>` for arbitrary T.
- [ ] `:wat::std::program::Console` registered at wat-vm startup.
- [ ] `:wat::std::program::Cache<K,V>` registered at wat-vm startup.
- [ ] Hello-world that uses `Console` to serialize stdout writes across
  multiple worker threads — a trading-lab-shaped toy.

### Step 6 — driver model proposal (058 growth)

With Steps 1-5 shipped, the substrate has enough surface to design
drivers honestly. New sub-proposals within 058:

- `058-033-driver-registry` (or similar) — Rust programs invokable by
  keyword path; same ABI whether compiled from wat or hand-written in
  Rust.
- `058-034-ffi-declare` — the wat-source syntax for declaring foreign
  Rust symbols a driver imports. Example:
  `(:wat::ffi::declare "rusqlite::Connection::execute" ...)`.
- `058-035-wat-to-rust-drivers` — scope the compile path to driver
  production. `wat-to-rust <driver.wat> → <driver.rs>`, linked into the
  wat-vm binary or a sidecar crate.

Designer review (Hickey + Beckman) on these three as a batch.

Spawns off: its own sub-proposals + implementation backlogs after
review.

### Step 7 — end-to-end trading-lab-class example

A real userland program that:

- Spawns a wat-to-rust compiled database driver (or hand-written
  Rust driver as interim)
- Spawns `Console` and `Cache` stdlib programs
- Runs multiple concurrent worker programs over pipes
- Shuts down cleanly via cascade

Proves the full stack. Probably lands in its own repo, consuming wat
as a dependency.

Not in this backlog. Called out here to make the arc visible.

---

## Things that are NOT in this backlog

- **Compile path for deploying full programs as binaries.** Re-examined;
  not needed. The compile path exists to produce DRIVERS; applications
  keep interpreting through wat-vm.
- **A 059 proposal batch.** 058 IS the language spec; it grows. New
  sub-proposals slot into 058.

---

## How this document evolves

When a step starts: spawn a dedicated backlog — `docs/backlog-<step>.md`
— with the slice-level breakdown. This document's step-level checkboxes
reference the dedicated backlog. When the step completes: mark it and
archive the dedicated backlog to `docs/archive/`.

When 058 grows a new sub-proposal (Step 6's driver model, or anything
else): that's a proposal-corpus change, not a backlog change. The
backlog references the new sub-proposal by number.

When the whole backlog is complete: archive this document to
`docs/archive/058-backlog-post-presence-proof.md` (or similar dated
name) and write a fresh one for whatever's next.
