# 058 Backlog — Post-Presence-Proof

**Status:** Living. The high-level sequence only. Per-step detail
tracking lives in the task runner during implementation, in commit
messages as slices land, and in the 058 proposal corpus for
spec-level changes.

**Spec source:**
`docs/proposals/2026/04/058-ast-algebra-surface/`
— FOUNDATION.md, VISION.md, FOUNDATION-CHANGELOG.md.

**Prior backlog:** `archived/058-backlog.md` — Tracks 0/1/2 through
Phase 1 completion (2026-04-19 morning).

---

## Where we are

**Phase 1 complete; programs-as-holons operational; `:Option<T>` +
`match` live; kernel surface complete.** wat-rs ships the full startup
pipeline, real Ed25519 crypto at `signed-load!` / `eval-signed!`,
parametric `:Atom<T>`, the six algebra-core forms, `:wat::core::quote` /
`:wat::core::atom-value` / `:wat::core::let*` / `:wat::algebra::cosine` / `:wat::algebra::presence?`,
config-committed `noise_floor`, `EncodingCtx` attached at freeze,
`:Option<T>` with `:None` / `(Some _)` constructors,
`(:wat::core::match ...)` with exhaustiveness, `recv` / `try-recv` /
`select` returning `:Option<T>`, typed pipe values, tuples +
destructuring, `make-bounded-queue` / `make-unbounded-queue`, `spawn` /
`join` on a Mutex-free `:ProgramHandle<R>`, `HandlePool` with
claim-or-panic, the per-signal poll/reset primitives for SIGUSR1 /
SIGUSR2 / SIGHUP, the full stdlib algebra macros (Amplify, Subtract,
Log, Circular, Reject, Project, Sequential, Bigram, Trigram, Ngram)
plus Round 4a list primitives (list, map, length, empty?, reverse,
range, take, drop, foldl, first/second/third polymorphic over Vec +
tuple, rest, std::list::window, std::list::map-with-index), and the
naming-convention sweep (`stopped?`, `cosine`, `presence?`). **453+
tests green; zero warnings; zero Mutex.** The vector-level proof
runs end-to-end:

```
$ echo watmin | wat-vm presence-proof.wat
None
Some
watmin
```

---

## Direction

Settled in conversation 2026-04-19 afternoon:

- **wat is the primary language.** Both application programs AND
  drivers are expressed in wat source.
- **Drivers are a kind of wat program** — ones that own resources,
  expose pipe-based protocols, run on their own thread.
- **wat-to-rust compiles drivers into Rust artifacts** for FFI. The
  compile path serves driver production, not deployment of the whole
  program — applications keep running through the wat-vm interpreter.
- **Hand-written Rust drivers are the escape hatch** — when wat can't
  express a foreign resource (SQLite bindings, raw OS I/O), the user
  writes Rust directly. Same calling convention; callers don't know
  the difference.
- **058 is the language spec; it grows.** No 059. New sub-proposals
  slot into 058.

The driver model gets designed after the kernel / stdlib layers land,
informed by running real programs through them.

---

## The sequence

### Step 1 — kernel primitives (full surface) — DONE (2026-04-19)

- [x] typed pipe values over arbitrary `T`
- [x] `make-bounded-queue` / `make-unbounded-queue`
- [x] `spawn` (for wat-authored functions) + `join`
- [x] `try-recv` / `select` / `drop`
- [x] `HandlePool` (channel-backed, Mutex-free)
- [x] user-signal surface: `sigusr1?` / `reset-sigusr1!` / `sigusr2?` /
  `reset-sigusr2!` / `sighup?` / `reset-sighup!` — kernel maintains
  boolean state, userland polls + resets. Terminal signals (SIGINT /
  SIGTERM) stay on the existing `stopped` flag. No signals queue; no
  4th `:user::main` parameter.

Known deviations from spec, tracked separately:
- `select`'s index is `:i64`, not `:usize` — `:usize` value variant
  lands when a caller needs it.
- `(drop)` is a scope-based close marker: the Arc reference dropped
  inside the primitive is one of several; full channel-end close
  happens when the enclosing let-scope releases its binding.

### Step 1.5 — naming-convention sweep — DONE (2026-04-19)

- [x] renamed `(:wat::kernel::stopped)` → `(:wat::kernel::stopped?)`
- [x] split `(:wat::core::presence target ref)` (`:f64`) into
  `(:wat::algebra::cosine target ref)` (`:f64`) and
  `(:wat::algebra::presence? target ref)` (`:bool`, cosine vs
  committed noise floor). Both live at `:wat::algebra::*` per
  OPEN-QUESTIONS line 419. `:wat::std::math::*` stays for raw-number
  utilities only (`ln`, `sin`, `cos` of an angle, `pi`).
