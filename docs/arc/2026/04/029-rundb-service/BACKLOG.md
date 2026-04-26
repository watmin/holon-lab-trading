# lab arc 029 — RunDb service — BACKLOG

**Shape:** three slices. Slice 1 refactors the arc-027 shim
(`run_name` per-message, not per-handle). Slice 2 builds the
wat-only `:lab::rundb::Service` on top. Slice 3 lands the
INSCRIPTION and flips proof 003 from BLOCKED to ready. Total
estimate: ~2.5 hours.

This arc is the second proofs-lane → infra-lane handoff.
Builder direction 2026-04-25 (mid-implementation, after I tried
to hack 10 sequential `:lab::rundb::open` calls into proof 003):

> "hold on - we need a db service for this... go study the
> archived rust and wat's service pattern (console service,
> cache service)"

The proofs lane drafts the design + backlog (this doc); the
infra session implements; the proofs lane writes the supporting
program once the seam exists.

---

## Slice 1 — Refactor `WatRunDb` (per-message `run_name`)

**Status: not started.**

`src/shims.rs` — three small edits:

1. **Struct:** drop the `run_name: String` field.

```rust
pub struct WatRunDb {
    conn: Connection,
    // run_name removed
}
```

2. **`open(path)` — drop the `run_name` parameter.**

```rust
pub fn open(path: String) -> Self {
    let conn = Connection::open(&path).unwrap_or_else(|e| {
        panic!(":rust::lab::RunDb::open: cannot open {path}: {e}")
    });
    conn.execute_batch(RUNDB_SCHEMA).unwrap_or_else(|e| {
        panic!(":rust::lab::RunDb::open: schema creation failed at {path}: {e}")
    });
    Self { conn }
}
```

3. **`log_paper(...)` — add `run_name` as the first arg, replace
   `self.run_name` in the params.**

```rust
#[allow(clippy::too_many_arguments)]
pub fn log_paper(
    &mut self,
    run_name: String,    // ← new first arg
    thinker: String,
    predictor: String,
    paper_id: i64,
    direction: String,
    opened_at: i64,
    resolved_at: i64,
    state: String,
    residue: f64,
    loss: f64,
) {
    self.conn.execute(
        "INSERT OR REPLACE INTO paper_resolutions \
         (run_name, thinker, predictor, paper_id, direction, \
          opened_at, resolved_at, state, residue, loss) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            run_name,    // ← was self.run_name
            thinker, predictor, paper_id, direction,
            opened_at, resolved_at, state, residue, loss,
        ],
    ).unwrap_or_else(|e| {
        panic!(":rust::lab::RunDb::log-paper: insert failed: {e}")
    });
}
```

`wat/io/RunDb.wat` — mirror the signature change:

```scheme
(:wat::core::define
  (:lab::rundb::open
    (path :String)                              ; ← removed run-name arg
    -> :lab::rundb::RunDb)
  (:rust::lab::RunDb::open path))

(:wat::core::define
  (:lab::rundb::log-paper
    (db :lab::rundb::RunDb)
    (run-name :String)                          ; ← new arg
    (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String)
    (residue :f64) (loss :f64)
    -> :())
  (:rust::lab::RunDb::log-paper
    db run-name thinker predictor paper-id direction
    opened-at resolved-at state residue loss))
```

Doc comments at the top of `wat/io/RunDb.wat` — update the
example block to show per-call run_name. Schema doc unchanged.

`wat-tests/io/RunDb.wat` — three existing smoke tests need their
`open` calls trimmed and `log-paper` calls patched to pass
run_name. ~6 line edits across the file.

`wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`
— two `(:lab::rundb::open db-path run-name)` sites become
`(:lab::rundb::open db-path)`; the existing `run-name` binding
in each deftest's `let*` gets passed to every
`(:lab::rundb::log-paper db ...)` call as the second argument.
The helper `log-outcome` in proof 002 grows one parameter
(`run-name`) and threads it into the two `log-paper` call sites
inside its `match`.

