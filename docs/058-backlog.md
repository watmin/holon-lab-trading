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
`:wat::core::atom-value` / `:wat::core::let*` / `:wat::core::presence`,
config-committed `noise_floor`, `EncodingCtx` attached at freeze,
`:Option<T>` with `:None` / `(Some _)` constructors,
`(:wat::core::match ...)` with exhaustiveness, `recv` / `try-recv` /
`select` returning `:Option<T>`, typed pipe values, tuples +
destructuring, `make-bounded-queue` / `make-unbounded-queue`, `spawn` /
`join` on a Mutex-free `:ProgramHandle<R>`, `HandlePool` with
claim-or-panic, and the per-signal poll/reset primitives for SIGUSR1 /
SIGUSR2 / SIGHUP. 409 tests green; zero warnings; zero Mutex. The
vector-level proof runs end-to-end:

```
$ echo watmin | wat-vm presence-proof.wat
None
Some
watmin
```

372 tests green; zero warnings.

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

### Step 1.5 — naming-convention sweep (follow-up to the signal surface)

- [ ] rename `(:wat::kernel::stopped)` → `(:wat::kernel::stopped?)` to
  conform to the `?`-suffix predicate rule
- [ ] split `(:wat::core::presence target ref)` (`:f64`) into
  `(:wat::algebra::cosine target ref)` (`:f64`, the measurement) and
  `(:wat::core::presence? target ref)` (`:bool`, binarized against
  noise floor). Callers who want the exact value reach for `cosine`;
  callers who want the verdict reach for `presence?`.
- [ ] sweep other bare forms that are semantically predicates and
  rename to conform (one-pass audit)

### Step 2 — `:Option<T>` + `match` — PARTIAL (out-of-order, 2026-04-19)

Done ahead of Step 1 because every kernel primitive with an `:Option<T>`
return needs the runtime first. `try-recv` / `select` land in Step 1
already spec-shaped.

- [x] `Value::Option<Value>` + `Some` / `None` constructors
- [x] `(:wat::core::match ...)` with exhaustiveness check
- [x] `recv` returns `:Option<T>` (`:None` on disconnect)
- [ ] `try-recv` returns `:Option<T>` (lands with Step 1's try-recv)

### Step 3 — stdlib algebra macros

- [ ] `Sequential` / `Bigram` / `Trigram` / `Ngram`
- [ ] `Linear` / `Log` / `Circular`
- [ ] `Amplify` / `Subtract`
- [ ] `Reject` / `Project` (the Gram-Schmidt pair)

### Step 4 — stdlib data structures + list combinators

- [ ] `HashMap<K,V>` + `get` / `contains?`
- [ ] `Vec<T>` + `nth` / `length`
- [ ] `HashSet<T>` + `member?`
- [ ] `map` / `filter` / `fold` / `reduce` / `range` / `take` / `drop` /
  `reverse` / `pairwise-map` / `n-wise-split` / `zip`

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
