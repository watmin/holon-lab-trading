# lab arc 029 — RunDb service (multi-run-name; CSP shape)

**Status:** opened 2026-04-25.
**Predecessor arc:** [`docs/arc/2026/04/027-rundb-shim/`](../027-rundb-shim/DESIGN.md) (closed 2026-04-25).
**Consumer:** [`docs/proofs/2026/04/003-thinker-significance/PROOF.md`](../../proofs/2026/04/003-thinker-significance/PROOF.md).

Builder direction (2026-04-25), after I tried to hack 10
sequential `:lab::rundb::open` calls into proof 003:

> "hold on - we need a db service for this... go study the
> archived rust and wat's service pattern (console service,
> cache service)"

Right call. Arc 027 shipped the minimum-viable shim — one
`run_name` baked into the handle at open. That's a thread-owned
struct with method calls; pre-service-pattern thinking. It works
for one-window proofs (002), wedges for multi-window proofs
(003), and won't scale to the multi-thread futures (post per
asset, broker per N×M).

This arc fixes the shape.

Cross-references:
- [`archived/pre-wat-native/src/programs/stdlib/database.rs`](../../../../archived/pre-wat-native/src/programs/stdlib/database.rs) — 627-LOC archive predecessor. Generic batched SQLite writer behind a driver thread, per-client req/ack queues, gate-controlled telemetry. This arc ships *less* — no batching, no telemetry gate — but mirrors the lifecycle (drop cascade → final flush → driver exit). Future sibling arc adds batching when a hot-path caller surfaces.
- `wat-rs/wat/std/service/Console.wat` — fire-and-forget service template (one driver, N clients, tagged messages). Closest match for the rundb service: every log is a side-effect with no reply needed.
- `wat-rs/crates/wat-lru/wat/lru/CacheService.wat` — query-style service template (per-message reply channel). Reference, not template — the rundb service doesn't need replies.
- `feedback_query_db_not_tail` — "no grepping; SQL on the run DB."
- `feedback_capability_carrier` — new capabilities should attach to existing carriers; `RunDb` shim already exists, so the wat service builds on top rather than carving a new slot.
- [Slice-by-slice plan: `BACKLOG.md`](BACKLOG.md).

---

## Why this arc, why now

Proof 003 needs **10 different run_names per database** so that
per-window slicing is `GROUP BY run_name`. The arc-027 shim
binds run_name at open; the only honest path with that shape is
"open 10 connections to the same file." That works mechanically
but it's an architectural lie — we already know the right shape
from the archived Rust (one connection, many writers) and from
the wat service templates (driver thread + clients).

The wat substrate has matured since arc 027: `:wat::kernel::select`,
`HandlePool`, `ProgramHandle`, `make-bounded-queue`, `spawn` —
all in production via Console + CacheService. The
rundb-as-service shape is now expressible in ~140 LOC of wat. A
month ago it would have required a Rust-side mini-service.
Today it's a wat program.

This arc closes the shape gap before any more proofs build on
the wrong abstraction.

---

## What ships

Two surfaces.

### Refactored shim (`src/shims.rs` + `wat/io/RunDb.wat`)

`run_name` moves out of the `WatRunDb` struct's state and onto
`log_paper`'s parameter list. Schema unchanged.

```rust
pub struct WatRunDb {
    conn: Connection,
    // run_name removed — was: run_name: String
}

pub fn open(path: String) -> Self;     // ← drops run_name arg

pub fn log_paper(
    &mut self,
    run_name: String,                  // ← new first param
    thinker: String, predictor: String,
    paper_id: i64, direction: String,
    opened_at: i64, resolved_at: i64,
    state: String, residue: f64, loss: f64,
);
```

```scheme
(:lab::rundb::open path) -> :lab::rundb::RunDb
(:lab::rundb::log-paper db run-name thinker predictor paper-id ...) -> :()
```

### New wat service (`wat/io/RunDbService.wat`)

Fire-and-forget driver loop. One thread owns one `RunDb`
connection. N clients each get a `Sender<Resolution>` handle.
Each Resolution is a 10-tuple carrying the full row payload
(run_name included). Drop cascade closes the connection
cleanly.

```scheme
(:wat::core::typealias :lab::rundb::Service::Resolution
  :(String,String,String,i64,String,i64,i64,String,f64,f64))

;; Setup: spawns the driver, returns (HandlePool, ProgramHandle).
(:lab::rundb::Service path count)
  -> :(HandlePool<Service::Tx>, ProgramHandle<()>)

;; Client helper: fire-and-forget, swallows :None on disconnect.
(:lab::rundb::Service/log handle
  run-name thinker predictor paper-id direction
  opened-at resolved-at state residue loss)
  -> :()
```

Lifecycle mirrors Console + CacheService: caller spawns the
service, pops handles, distributes, calls `HandlePool::finish`,
clients log via `Service/log`, handles drop, driver's last `Rx`
disconnects, loop exits, connection drops, `(join driver)`
confirms clean exit.

---

## Decisions resolved

### Q1 — Why refactor instead of building service over today's shim?

The today's shim wedges `run_name` into the struct. To preserve
that across a service, every `Service::Tx` would need its own
`RunDb` handle (one per run_name) — meaning the driver opens N
connections and routes each request to the right one. That
multiplies file handles, complicates lifecycle, and doesn't
match how the archived `database.rs` worked (one connection,
per-message routing).

