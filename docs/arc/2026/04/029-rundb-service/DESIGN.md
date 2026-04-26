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

This arc fixes the shape. Two slices:

**Slice A — refactor the shim.** Drop `run_name` from
`WatRunDb`'s state; make it a per-message field on `log_paper`.
Backward-incompatible change to arc 027; proof 002 is the only
consumer and gets a one-line update. ~30 LOC delta.

**Slice B — wat-level `:lab::rundb::Service`.** Console-style
fire-and-forget driver loop. One thread owns the connection.
N clients each get a `Sender<Request>`. Each Request carries the
full row (run_name included). Drop cascade closes cleanly.
~120 LOC wat, no Rust.

Cross-references:
- [`archived/pre-wat-native/src/programs/stdlib/database.rs`](../../../../archived/pre-wat-native/src/programs/stdlib/database.rs) — 627-LOC archive predecessor. Generic batched SQLite writer behind a driver thread, per-client req/ack queues, gate-controlled telemetry. This arc ships *less* — no batching, no telemetry gate — but mirrors the lifecycle (drop cascade → final flush → driver exit). Future sibling arc adds batching when a hot-path caller surfaces.
- `wat-rs/wat/std/service/Console.wat` — fire-and-forget service template (one driver, N clients, tagged messages). Closest match for the rundb service: every log is a side-effect with no reply needed.
- `wat-rs/crates/wat-lru/wat/lru/CacheService.wat` — query-style service template (per-message reply channel). Reference, not template — the rundb service doesn't need replies.
- `feedback_query_db_not_tail` — "no grepping; SQL on the run DB."
- `feedback_capability_carrier` — new capabilities should attach to existing carriers; `RunDb` shim already exists, so the wat service builds on top rather than carving a new slot.

---

## Why this arc, why now

Proof 003 needs **10 different run_names per database** so that
per-window slicing is `GROUP BY run_name`. The arc-027 shim
binds run_name at open; the only honest path with that shape is
"open 10 connections to the same file." That works mechanically
but it's an architectural lie — we already know the right shape
from the archived Rust (one connection, many writers) and from
the wat service templates (driver thread + clients).

The wat substrate has matured since arc 027: kernel/select,
HandlePool, ProgramHandle, make-bounded-queue, spawn — all in
production via Console + CacheService. The rundb-as-service shape
is now expressible in ~120 LOC of wat. A month ago it would have
required a Rust-side mini-service. Today it's a wat program.

This arc closes the shape gap before any more proofs build on
the wrong abstraction.

---

## Slice A — Refactor `WatRunDb`

### Current shape (arc 027)

```rust
pub struct WatRunDb {
    conn: Connection,
    run_name: String,    // ← bound at open
}

pub fn open(path: String, run_name: String) -> Self;
pub fn log_paper(&mut self, thinker, predictor, paper_id, ...);
//                                            ↑ no run_name; uses self.run_name
```

```scheme
(:lab::rundb::open path run-name) -> :lab::rundb::RunDb
(:lab::rundb::log-paper db thinker predictor paper-id ...) -> :()
```

### New shape

```rust
pub struct WatRunDb {
    conn: Connection,
    // run_name removed
}

pub fn open(path: String) -> Self;
pub fn log_paper(
    &mut self,
    run_name: String,    // ← per-message
    thinker: String,
    predictor: String,
    paper_id: i64,
    direction: String,
    opened_at: i64,
    resolved_at: i64,
    state: String,
    residue: f64,
    loss: f64,
);
```

```scheme
(:lab::rundb::open path) -> :lab::rundb::RunDb
(:lab::rundb::log-paper db run-name thinker predictor paper-id ...) -> :()
```

Schema unchanged (`run_name` was always a column; the only
change is who supplies it).

### Migration

`wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`
is the only consumer. The `:lab::rundb::open` calls drop their
second arg; the `(:lab::rundb::log-paper db thinker-name
predictor-name ...)` calls gain `run-name` as the second arg
(after `db`). The run-name is already constructed in proof 002's
let* (passed to `(:lab::rundb::open db-path run-name)`); just
hoist it as the source-of-truth and pass it on every log call.

Smoke check after migration: `cargo test --features proof-002
--test proof_002` returns the same numbers as today (34 papers
each thinker, conservation holds, same residue/loss).

### Slice A LOC budget

- `src/shims.rs`: −1 line (struct field) + 1 line (parameter) + 1 line in execute params; trivial. ~5 LOC delta.
- `wat/io/RunDb.wat`: 1 parameter added to log-paper, 1 removed from open; doc comments updated. ~10 LOC delta.
- Proof 002 wat: hoist run_name binding to outer let*, add run-name arg to two log-paper sites. ~6 LOC delta.

**Total: ~25 LOC, ~30 minutes including the proof 002 verification re-run.**

---

## Slice B — `:lab::rundb::Service`

### Protocol