### Verification

```bash
# 1. Lab unit tests pass — RunDb smoke tests still work.
cargo test --release --test test 2>&1 | grep -E "rundb|FAILED"

# 2. Proof 002 still passes and produces the SAME numbers.
cargo test --release --features proof-002 --test proof_002 -- --nocapture

# 3. Confirm proof 002's freshest DB has the expected counts.
ls -t runs/proof-002-always-up-*.db | head -1 | xargs -I{} sqlite3 {} \
  "SELECT COUNT(*), SUM(state='Grace'), SUM(state='Violence') FROM paper_resolutions;"
# Expected: 34 | 0 | 34   (matches proof 002's shipped numbers)

ls -t runs/proof-002-sma-cross-*.db | head -1 | xargs -I{} sqlite3 {} \
  "SELECT COUNT(*), SUM(state='Grace'), SUM(state='Violence') FROM paper_resolutions;"
# Expected: 34 | 5 | 29
```

If proof 002's numbers shift, the refactor introduced a
behavioral change — back out and re-investigate before
proceeding to slice 2.

**LOC budget:**
- `src/shims.rs`: −1 field, +1 param, ~5 LOC delta net.
- `wat/io/RunDb.wat`: 1 param removed from open, 1 added to log-paper, doc comments refreshed. ~10 LOC delta.
- `wat-tests/io/RunDb.wat`: ~6 line edits.
- `wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`: ~6 line edits.

**Estimated cost:** ~30 LOC delta. **~30 minutes** including the
proof 002 verification re-run.

---

## Slice 2 — `:lab::rundb::Service` (wat-only)

**Status: not started.** Depends on slice 1.

`wat/io/RunDbService.wat` — new file. Mirrors the shape of
`wat-rs/wat/std/service/Console.wat` (fire-and-forget service
template; one driver thread, N clients, no reply channels).

### Protocol typealiases

```scheme
;; A Resolution is the full row payload, run_name included.
;; (run-name, thinker, predictor, paper-id, direction,
;;  opened-at, resolved-at, state, residue, loss)
(:wat::core::typealias :lab::rundb::Service::Resolution
  :(String,String,String,i64,String,i64,i64,String,f64,f64))

(:wat::core::typealias :lab::rundb::Service::Tx
  :rust::crossbeam_channel::Sender<lab::rundb::Service::Resolution>)

(:wat::core::typealias :lab::rundb::Service::Rx
  :rust::crossbeam_channel::Receiver<lab::rundb::Service::Resolution>)
```

### Driver entry — opens the connection inside the driver thread

Per CacheService precedent (LocalCache::new is called inside
the driver, not in the setup): the `RunDb` shim is
`thread_owned`, so `open` MUST happen in the driver's thread.

```scheme
(:wat::core::define
  (:lab::rundb::Service/loop-entry
    (path :String)
    (rxs :Vec<lab::rundb::Service::Rx>)
    -> :())
  (:wat::core::let*
    (((db :lab::rundb::RunDb) (:lab::rundb::open path)))
    (:lab::rundb::Service/loop db rxs)))
```

### Recursive select loop

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

### Dispatch — unpack the 10-tuple, call refactored log-paper

```scheme
(:wat::core::define
  (:lab::rundb::Service/dispatch
    (db :lab::rundb::RunDb)
    (r :lab::rundb::Service::Resolution)
    -> :())
  ;; tuple destructuring via nth or via pattern match —
  ;; whichever the surface prefers. Threads the 10 fields
  ;; into log-paper.
  ...)
```

(If wat doesn't have an ergonomic 10-tuple destructuring form,
the dispatch may need to use `:wat::core::nth` repeatedly. Keep
the implementation honest — no synthetic helpers.)

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

