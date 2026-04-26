# lab arc 029 — RunDb service (multi-run-name; CSP shape)

**Status:** opened 2026-04-25.
**Predecessor arc:** [`docs/arc/2026/04/027-rundb-shim/`](../027-rundb-shim/DESIGN.md) (closed 2026-04-25).
**Consumer:** [`docs/proofs/2026/04/003-thinker-significance/PROOF.md`](../../proofs/2026/04/003-thinker-significance/PROOF.md).

Builder direction (2026-04-25), after I tried to hack 10
sequential `:trading::rundb::open` calls into proof 003:

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

Three surfaces.

### Refactored shim (`src/shims.rs` + `wat/io/RunDb.wat`)

`run_name` moves out of the `WatRunDb` struct's state and onto
`log_paper_resolved`'s parameter list. Schema setup moves OUT
of `open()` (per Q9 — wat owns the schema definitions); shim
gains a generic `execute_ddl` for wat to call at startup.

```rust
pub struct WatRunDb {
    conn: Connection,
    // run_name removed — was: run_name: String
}

pub fn open(path: String) -> Self;
// — connection only; no schema. Caller responsible for ddl setup.

pub fn execute_ddl(&mut self, ddl_str: String);
// — runs `conn.execute_batch(ddl_str)`. Used by wat to install
//   schemas (one per LogEntry variant) at service startup.

pub fn log_paper_resolved(
    &mut self,
    run_name: String,                  // ← new first param
    thinker: String, predictor: String,
    paper_id: i64, direction: String,
    opened_at: i64, resolved_at: i64,
    state: String, residue: f64, loss: f64,
);
// — INSERT one row into paper_resolutions. Renamed from
//   log_paper to align with the LogEntry::PaperResolved
//   variant name. Future variants add log_telemetry,
//   log_broker_snapshot, etc., each ~10 LOC.
```

```scheme
(:trading::rundb::open path)                         -> :trading::rundb::RunDb
(:trading::rundb::execute-ddl db ddl-str)            -> :()
(:trading::rundb::log-paper-resolved db run-name ...) -> :()
```

### LogEntry sum + schema (`wat/io/log/`)

```scheme
;; wat/io/log/LogEntry.wat — the unit of communication.
(:wat::core::enum :trading::log::LogEntry
  (PaperResolved
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64)))

;; wat/io/log/schema.wat — DDL strings, one per variant's table.
;; A single :trading::log::all-schemas Vec<String> the service
;; iterates at startup so growth is "add string + register".

(:wat::core::define
  (:trading::log::schema-paper-resolved -> :String)
  "CREATE TABLE IF NOT EXISTS paper_resolutions (...)"))

(:wat::core::define
  (:trading::log::all-schemas -> :Vec<String>)
  (:wat::core::vec :String
    (:trading::log::schema-paper-resolved)
    ;; future: (:trading::log::schema-telemetry), ...
    ))
```

### Service (`wat/io/RunDbService.wat`)

CacheService-style request/reply driver. Each request carries
its own ack-tx. One thread owns the connection; N clients
each get a request-Tx handle; each client also owns one ack
channel reused across batches.

```scheme
(:wat::core::typealias :trading::rundb::Service::AckTx
  :rust::crossbeam_channel::Sender<()>)
(:wat::core::typealias :trading::rundb::Service::AckRx
  :rust::crossbeam_channel::Receiver<()>)
(:wat::core::typealias :trading::rundb::Service::Request
  :(Vec<trading::log::LogEntry>, trading::rundb::Service::AckTx))

;; Setup: opens RunDb in driver thread, executes all schemas,
;;   spawns the loop. Returns the standard (pool, driver-handle).
(:trading::rundb::Service path count)
  -> :(HandlePool<Sender<Service::Request>>, ProgramHandle<()>)

;; Client helper — one primitive. Single-entry callers pass
;; (vec :LogEntry entry).
(:trading::rundb::Service/batch-log req-tx ack-tx ack-rx entries) -> :()

;; Internal dispatcher (wat-side):
(:trading::rundb::Service/dispatch db entry :LogEntry)
  ;; (match entry :LogEntry -> :()
  ;;   ((PaperResolved run-name thinker ... loss)
  ;;     (:trading::rundb::log-paper-resolved db run-name ... loss))
  ;;   ;; future: ((Telemetry ...) (:trading::rundb::log-telemetry db ...)))
```

Lifecycle mirrors Console + CacheService: caller spawns the
service, pops handles, distributes, calls `HandlePool::finish`,
clients log via `batch-log` (blocked-on-ack), handles drop,
driver's last `Rx` disconnects, loop exits, connection drops,
`(join driver)` confirms clean exit.

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

### Q8 — One DB per run, many tables

Builder direction 2026-04-25, mid-arc-029:

> "i think we should have one database per run with as many
> tables as we need... one db per run - that db can have as
> many tables as you want - that db contains everything we
> could want to review the run - we'll grow more tables later"

(Q9 below extends this principle to the *unit of communication*
crossing the channel.)

A "run" is one proof execution. ONE DB file per run; inside
the DB, schema grows as concerns surface. Today: just
`paper_resolutions`. Tomorrow: `aggregate_metrics`, `windows`,
`thinkers`, `runs` (top-level metadata), whatever future
proofs need.

What this rules out: splitting at the file level. v0 proof 002
opened `runs/proof-002-always-up-<epoch>.db` AND
`runs/proof-002-sma-cross-<epoch>.db` — two files for one
investigation, requiring `ATTACH DATABASE` for cross-thinker
queries. Wrong cut.

What this implies: one deftest per proof (not per thinker);
all variants of an experiment write into the same DB,
distinguished by columns (`thinker`, `run_name`, future
columns). The schema's `thinker` column was always there
(arc 027 left the door open) — proof 002's file-split simply
ignored it.

For proof 003: one DB at `runs/proof-003-<epoch>.db`. Inside,
20 sub-runs (2 thinkers × 10 windows) distinguished by
`(thinker, run_name)`. Cross-thinker queries are `GROUP BY
thinker`. Cross-window queries are `GROUP BY run_name`. No
ATTACH dance.

For arc 029's service: nothing in the service surface forces
or forbids this — `:trading::rundb::Service` takes one path; what
the caller passes is the caller's choice. The principle is
enforced at the proof layer, not the infra layer. The arc's
slice-1 proof-002 migration consolidates the two-deftest shape
into one.

Future proofs that span asset pairs (multi-asset enterprise)
might revisit: one DB per asset? One DB per session-of-runs?
That decision lives with whichever proof surfaces it.

### Q9 — `LogEntry` as the unit of communication

Builder direction 2026-04-25:

> "do you wanna review how the archived rust did database
> writes?.. the request pattern?.... it was very nice... i
> want to repeat that... the metrics we had and the records-
> as-logs system was phenomenal - we modeled it like a mini
> cloudwatch"

The archive's pattern (`archived/pre-wat-native/src/types/log_entry.rs`,
`archived/pre-wat-native/src/domain/ledger.rs`,
`archived/pre-wat-native/src/programs/telemetry.rs`):

- **`LogEntry`** is a discriminated union — 13 variants in the
  shipped enterprise. Each variant represents one *kind of
  thing that happened*: `ProposalSubmitted`, `TradeSettled`,
  `PaperResolved`, `Diagnostic` (per-candle perf timing
  breakdown), `Telemetry` (CloudWatch-style:
  `{namespace, id, dimensions, timestamp_ns, metric_name,
  metric_value, metric_unit}`), `ObserverSnapshot`,
  `BrokerSnapshot`, `PhaseSnapshot`, etc.
- Programs accumulate `Vec<LogEntry>` locally per candle,
  then flush in a confirmed batch.
- The driver `match`es on the variant and routes to the right
  table. `ObserverSnapshot` → `observer_snapshots`,
  `Telemetry` → `telemetry`, `BrokerSnapshot` →
  `broker_snapshots`, etc. **One enum, one DB, many tables.**

This arc adopts the same shape, with one wat-native twist:
**the variant dispatch lives in wat**, not Rust. The shim
exposes minimal primitives; wat owns the schema definitions
and the variant→table routing.

**Initial sum (this arc ships only this much):**

```scheme
(:wat::core::enum :trading::log::LogEntry
  (PaperResolved
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64)))
;; Future variants land as future proofs surface them:
;;   Telemetry, BrokerSnapshot, Diagnostic, PhaseSnapshot, ...
```

**Layering:**

- **Shim** (Rust, in `src/shims.rs`):
  - `RunDb::open(path)` — open the connection. No schema yet.
  - `RunDb::execute_ddl(conn, ddl_str)` — run a DDL string
    (CREATE TABLE, etc.). Wat calls this once per known
    variant at service startup.
  - `RunDb::log_<variant_snake>(conn, ...)` — one method per
    table, typed parameters. v1 ships only `log_paper_resolved`
    (matching the sole `PaperResolved` variant). Each new
    variant adds ~10 LOC of Rust later.
- **Wat** (in `wat/io/log/LogEntry.wat`, `wat/io/log/schema.wat`,
  `wat/io/RunDbService.wat`):
  - `LogEntry` sum.
  - Schema DDL constants per variant (one CREATE TABLE per
    variant), and a `:trading::log::all-schemas` Vec<String> the
    service iterates at startup.
  - The dispatcher: `(match entry → call shim's log_<variant>
    with the variant's fields)`.