```scheme
(:wat::core::typealias :lab::rundb::Service::Resolution
  :(String,String,String,i64,String,i64,i64,String,f64,f64))
;;   run-name, thinker, predictor, paper-id, direction,
;;   opened-at, resolved-at, state, residue, loss

(:wat::core::typealias :lab::rundb::Service::Tx
  :rust::crossbeam_channel::Sender<lab::rundb::Service::Resolution>)

(:wat::core::typealias :lab::rundb::Service::Rx
  :rust::crossbeam_channel::Receiver<lab::rundb::Service::Resolution>)
```

Single message type; no tag/body split. Console has tags because
two destinations (stdout/stderr); rundb has one destination
(the table) so messages are uniform.

### Driver loop

```scheme
(:wat::core::define
  (:lab::rundb::Service/loop
    (db :lab::rundb::RunDb)
    (rxs :Vec<lab::rundb::Service::Rx>)
    -> :())
  (:wat::core::if (:wat::core::empty? rxs) -> :()
    ()
    (:wat::core::let*
      (((chosen :(i64,Option<lab::rundb::Service::Resolution>))
        (:wat::kernel::select rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<lab::rundb::Service::Resolution>)
        (:wat::core::second chosen)))
      (:wat::core::match maybe -> :()
        ((Some r)
          (:wat::core::let*
            (((_ :()) (:lab::rundb::Service/dispatch db r)))
            (:lab::rundb::Service/loop db rxs)))
        (:None
          (:lab::rundb::Service/loop
            db
            (:wat::std::list::remove-at rxs idx)))))))
```

`dispatch` unpacks the 10-tuple and calls the (refactored)
`:lab::rundb::log-paper`.

### Client helper

```scheme
(:wat::core::define
  (:lab::rundb::Service/log
    (handle :lab::rundb::Service::Tx)
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64)
    -> :())
  (:wat::core::let*
    (((r :lab::rundb::Service::Resolution)
      (:wat::core::tuple
        run-name thinker predictor paper-id direction
        opened-at resolved-at state residue loss))
     ((_ :Option<()>) (:wat::kernel::send handle r)))
    ()))
```

Fire-and-forget. If the driver dropped before we wrote, `send`
returns `:None` and the log is silently lost — same as
`Console/out`. A program that wants disconnect awareness uses
`:wat::kernel::send` directly.

### Setup

```scheme
(:wat::core::define
  (:lab::rundb::Service
    (path :String)
    (count :i64)
    -> :(wat::kernel::HandlePool<lab::rundb::Service::Tx>,
         wat::kernel::ProgramHandle<()>))
  (:wat::core::let*
    (((pairs :Vec<(lab::rundb::Service::Tx,lab::rundb::Service::Rx)>)
      (:wat::core::map (:wat::core::range 0 count)
        (:wat::core::lambda ((_i :i64) -> :(...))
          (:wat::kernel::make-bounded-queue
            :lab::rundb::Service::Resolution 1))))
     ((txs ...) ...)
     ((rxs ...) ...)
     ((db :lab::rundb::RunDb) (:lab::rundb::open path))
     ((pool :wat::kernel::HandlePool<lab::rundb::Service::Tx>)
      (:wat::kernel::HandlePool::new "RunDbService" txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :lab::rundb::Service/loop db rxs)))
    (:wat::core::tuple pool driver)))
```

**Wait — `db` opens in the caller, then crosses thread boundary
into the driver via `spawn`.** Per CacheService precedent
(`LocalCache::new` is called *inside* the driver loop entry,
not in the setup), the right move is to open the connection
*inside* the driver so it never crosses threads. Service entry
takes `path` and opens.

```scheme
;; Driver entry — opens the connection inside the driver thread.
(:wat::core::define
  (:lab::rundb::Service/loop-entry
    (path :String)
    (rxs :Vec<lab::rundb::Service::Rx>)
    -> :())
  (:wat::core::let*
    (((db :lab::rundb::RunDb) (:lab::rundb::open path)))
    (:lab::rundb::Service/loop db rxs)))

;; Setup — spawns the entry, no db pre-open.
;;
;;   ((driver ...) (:wat::kernel::spawn
;;                   :lab::rundb::Service/loop-entry path rxs))
```

This mirrors CacheService's `LocalCache` thread-id guard: the
underlying resource gets created inside its driver. The shim's
`Connection` from arc 027 is `thread_owned`; can't cross
without panic.

### Lifecycle

Same shape as Console + CacheService:

1. Caller: `(let* (((tup ...) (:lab::rundb::Service "runs/foo.db" 4))
                     ((pool ...) (first tup))
                     ((driver ...) (second tup))
                     ((handles ...) (HandlePool::pop-all pool))) ...)`
2. Distribute `handles[i]` to clients.
3. `(:wat::kernel::HandlePool::finish pool)` after distribution.
4. Clients log via `:lab::rundb::Service/log handle ...`.
5. Clients drop their handles (end of scope).
6. Driver's last receiver disconnects → loop exits → connection
   dropped → file-handle released (rusqlite auto-commits per
   statement, so nothing to flush).
