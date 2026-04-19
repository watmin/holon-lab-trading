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
`match` live.** wat-rs ships the full startup pipeline, 30+ threads with
zero Mutex, real Ed25519 crypto at `signed-load!` / `eval-signed!`,
parametric `:Atom<T>`, the six algebra-core forms, `:wat::core::quote` /
`:wat::core::atom-value` / `:wat::core::let*` / `:wat::core::presence`,
config-committed `noise_floor`, `EncodingCtx` attached at freeze,
`:Option<T>` with `:None` / `(Some _)` constructors,
`(:wat::core::match ...)` with exhaustiveness, and `recv` upgraded to
`:Option<String>`. The vector-level proof runs end-to-end:

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

### Step 1 — kernel primitives (full 8 of 8)

- [ ] typed pipe values over arbitrary `T`
- [ ] `make-bounded-queue` / `make-unbounded-queue`
- [ ] `spawn` (for wat-authored functions)
- [ ] `try-recv` / `select` / `drop` / `join`
- [ ] `HandlePool`
- [ ] `Signal` enum + signals queue + `:user::main` fourth parameter

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