Fire-and-forget: if the driver is gone, `send` returns `:None`
and the log is silently lost — same posture as `Console/out`.

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
        (:wat::core::lambda
          ((_i :i64)
           -> :(lab::rundb::Service::Tx,lab::rundb::Service::Rx))
          (:wat::kernel::make-bounded-queue
            :lab::rundb::Service::Resolution 1))))
     ((txs :Vec<lab::rundb::Service::Tx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :(lab::rundb::Service::Tx,lab::rundb::Service::Rx))
           -> :lab::rundb::Service::Tx)
          (:wat::core::first p))))
     ((rxs :Vec<lab::rundb::Service::Rx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :(lab::rundb::Service::Tx,lab::rundb::Service::Rx))
           -> :lab::rundb::Service::Rx)
          (:wat::core::second p))))
     ((pool :wat::kernel::HandlePool<lab::rundb::Service::Tx>)
      (:wat::kernel::HandlePool::new "RunDbService" txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :lab::rundb::Service/loop-entry path rxs)))
    (:wat::core::tuple pool driver)))
```

### Wire the new wat file into `src/shims.rs::wat_sources()`

```rust
pub fn wat_sources() -> &'static [WatSource] {
    static FILES: &[WatSource] = &[
        WatSource { path: "io/CandleStream.wat",
                    source: include_str!("../wat/io/CandleStream.wat") },
        WatSource { path: "io/RunDb.wat",
                    source: include_str!("../wat/io/RunDb.wat") },
        WatSource { path: "io/RunDbService.wat",                       // ← new
                    source: include_str!("../wat/io/RunDbService.wat") },
    ];
    FILES
}
```

### Smoke tests

`wat-tests/io/RunDbService.wat` — three deftests (single-client
roundtrip, multi-client fan-in, lifecycle exit on disconnect).
Same CSP-test shape as `wat-rs/wat-tests/std/service/Console.wat`
modulo the run-hermetic-ast wrapper (rundb writes to its own
file; no cross-thread stdio issue). Verify by reading back via
`sqlite3` CLI in the test (or — if a quick `:rust::lab::*`
helper for `SELECT COUNT(*)` is added — assert in-wat).

### Verification

```bash
cargo test --release --test test 2>&1 | grep -E "rundb|RunDb|FAILED"
# Lab wat tests count climbs by 3 (the new service smoke tests).
```

**LOC budget:**
- `wat/io/RunDbService.wat`: typealiases (~15 LOC) + loop-entry/loop/dispatch (~50 LOC) + log helper (~15 LOC) + setup (~30 LOC) + doc comments (~30 LOC). **~140 LOC.**
- `src/shims.rs`: 1 line in `wat_sources()`.
- `wat-tests/io/RunDbService.wat`: ~80 LOC for 3 deftests.

**Estimated cost:** ~220 LOC + 3 tests. **~1.5 hours**.

---

## Slice 3 — INSCRIPTION + downstream status flip

**Status: not started.** Depends on slices 1 and 2.

`docs/arc/2026/04/029-rundb-service/INSCRIPTION.md` — same shape
as arc 027's INSCRIPTION:

- "What shipped" table (slice / surface / LOC / status).
- Lab wat test count delta (current 331 → expected 334).
- Architecture notes: divergences from DESIGN, decisions made
  during implementation (e.g., if 10-tuple destructuring needed
  a substrate uplift, capture it).
- "What this unblocks" — proof 003 status, forward implications.
- "What this arc deliberately did NOT add" — mirror DESIGN's
  out-of-scope (batching, telemetry, read APIs).
- "The thread" — date timeline.

`docs/proofs/2026/04/003-thinker-significance/PROOF.md` — flip
status header from `BLOCKED on lab arc 029` to `ready — pair
file forthcoming`. The proofs lane writes the supporting
program at `wat-tests-integ/proof/003-thinker-significance/`.

`docs/proofs/2026/04/002-thinker-baseline/PROOF.md` — note in
the closing section that proof 002's pair file was migrated to
the per-message `run_name` shim shape post-arc-029.

**Estimated cost:** ~1 hour. Doc only.

---

## Verification end-to-end

After all three slices land:

```bash
cd /home/watmin/work/holon/holon-lab-trading

