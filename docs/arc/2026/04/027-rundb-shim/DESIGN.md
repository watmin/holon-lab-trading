# lab arc 027 — Minimum-viable RunDb shim

**Status:** opened 2026-04-25.

**Scope:** small. ~120 LOC Rust + ~30 LOC wat wrapper + smoke test.
Same in-crate `#[wat_dispatch]` pattern as `CandleStream`. Estimate
half a day. Coordination ask from the proofs lane to the infra lane.

Builder direction:

> "we have logging queued up and we were writing logs to sqlite dbs
> to query from - no grepping"

> "i say we drop infra issues into arcs and we do proof things in
> proofs?... we can coordinate through the disk - you express what
> you want and we get it built"

This arc is the proofs-lane → infra-lane handoff for the SQLite-
logging surface. Proof 002 (`docs/proofs/2026/04/002-thinker-baseline/`)
needs it; sits BLOCKED until this arc closes.

Cross-references:
- [`docs/proofs/2026/04/002-thinker-baseline/PROOF.md`](../../proofs/2026/04/002-thinker-baseline/PROOF.md) — the consumer.
- [`archived/pre-wat-native/src/programs/stdlib/database.rs`](../../../archived/pre-wat-native/src/programs/stdlib/database.rs) — the 627-LOC archive predecessor (CSP-style batched writer with driver thread; this arc ships *less* than that, deliberately).
- `feedback_query_db_not_tail` memory — "use SQL on the run DB, not log tail; machine reads machine data."
- [`docs/rewrite-backlog.md`](../../rewrite-backlog.md) Phase 7 entry naming `wat-rusqlite` as a future sibling crate.
- [`src/shims.rs`](../../../src/shims.rs) — existing in-crate dispatch pattern; this arc extends it.

---

## Why this arc, why now

Proof 001 established the simulator runs end-to-end on real BTC.
Proof 002 wants to know **what numbers the simulator actually
produces** — `(papers, grace, violence, residue, loss)` per thinker
— and compare two v1 thinkers (always-up, sma-cross) to see whether
either produces meaningful Grace.

Today the simulator doesn't log per-paper outcomes anywhere. The
existing `:trading::sim::Aggregate` is a return-from-run summary;
the per-paper history is computed and discarded inside the
simulator's loop. Proof 002 needs the per-paper trail persisted to
disk in a query-friendly form.

Per memory `feedback_query_db_not_tail`, that form is SQLite — not
text logs that need grepping. Past archived runs lived in
`runs/*.db`; the pattern is established. The wat-side shim to
write into SQLite from the simulator is what's missing.

---

## What ships

A minimum-viable in-crate `#[wat_dispatch]` shim. Same pattern as
the parquet `CandleStream` shipped under arc 025 slice 0.

### `src/shims.rs` additions

```rust
use rusqlite::Connection;

pub struct WatRunDb {
    conn: Connection,
    run_name: String,
}

#[wat_dispatch(path = ":rust::trading::RunDb", scope = "thread_owned")]
impl WatRunDb {
    /// Open or create a SQLite database at `path`, ensure the
    /// `paper_resolutions` schema exists, and bind a `run_name`
    /// discriminator for every subsequent `log_paper` call.
    pub fn open(path: String, run_name: String) -> Self { ... }

    /// Insert one row into `paper_resolutions`. Single statement,
    /// no batching (v1 simplification — see Q3).
    pub fn log_paper(
        &mut self,
        thinker: String, predictor: String,
        paper_id: i64, direction: String,
        opened_at: i64, resolved_at: i64,
        state: String,                      // "Grace" | "Violence"
        residue: f64, loss: f64,
    ) {
        ...
    }

    /// Flush + close. Optional — Drop also commits, but explicit
    /// close gives the wat program a control point.
    pub fn close(&mut self) { ... }
}
```

### `wat/io/RunDb.wat` (new)

```scheme
(:wat::core::use! :rust::trading::RunDb)

(:wat::core::typealias :trading::rundb::RunDb :rust::trading::RunDb)

(:wat::core::define
  (:trading::rundb::open
    (path :String) (run-name :String)
    -> :trading::rundb::RunDb)
  (:rust::trading::RunDb::open path run-name))

(:wat::core::define
  (:trading::rundb::log-paper
    (db :trading::rundb::RunDb)
    (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String)
    (residue :f64) (loss :f64)
    -> :())
  (:rust::trading::RunDb::log-paper db thinker predictor paper-id direction
                                 opened-at resolved-at state residue loss))

(:wat::core::define
  (:trading::rundb::close
    (db :trading::rundb::RunDb)
    -> :())
  (:rust::trading::RunDb::close db))
```

### Schema

ONE table for v1. `runs/<file>.db` is one DB per run; per-run
isolation handled at the file level rather than via foreign keys.

```sql
CREATE TABLE IF NOT EXISTS paper_resolutions (
  run_name     TEXT NOT NULL,
  thinker      TEXT NOT NULL,
  predictor    TEXT NOT NULL,
  paper_id     INTEGER NOT NULL,
  direction    TEXT NOT NULL,    -- 'Up' | 'Down'
  opened_at    INTEGER NOT NULL, -- candle index
  resolved_at  INTEGER NOT NULL,
  state        TEXT NOT NULL,    -- 'Grace' | 'Violence'
  residue      REAL NOT NULL,
  loss         REAL NOT NULL,
  PRIMARY KEY (run_name, paper_id)
);
```

`run_name` exists in the schema even though one DB = one run for
v1 — leaves the door open for "many runs in one DB" without a
schema migration when a future caller wants it.

### `Cargo.toml` addition

```toml
rusqlite = { version = "0.31", features = ["bundled"] }
```