7. Caller: `(:wat::kernel::join driver)` to confirm clean exit.

### Slice B LOC budget

- `wat/io/RunDbService.wat`: typealiases (~15 LOC) + loop-entry + loop (~25 LOC) + log helper (~15 LOC) + setup (~30 LOC) + doc comments (~30 LOC). **~115 LOC.**
- No Rust changes; everything runs on the slice-A-refactored shim plus existing wat::kernel::* primitives.
- `src/shims.rs::wat_sources()`: 1 line to register the new wat file.

**Total: ~120 LOC, ~1 hour.**

---

## Slice C — Proof 003 supporting program

(Tracked under [`docs/proofs/2026/04/003-thinker-significance/`](../../proofs/2026/04/003-thinker-significance/PROOF.md), not this arc — but the seam this arc opens is the seam proof 003 consumes.)

Sketch:

```scheme
;; In each deftest:
(let* (((tup ...) (:lab::rundb::Service "runs/proof-003-<thinker>-<epoch>.db" 1))
       ((pool ...) (first tup))
       ((driver ...) (second tup))
       ((handles ...) (:wat::kernel::HandlePool::pop-all pool))
       ((_ :()) (:wat::kernel::HandlePool::finish pool))
       ((handle ...) (:wat::core::nth handles 0))
       ;; Walk 10 windows, log each Outcome with its run_name.
       ;; The handle is shared across all 10 iterations because
       ;; this deftest is single-threaded; future multi-thread
       ;; consumers would pop count-many handles instead.
       ((_run :())
        (foldl (range 0 10) ()
          (lambda ((acc :()) (i :i64) -> :())
            (run-window-i path i window-size cfg thinker predictor
                          handle "<thinker>" "cosine-vs-corners" iso-str))))
       ;; handle drops out of scope → driver's last rx disconnects.
       ((_ :()) (:wat::kernel::join driver)))
  (:wat::test::assert-eq true true))
```

`run-window-i` opens a per-window stream, runs the simulator,
walks `SimState/outcomes`, calls `Service/log` for each with
the per-window `run-name = "<thinker>-w<i>-<iso>"`.

---

## Out of scope

- **Batching.** The archived rust pattern batched per-client and
  flushed on threshold. The lab's current write volume (≈340
  inserts per proof) doesn't justify the complexity. A future arc
  adds it when a high-throughput consumer (multi-asset post grid,
  tick-by-tick logging) surfaces.
- **Telemetry gate.** Same rationale.
- **Read-side queries.** Still out of scope per arc 027. Use the
  `sqlite3` CLI.
- **WAL mode pragma.** rusqlite's default rollback journal is
  fine for write-heavy single-writer workloads. Multi-writer
  proof-side use cases haven't materialized.
- **Multi-database support per service.** One service, one path.
  A program that needs two databases spawns two services.

---

## Risks

**Lifecycle correctness across deftest boundaries.** The
`HandlePool` + `spawn` lifecycle works in the wat-rs unit
tests (Console, CacheService). Lab proofs inside `cargo test`
under the `wat::test!` macro have not yet exercised the
HandlePool/spawn shape. If kernel scheduling or test-isolation
quirks bite, fall back to the slice-A-only path: open the shim
directly (no service), pass run_name on every log call, single
thread. Proof 003 still works; just bypasses the service.

**`spawn` accepts a named-define entry by symbol** (per Console
precedent). If the macro path can't load `:lab::rundb::Service/loop-entry`
at spawn time, the failure mode is at startup (wat-side check
catches the unresolved symbol). Diagnostic clear; recoverable.

**Cross-thread sends of `Resolution = (String, String, ...)`.**
Strings are `Send` in Rust; tuples of `Send` are `Send`. The
crossbeam_channel typealiases above already require `Send` at
the type-check layer. No new cross-thread surface.

---

## Total estimate

- Slice A (shim refactor + proof 002 update): 30 minutes
- Slice B (RunDbService wat program): 1 hour
- Slice C (proof 003 supporting program): 30 minutes
- Verification (proof 002 still passes; proof 003 newly passes): 15 minutes

**~2.5 hours** of focused work. Smaller than arc 027 (which
shipped in similar elapsed time including the failed first
attempt at the test-binary scaffolding).

---

## What this unblocks

- **Proof 003** — flips from DESIGN to runnable; produces the
  multi-window numbers that compare always-up vs sma-cross
  across the 6-year stream.
- **Proof 004** — full 6-year stream. Single window, single
  client; the service is overkill but the single-row-per-Outcome
  shape works at any scale.
- **Future proof N** — multi-thread, multi-broker per post.
  Each broker holds its own `Service::Tx` handle; the driver
  serializes writes. The shape is the shape regardless of
  client count.

PERSEVERARE.