The honest fix is the smaller change: drop the struct field,
move it to a parameter. ~5-LOC delta in Rust. Proof 002 (the
only existing consumer) costs ~6 lines of wat to migrate. The
service then becomes a clean wat program with a single
underlying connection.

### Q2 — Why fire-and-forget (Console pattern), not request/reply (CacheService pattern)?

Logging has no return value worth waiting for. The caller knows
"I logged a row"; rusqlite either succeeded (the row's there)
or panicked (the test crashes loudly with a diagnostic).
Adding a per-message reply channel would introduce blocking
semantics that callers don't actually want — every `log` call
would wait for the driver to ack, serializing client throughput
behind driver latency.

Console solves the same write-only problem; copy its shape.

The trade: clients can't observe write failures. v1 accepts
that — `feedback_shim_panic_vs_option` says construction errors
panic with diagnostic, and write failures land as panics from
the driver thread (which surface as test failures via
`(:wat::kernel::join driver)`). Future arc adds a Result-typed
variant if a caller wants graceful per-row error handling.

### Q3 — Why no batching?

The archived `database.rs` batched writes for throughput: 627
LOC of accumulator state, transaction wrappers, telemetry
gates. That mattered when the trader logged thousands of rows
per second.

The current write volume is ~340 inserts per proof. SQLite's
auto-commit (one transaction per statement) handles that
without breaking a sweat. Adding batching now would be premature
optimization that obscures the lifecycle contract.

A future arc adds batching the day a hot-path consumer surfaces
(per-broker logging in the multi-asset enterprise; tick-by-tick
trace logs).

### Q4 — Why open `RunDb` inside the driver thread, not in setup?

The shim is `scope = "thread_owned"` (per arc 027). A
`Connection` opened in thread A and passed to thread B trips
the thread-id guard at first use → panic.

CacheService solved the same problem with `LocalCache::new`
inside the driver. RunDbService follows: `Service/loop-entry`
takes a `path` (a `Send` String), opens the connection inside
itself, then enters the recursive select loop. Setup never
touches a `RunDb`.

### Q5 — One service per database file, or multiplexed?

**One service, one path.** Multiplexing would require the
driver to hold N connections (one per path) and route by path —
adding a routing dimension that the lifecycle (drop cascade)
doesn't naturally express.

A program that needs two databases spawns two services. They're
cheap (one thread + one bounded queue per client). Each manages
its own lifecycle independently.

### Q6 — Schema migrations?

**None.** Same as arc 027. The `CREATE TABLE IF NOT EXISTS` at
`open` time handles fresh DBs; the schema is unchanged from arc
027 (`run_name` was always a column — only its source
changed).

### Q7 — Why expose both raw shim AND service?

Single-threaded callers (proof 002) shouldn't be forced through
a thread + queue + select loop just to log 34 rows. The raw
shim stays available for the synchronous, single-thread case.

The service is for callers that need either (a) per-message
run_name (proof 003), (b) multiple clients sharing one
database (future multi-broker proofs), or (c) decoupling
client write latency from driver write latency. The decision
of which to use is up to the caller.

This isn't a layering compromise — both shapes are first-class.
The shim is the resource; the service is a CSP wrapper that
adds one capability (run_name routing) and one architectural
guarantee (mutex-free multi-writer lifecycle).

---

## Implementation sketch

Three slices, tracked in [`BACKLOG.md`](BACKLOG.md):

- **Slice 1** — refactor `WatRunDb` (Rust + wat surface). Update
  proof 002's pair file and verify it produces the same numbers
  as the shipped run.
- **Slice 2** — build `:lab::rundb::Service` as a wat program in
  `wat/io/RunDbService.wat`. Three smoke tests at
  `wat-tests/io/RunDbService.wat`. Wire into the shim's
  `wat_sources()`.
- **Slice 3** — INSCRIPTION.md + flip
  `docs/proofs/2026/04/003-thinker-significance/PROOF.md` from
  BLOCKED to ready.

Total estimate: ~3 hours of focused work. Same shape as arc 027
(~half a day) with a slightly heavier wat surface because of the
service ceremony (HandlePool / spawn / select).

---

## What this arc does NOT add

- **Batching.** Out of scope. Future arc when a hot-path caller surfaces.
- **Telemetry / gate-pattern emit callbacks.** Same.
- **Read-side query APIs.** Still out of scope per arc 027. Use the `sqlite3` CLI.
- **WAL mode pragma.** rusqlite default rollback journal is fine.
- **Multi-database support per service.** One service, one path; spawn two services if you need two paths.
- **Schema migrations.** Defer until needed.
- **Result-typed write errors.** Future arc when a caller surfaces graceful failure handling.
- **A wat-rusqlite sibling crate.** Phase 7 work.

---

## What this unblocks

- **Proof 003** — flips from BLOCKED to ready. Multi-window
  thinker comparison across the 6-year stream becomes a clean
  service-based supporting program.
- **Proof 004** — full 6-year stream. Same service, single
  client; service is "overkill" but the shape works at any
  scale and any client count.
- **Future proof N — multi-thread per-broker logging.** Each
  broker holds its own `Service::Tx`; the driver serializes
  writes. The pattern stays the same regardless of client
  count.
- **Phase 7's eventual `wat-rusqlite` crate** has a working
  reference Service shape to either inherit or supersede.

PERSEVERARE.