# 1. Build clean.
cargo build --release

# 2. All lab wat-tests pass.
cargo test --release --test test 2>&1 | grep -E "test result|FAILED"
# Expected: 334 wat tests, 0 failed (was 331 pre-arc-029).

# 3. Proof 002 still produces the same numbers.
cargo test --release --features proof-002 --test proof_002

# 4. Proof 003 now runnable (proofs lane writes the pair file).
ls wat-tests-integ/proof/003-thinker-significance/  # the proofs lane fills this in.
```

---

## Total estimate

- Slice 1: 30 minutes (shim refactor + proof 002 verify)
- Slice 2: 1.5 hours (service + smoke tests)
- Slice 3: 1 hour (INSCRIPTION + status flips)

**~3 hours** = a half-morning of focused work. Same shape as arc
027 (~half a day); slightly longer because of the wat service
ceremony around HandlePool / spawn / select.

---

## Out of scope

Mirror of DESIGN's out-of-scope; reproduced here as the honest
scope ledger for the implementer:

- **Batching.** Single-row inserts; the archived rust pattern
  batched but the lab's current write volume (≈340 inserts per
  proof) doesn't justify the complexity.
- **Telemetry / gate-pattern emit callbacks.** Same rationale.
- **Read-side query APIs.** Still out of scope per arc 027. Use
  the `sqlite3` CLI.
- **WAL mode pragma.** rusqlite's default rollback journal is
  fine for single-writer workloads.
- **Multi-database support per service.** One service, one path.
- **Schema migrations.** Defer until needed.

---

## Risks

**Lifecycle correctness inside `cargo test` deftests.** The
HandlePool + spawn lifecycle is tested in wat-rs (Console,
CacheService) but the lab's `wat::test! { path, deps: [shims] }`
scaffold has not yet exercised the multi-thread service shape.
Console's tests run via `run-hermetic-ast` (subprocess fork)
because of cross-thread stdio in StringIoWriter; the rundb
service writes to its own connection, so it should not need
`run-hermetic-ast`. If kernel scheduling or test-isolation
quirks bite, the fallback path is slice-1-only — proofs use the
refactored shim directly with a per-call run_name and a single
thread. Proof 003 still works; just bypasses the service.

**`spawn` accepts a named-define entry by symbol.** Per Console
precedent, `(:wat::kernel::spawn :lab::rundb::Service/loop-entry
path rxs)` should resolve at startup-check time. If symbol
resolution fails, the diagnostic is at startup; recoverable.

**Cross-thread sends of `Resolution = (String, String, ...)`.**
Strings are `Send` in Rust; tuples of `Send` are `Send`. The
crossbeam_channel typealiases enforce `Send` at the type-check
layer. No new cross-thread surface.

**10-tuple destructuring ergonomics.** wat's tuple primitives
(`first`, `second`, `nth`) handle small tuples cleanly; a
10-tuple may push against ergonomic limits. If the dispatch
function reads as ugly, a future arc may add a `:Resolution`
struct (or a destructuring `match` on tuples). For v1, ugly is
honest — it surfaces the natural pressure for a struct shape.

---

## What this unblocks

- **Proof 003** — flips from BLOCKED to ready; produces the
  multi-window numbers that compare always-up vs sma-cross
  across the 6-year stream.
- **Proof 004** — full 6-year stream. The service spans single
  vs many clients seamlessly.
- **Future proof N — multi-thread per-broker logging.** Each
  broker holds its own `Service::Tx`; the driver serializes
  writes. Same shape regardless of client count. The service
  pattern scales.
- **Phase 7's eventual `wat-rusqlite` sibling crate** has a
  reference Service shape to either inherit or supersede.

PERSEVERARE.