**Adding a variant later** (e.g., when proof 005 wants
Telemetry rows for cosine similarity tracking):
1. Add the variant constructor in `wat/io/log/LogEntry.wat`.
2. Add the table DDL constant in `wat/io/log/schema.wat`,
   register it in `:trading::log::all-schemas`.
3. Add the wat dispatcher arm.
4. Add the shim method `log_telemetry` (~10 LOC).
5. No callers break — sum types are open at the variant
   level; existing matches stay exhaustive on the variants
   they handle and pattern-match-fail on novel variants
   (or use a catch-all `_` arm).

**Why the dispatch in wat, not Rust** (per builder
direction "as much as we can in wat"):
- Schema lives next to the variant constructor — read-locality.
- Adding a variant doesn't require a Rust commit unless a
  new typed insert wrapper is genuinely needed (it usually
  is — but the *dispatch* is a wat concern).
- The wat enum + match are first-class language constructs;
  no `#[wat_dispatch]` ceremony for the dispatch logic
  itself.

The cost: every new variant still touches Rust (the typed
shim wrapper). A future arc could collapse that to a single
generic `RunDb::execute(conn, sql, params)` taking a wat
`Vec<Param>` (sum of i64/f64/String) — but that needs a
`Param` heterogeneous-vec substrate primitive that doesn't
exist today. Out of scope for v1; revisit when the variant
count makes per-method codegen tedious (probably ≥10).

### Q10 — Batched send + ack (CSP confirmed-write)

Builder direction 2026-04-25 (in same exchange):

> "batch with ack - the perf matters"

The archive's `DatabaseHandle<T>::batch_send(entries)` sent
a `Vec<T>` and *blocked on a one-shot ack channel* until the
driver had committed the batch. This gave callers a
back-pressure signal: a slow driver throttles upstream
producers naturally. No silent drops, no unbounded queue
growth.

This arc replicates that, with the CacheService-style "reply
channel per request" pattern (each request carries its own
ack-tx, so the driver doesn't need to track per-client
ack-tx state):

```scheme
(:wat::core::typealias :trading::rundb::Service::AckTx
  :rust::crossbeam_channel::Sender<()>)
(:wat::core::typealias :trading::rundb::Service::AckRx
  :rust::crossbeam_channel::Receiver<()>)
(:wat::core::typealias :trading::rundb::Service::Request
  :(Vec<trading::log::LogEntry>, trading::rundb::Service::AckTx))
```

Driver loop:
1. `select` across N request receivers.
2. On `Some((batch, ack-tx))`:
   - `BEGIN TRANSACTION`
   - `foldl` over `batch`, dispatching each `LogEntry` to its
     shim method.
   - `COMMIT`
   - `(:wat::kernel::send ack-tx ())` — driver-side `send`
     swallows `:None` if the client is already gone.
3. Loop.

Client helper builds its ack channel once at setup, reuses
for every batch:

```scheme
(:trading::rundb::Service/batch-log
  (req-tx :Sender<Request>)
  (ack-tx :AckTx)         ; client-owned, reused
  (ack-rx :AckRx)         ; client-owned, reused
  (entries :Vec<LogEntry>)
  -> :())
;; sends (entries, ack-tx) on req-tx; recv on ack-rx; returns ()
```

**One primitive, no sugar.** Callers with a single entry pass
`(:wat::core::vec :trading::log::LogEntry entry)`. Builder
direction 2026-04-25:

> "only batch - if the user has one message its an array-of-one"

This keeps the surface honest (one verb to learn, one
contract to remember) and aligns with
`feedback_verbose_is_honest` — sugar that hides "this is
always a batch" would obscure the back-pressure semantics
callers need to reason about.

**Trade-off vs fire-and-forget (Console pattern):**
- + Back-pressure. Slow disks slow producers.
- + Atomic batch commits. A `Vec<LogEntry>` becomes one
  SQLite transaction; reads see all-or-nothing.
- + Throughput at scale. One BEGIN + N INSERTs + COMMIT is
  much faster than N auto-commit statements (the archive
  measured this — auto-commit was the bottleneck; batching
  unlocked thousands of writes/sec).
- − Client blocks on every `batch-log`. Single-thread
  callers (proof 003 v1) see ~1 ack per batch latency;
  acceptable.

**Batch boundaries are caller-defined.** Proof 003 will
naturally batch one window's outcomes (all PaperResolved
for w_i across the simulator loop, flushed once when the
window completes). Future per-candle telemetry will batch
all-Telemetry-for-this-candle. The service doesn't impose
a boundary; it just flushes whatever arrives.

---

## Implementation sketch

Three slices, tracked in [`BACKLOG.md`](BACKLOG.md):

- **Slice 1** — refactor `WatRunDb` (Rust + wat surface). Update
  proof 002's pair file and verify it produces the same numbers
  as the shipped run.
- **Slice 2** — build `:trading::rundb::Service` as a wat program in
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