The `bundled` feature builds libsqlite from source rather than
depending on a system shared library. Same pattern as the archive
(`archived/pre-wat-native/Cargo.toml:20`).

---

## Decisions resolved

### Q1 — Why not port `database.rs` in full?

**Out of scope.** The archive's `database.rs` (627 LOC) is the
full CSP-style batched writer: per-client request/ack queues, a
dedicated driver thread, telemetry gate-pattern emit closures,
shutdown flush coordination. That work belongs in Phase 7's
`wat-rusqlite` sibling crate when the lab needs multi-program
shared SQLite access (the ledger; multi-broker tournament; live
trading observability).

This arc ships only what proof 002 needs: a single-threaded
synchronous one-row-per-call writer. Same surface area as the
parquet `CandleStream` reader. When Phase 7 opens, the lab
upgrades to the batched/driver-thread shape; v1 callers like
proof 002 either upgrade or stay on this minimal shim.

### Q2 — Where does the shim live?

**`src/shims.rs`** alongside `WatCandleStream`. Same precedent.
The "no new crate" position from arc 025's CandleStream work
holds: rusqlite is a direct dep of the lab; the shim lives in the
lab's own Rust surface.

### Q3 — Batching, transactions, durability

**v1: one `INSERT` per `log_paper` call. No explicit transaction.**

Rusqlite uses SQLite's auto-commit by default — every statement
runs in its own transaction unless wrapped explicitly. For
proof 002's volume (thousands of rows per run, not millions),
auto-commit's overhead is acceptable. A future arc adds a
`begin_transaction` / `commit` pair when a caller surfaces the
write throughput as hot.

`close` calls `Connection::close()` (or relies on Drop). No
explicit flush needed — SQLite WAL handles durability at the
file level.

### Q4 — Concurrency

**v1: single-threaded, thread-owned.** `scope = "thread_owned"`
on the `#[wat_dispatch]` annotation matches `CandleStream`'s
shape. The simulator runs single-threaded; the shim is owned by
that thread; no Mutex.

When multi-broker tournament work opens (Phase 7+ probably), the
shim grows to a CSP-style driver-thread variant. Out of scope here.

### Q5 — Schema migrations

**None for v1.** The `CREATE TABLE IF NOT EXISTS` at `open` time
handles fresh databases; existing databases with the same schema
shape just work. If the schema changes later, callers create a
new DB file or add a migration step. SQLite's `PRAGMA user_version`
exists for the day we need it.

### Q6 — Error handling posture

**Construction-time errors panic** (`open` on a bad path; schema
creation failure on a permission issue) — same posture as
`CandleStream::open` (per `feedback_shim_panic_vs_option`'s
"construction/input-validation panics with diagnostic" rule).

**Per-call write errors** — `log_paper` panics on rusqlite errors
in v1 (e.g., disk full, schema mismatch). A future arc could
return `:Result<(), String>` once a caller wants to handle write
failures gracefully. Proof 002 doesn't need that; it'd rather
crash loudly than silently drop log rows.

### Q7 — Run-name lifecycle

The `run_name` is bound at `open` time and stored on the shim.
Every `log_paper` call uses that bound name. To start a new run
with a different name, callers `close` the current shim and
`open` a new one. v1 doesn't support changing the run name on a
live shim — keeps the `log_paper` arity fixed and avoids state-
machine concerns.

---

## Implementation sketch

Three slices.

### Slice 1 — Rust shim + Cargo.toml

`src/shims.rs` gains the `WatRunDb` newtype + `#[wat_dispatch]`
impl block. Cargo.toml gains rusqlite. Build verifies.

### Slice 2 — wat wrapper

`wat/io/RunDb.wat` ships the typealias + thin define wrappers.
`wat/main.wat` adds the `(:wat::load-file! "io/RunDb.wat")` line
in the Phase 0 section near `io/CandleStream.wat`.

### Slice 3 — Smoke test + INSCRIPTION

`wat-tests/io/RunDb.wat` (3 deftests):
- `test-open-creates-schema` — open a tempfile, verify the
  `paper_resolutions` table exists post-open.
- `test-log-paper-round-trip` — open, log one row, close, re-open
  the same DB, query, verify the row matches what was written.
- `test-multiple-rows` — log 100 rows, query count, verify == 100.

Then INSCRIPTION + flip proof 002's status from BLOCKED to ready.

---

## What this arc does NOT add

- **Batched / async / driver-thread writes.** Future arc.
- **Multi-program shared access** (the archive's
  `request/ack queue` shape). Future arc.
- **Schema migrations.** Future arc.
- **Telemetry / gate-pattern emit callbacks.** Future arc.
- **A separate `wat-rusqlite` crate.** When Phase 7 opens,
  factor out — same path as `wat-lru`. Not this arc.
- **Result-typed write errors.** v1 panics; future arc adds
  `:Result<()>` when a caller needs it.
- **Read APIs.** v1 is write-only. Queries happen out-of-band via
  the `sqlite3` CLI or external tools. Future arc adds read APIs
  if a wat program needs to consume its own log output.

---

## What this unblocks

- **Proof 002 — `(papers, grace, violence, residue, loss)` per
  thinker.** The proofs-lane consumer; sketched at
  `docs/proofs/2026/04/002-thinker-baseline/PROOF.md`.
- **Proof 003+ — sma-cross vs always-up comparison.** Same shim;
  multiple runs into separate `runs/proof-NNN-*.db` files.
- **Proof 004 — full 6-year stream.** Captures aggregates over
  650k candles; querying time-distributed Grace/Violence becomes
  trivial SQL.
- **Future Phase 5 ledger work.** When the ledger ports, this
  shim either upgrades or sits next to a richer
  `wat-rusqlite`-style sibling crate. The schema lives on either
  way.

PERSEVERARE.