- [x] audit pass: no other bare form is a semantic predicate needing
  `?`. Comparison operators (`=`, `<`, `>`, `<=`, `>=`) stay bare by
  Lisp convention (operators, not predicates). `empty?` and the
  sigusr/reset primitives already shipped conforming.

### Step 2 — `:Option<T>` + `match` — PARTIAL (out-of-order, 2026-04-19)

Done ahead of Step 1 because every kernel primitive with an `:Option<T>`
return needs the runtime first. `try-recv` / `select` land in Step 1
already spec-shaped.

- [x] `Value::Option<Value>` + `Some` / `None` constructors
- [x] `(:wat::core::match ...)` with exhaustiveness check
- [x] `recv` returns `:Option<T>` (`:None` on disconnect)
- [ ] `try-recv` returns `:Option<T>` (lands with Step 1's try-recv)

### Step 3 — stdlib algebra macros — DONE (2026-04-19)

- [x] `Amplify` / `Subtract` (round 1)
- [x] `Log` / `Circular` (round 2 — needed `:wat::std::math::{ln,sin,cos,pi}`
  and the typed-arith split into `:wat::core::{i64,f64}::*`)
- [x] `Reject` / `Project` (round 3 — needed `:wat::algebra::dot` primitive)
- [x] `Sequential` / `Bigram` / `Trigram` / `Ngram` (round 4 — needed
  core list primitives + `:wat::std::list::{window,map-with-index}` +
  `first`/`second`/`third` polymorphic over Vec and tuple)

`Linear` is REJECTED (058-008; identical to Thermometer under the
3-arity signature). Does not ship.

### Step 4 — stdlib data structures + list combinators

**Round 4a — DONE (2026-04-19). Minimum set that unblocked Step 3.**

At `:wat::core::*`:
- [x] `list` — Lisp-y constructor alias of `vec`.
- [x] `map` — `Vec<T>, fn(T)→U → Vec<U>`
- [x] `length`, `empty?`, `reverse`
- [x] `range` — two-arg `(range start end) → Vec<i64>`
- [x] `take`, `drop`
- [x] `foldl` — canonical; no `foldr` / `fold` / `reduce` yet
- [x] `first`, `second`, `third` — polymorphic over Vec and tuple
  (per 2026-04-19 user direction: "both are index-accessed data
  structs"). Runtime error on out-of-range.
- [x] `rest` — `Vec<T>` → `Vec<T>`.

At `:wat::std::list::*`:
- [x] `window` — sliding window.
- [x] `map-with-index` — added to support Sequential's indexed fold.

**Design decisions — frozen here so compaction can't erase them:**

- **`list` vs `vec` — both legal, naming-convention distinction.**
  Runtime identical (both produce `Value::Vec<Value>`), type surface
  identical (`∀T. T* → Vec<T>`). `list` signals wat-level Lisp-y
  intent; `vec` signals data-of-T intent. The keyword chosen at the
  call site tells the reader which mental model applies.
- **`foldr` is deferred** — not needed for Sequential/Ngram. Lands
  when a concrete call site demands it.
- **`for-each`, `filter`, `reduce`, `cons`, `third`, `rest`, and the
  rest of the stdlib list combinators (`pairwise-map`, `n-wise-map`,
  `map-with-index`, `zip`, `unzip`, `take-while`, `drop-while`)
  deferred** — each lands when something wants it.

**Round 4b (later) — data structures:**
- [ ] `HashMap<K,V>` + `get` / `contains?`
- [ ] `HashSet<T>` + `member?`
- [ ] The rest of the list combinators above, as need arises.

(`Vec<T>` is the typed existing form; `:wat::core::vec` is its
constructor, already shipped. `nth` is `get` on Vec — graduates with
HashMap/HashSet's `get`.)

### Step 5 — stdlib programs (Console + Cache)

- [ ] driver registry (Rust fn + keyword path → spawn target)
- [ ] `:wat::std::program::Console` registered at wat-vm startup
- [ ] `:wat::std::program::Cache<K,V>` registered at wat-vm startup
- [ ] hello-world that uses Console to serialize stdout across workers

### Step 6 — driver model proposal (058 growth)

- [ ] sub-proposal: driver registry + invocation shape
- [ ] sub-proposal: FFI declaration syntax in wat source
- [ ] sub-proposal: wat-to-rust compile path scoped to drivers
- [ ] designer review (Hickey + Beckman)
- [ ] implementation

### Step 7 — end-to-end trading-lab-class example

- [ ] wat application using a wat-to-rust compiled database driver,
  `Console`, `Cache`, multiple concurrent worker programs, cascade
  shutdown

---

## Things that are NOT on this queue

- **Compile path for deploying full programs as binaries.** Not needed.
  Compile path exists to produce DRIVERS; applications interpret
  through wat-vm.
- **A 059 proposal batch.** 058 IS the spec; it grows.

---

When the queue empties, archive this document to `archived/` with a
dated name and open the next one for whatever arc is next.
