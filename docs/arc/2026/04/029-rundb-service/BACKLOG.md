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

## Slice 1 — Refactor `WatRunDb` (per-message `run_name` + variant-aligned naming)

**Status: shipped 2026-04-25.**

`src/shims.rs` — three small edits:

1. **Struct:** drop the `run_name: String` field.

```rust
pub struct WatRunDb {
    conn: Connection,
    // run_name removed
}
```

2. **`open(path)` — drop the `run_name` parameter.** Schema
   stays auto-installed for backward compatibility with proof
   002's direct-shim usage. Slice 2 will add `execute_ddl` and
   move schema ownership into wat for service-mode callers.

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

3. **`log_paper(...) → log_paper_resolved(...)`** — rename to
   align with the slice-2 `LogEntry::PaperResolved` variant.
   Add `run_name` as the first arg.

```rust
#[allow(clippy::too_many_arguments)]
pub fn log_paper_resolved(
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
            run_name, thinker, predictor, paper_id, direction,
            opened_at, resolved_at, state, residue, loss,
        ],
    ).unwrap_or_else(|e| {
        panic!(":rust::lab::RunDb::log-paper-resolved: insert failed: {e}")
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
  (:lab::rundb::log-paper-resolved              ; ← renamed
    (db :lab::rundb::RunDb)
    (run-name :String)                          ; ← new arg
    (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String)
    (residue :f64) (loss :f64)
    -> :())
  (:rust::lab::RunDb::log-paper-resolved
    db run-name thinker predictor paper-id direction
    opened-at resolved-at state residue loss))
```

Doc comments at the top of `wat/io/RunDb.wat` — update the
example block to show per-call run_name and the new method
name. Schema doc unchanged.

`wat-tests/io/RunDb.wat` — three existing smoke tests need
their `open` calls trimmed and `log-paper` calls patched to
pass run_name and use the new method name. ~6 line edits
across the file.

`wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`
— **collapse to one deftest, one DB**. Per Q8 (one DB per
run, many tables/columns inside): the v0 file replaced two
deftests writing two DB files (`proof-002-always-up-<epoch>.db`
+ `proof-002-sma-cross-<epoch>.db`) with one deftest writing
one DB (`proof-002-<epoch>.db`) carrying both thinkers'
results. The schema's `thinker` column already distinguishes
them; cross-thinker queries become `GROUP BY thinker`.

Concrete shape post-migration:

```scheme
(:deftest :trading::test::proofs::002::thinker-baseline
  (:wat::core::let*
    (((path :String) "data/btc_5m_raw.parquet")
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String) (:wat::core::i64::to-string
                            (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))
     ((db-path :String)
      (:wat::core::string::concat "runs/proof-002-" epoch-str ".db"))
     ((db :lab::rundb::RunDb) (:lab::rundb::open db-path))
     ;; Run always-up; log all outcomes with run-name "always-up-10k-<iso>".
     ;; (run-with-log calls :lab::rundb::log-paper-resolved per Outcome
     ;;  with the bound run-name + per-Outcome fields.)
     ((agg-up :trading::sim::Aggregate)
      (:trading::test::proofs::002::run-with-log
        ... db (:wat::core::string::concat "always-up-10k-" iso-str)
        "always-up" "cosine-vs-corners"))
     ;; Run sma-cross into the SAME db; different run-name distinguishes.
     ((agg-sx :trading::sim::Aggregate)
      (:trading::test::proofs::002::run-with-log
        ... db (:wat::core::string::concat "sma-cross-10k-" iso-str)
        "sma-cross" "cosine-vs-corners"))
     ((u1 :()) ;; conservation for always-up
      (:wat::test::assert-eq ...))
     ((u2 :()) ;; conservation for sma-cross
      (:wat::test::assert-eq ...))
     ((u3 :()) ;; both papers > 0
      (:wat::test::assert-eq ...)))
    (:wat::test::assert-eq true true)))
```

The helper `log-outcome` in proof 002 grows one parameter
(`run-name`) and threads it into the two `log-paper` call
sites inside its `match`. `run-with-log` grows a `run-name`
parameter that propagates to `log-outcome`.

### Verification

```bash
# 1. Lab unit tests pass — RunDb smoke tests still work.
cargo test --release --test test 2>&1 | grep -E "rundb|FAILED"

# 2. Proof 002 still passes and produces the SAME numbers.
cargo test --release --features proof-002 --test proof_002 -- --nocapture

# 3. Confirm the single freshest DB has the expected counts
#    per thinker (thinker is now a column, not a file split).
ls -t runs/proof-002-*.db | head -1 | xargs -I{} sqlite3 {} <<EOF
SELECT thinker,
       COUNT(*) AS papers,
       SUM(state='Grace') AS grace,
       SUM(state='Violence') AS violence
FROM paper_resolutions
GROUP BY thinker
ORDER BY thinker;
EOF
# Expected:
#   always-up | 34 | 0 | 34
#   sma-cross | 34 | 5 | 29
```

If proof 002's numbers shift, the refactor introduced a
behavioral change — back out and re-investigate before
proceeding to slice 2.

**LOC budget:**
- `src/shims.rs`: −1 field, +1 param, ~5 LOC delta net.
- `wat/io/RunDb.wat`: 1 param removed from open, 1 added to log-paper, doc comments refreshed. ~10 LOC delta.
- `wat-tests/io/RunDb.wat`: ~6 line edits.
- `wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`: collapse two deftests into one (~30-line restructure; let* scaffolding for both thinkers in one body). ~30 LOC delta.
- `docs/proofs/2026/04/002-thinker-baseline/PROOF.md`: addendum noting the file-split was a v0 misstep, corrected here; the originally-shipped per-thinker DBs stay on disk as historical artifacts (per `feedback_never_delete_runs`).

**Estimated cost:** ~55 LOC delta (rename adds touchpoints).
**~45 minutes** including the proof 002 verification re-run
and doc addendum.

---

## Slice 2 — `LogEntry` sum + service (batch-log + ack)

**Status: shipped 2026-04-25.** Depends on slice 1.

Three new wat files (sum + schema + service) and one shim
addition (`execute_ddl`). Mirrors the archive's
`LogEntry`/`ledger_setup`/`ledger_insert`/`database` triad
(`archived/pre-wat-native/src/types/log_entry.rs`,
`archived/pre-wat-native/src/domain/ledger.rs`,
`archived/pre-wat-native/src/programs/stdlib/database.rs`),
adapted to wat's enum + service patterns.

Architectural anchor: per Q9 + Q10, the unit of communication
is a `:lab::log::LogEntry` sum (initial variant: `PaperResolved`),
sent in confirmed batches with per-request ack channels
(CacheService-style). One thread owns the connection; N
clients each get a request-Tx + a personal ack channel.

### Step 2a — Shim grows `execute_ddl`

`src/shims.rs` — add one method to `WatRunDb`:

```rust
/// `:rust::lab::RunDb::execute-ddl db ddl-str` — run a
/// DDL string (CREATE TABLE, CREATE INDEX, etc.). Used by
/// the service's loop-entry to install schemas from
/// :lab::log::all-schemas at driver startup. Idempotent —
/// every schema string uses CREATE TABLE IF NOT EXISTS so
/// re-installs are no-ops.
pub fn execute_ddl(&mut self, ddl_str: String) {
    self.conn.execute_batch(&ddl_str).unwrap_or_else(|e| {
        panic!(":rust::lab::RunDb::execute-ddl: {e}")
    });
}
```

`wat/io/RunDb.wat` — mirror:

```scheme
(:wat::core::define
  (:lab::rundb::execute-ddl
    (db :lab::rundb::RunDb)
    (ddl-str :String)
    -> :())
  (:rust::lab::RunDb::execute-ddl db ddl-str))
```

Note: slice 1 leaves the auto-schema-on-open path intact for
backward compat with proof 002. The service uses
`execute_ddl` to install ALL known schemas at startup; the
auto-installed `paper_resolutions` is then redundantly
re-installed (CREATE TABLE IF NOT EXISTS = no-op).
A future arc removes auto-schema-on-open once all callers
go through wat-managed schemas.

### Step 2b — `wat/io/log/LogEntry.wat` — the sum type

```scheme
;; :lab::log::LogEntry — the unit of communication crossing
;; the rundb service boundary. Discriminated union, grows
;; variant-by-variant as proofs surface new "kinds of things
;; that happened".
;;
;; v1: one variant — PaperResolved. Carries the same payload
;; arc 027's log-paper accepted, with run_name promoted to a
;; field per Q8/arc-029.
;;
;; Future variants (when proofs need them):
;;   - Telemetry { namespace, id, dimensions, timestamp_ns,
;;                  metric_name, metric_value, metric_unit }
;;     CloudWatch-style; for cosine-similarity tracking,
;;     learning-rate observation, latency histograms.
;;   - BrokerSnapshot { ... }
;;   - Diagnostic { candle, throughput, ... per-candle perf }
;;   - PhaseSnapshot { ... }
;;   - ObserverSnapshot { ... }

(:wat::core::enum :lab::log::LogEntry
  (PaperResolved
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64)))
```

### Step 2c — `wat/io/log/schema.wat` — DDL constants + registry

```scheme
;; :lab::log::schema-* — per-variant DDL strings. Each is the
;; CREATE TABLE IF NOT EXISTS for one variant's destination
;; table. Read-locality: schema lives next to the variant it
;; describes (in the file pair LogEntry.wat / schema.wat).
;;
;; :lab::log::all-schemas — the registry. The service iterates
;; this at startup and execute-ddl's each. Adding a variant =
;; add a string + register it here. No service code changes.

(:wat::core::define
  (:lab::log::schema-paper-resolved -> :String)
  "CREATE TABLE IF NOT EXISTS paper_resolutions (
     run_name     TEXT NOT NULL,
     thinker      TEXT NOT NULL,
     predictor    TEXT NOT NULL,
     paper_id     INTEGER NOT NULL,
     direction    TEXT NOT NULL,
     opened_at    INTEGER NOT NULL,
     resolved_at  INTEGER NOT NULL,
     state        TEXT NOT NULL,
     residue      REAL NOT NULL,
     loss         REAL NOT NULL,
     PRIMARY KEY (run_name, paper_id)
   );")

(:wat::core::define
  (:lab::log::all-schemas -> :Vec<String>)
  (:wat::core::vec :String
    (:lab::log::schema-paper-resolved)
    ;; future: (:lab::log::schema-telemetry),
    ;;         (:lab::log::schema-broker-snapshot), ...
    ))
```

### Step 2d — `wat/io/RunDbService.wat`

#### Protocol typealiases

```scheme
(:wat::core::typealias :lab::rundb::Service::AckTx
  :rust::crossbeam_channel::Sender<()>)
(:wat::core::typealias :lab::rundb::Service::AckRx
  :rust::crossbeam_channel::Receiver<()>)
;; A Request is a batch of LogEntries + the ack channel the
;; client wants the driver to signal on after commit.
(:wat::core::typealias :lab::rundb::Service::Request
  :(Vec<lab::log::LogEntry>, lab::rundb::Service::AckTx))
(:wat::core::typealias :lab::rundb::Service::ReqTx
  :rust::crossbeam_channel::Sender<lab::rundb::Service::Request>)
(:wat::core::typealias :lab::rundb::Service::ReqRx
  :rust::crossbeam_channel::Receiver<lab::rundb::Service::Request>)
```

#### Dispatcher (per-variant routing — wat-side, per Q9)

```scheme
(:wat::core::define
  (:lab::rundb::Service/dispatch
    (db :lab::rundb::RunDb)
    (entry :lab::log::LogEntry)
    -> :())
  (:wat::core::match entry -> :()
    ((PaperResolved run-name thinker predictor paper-id
                    direction opened-at resolved-at
                    state residue loss)
      (:lab::rundb::log-paper-resolved
        db run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss))
    ;; future variant arms add here:
    ;;   ((Telemetry namespace id dimensions ts name value unit)
    ;;     (:lab::rundb::log-telemetry db namespace id ...))
    ))
```

#### Driver entry — opens, installs schemas, enters loop

Per CacheService precedent: `RunDb` is `thread_owned`, so
`open` MUST happen in the driver's thread.

```scheme
(:wat::core::define
  (:lab::rundb::Service/loop-entry
    (path :String)
    (rxs :Vec<lab::rundb::Service::ReqRx>)
    -> :())
  (:wat::core::let*
    (((db :lab::rundb::RunDb) (:lab::rundb::open path))
     ;; Install every known schema. Idempotent.
     ((_install :())
      (:wat::core::foldl (:lab::log::all-schemas) ()
        (:wat::core::lambda
          ((acc :()) (ddl :String) -> :())
          (:lab::rundb::execute-ddl db ddl)))))
    (:lab::rundb::Service/loop db rxs)))
```

#### Recursive select loop with confirmed batch + ack

```scheme
(:wat::core::define
  (:lab::rundb::Service/loop
    (db :lab::rundb::RunDb)
    (rxs :Vec<lab::rundb::Service::ReqRx>)
    -> :())
  (:wat::core::if (:wat::core::empty? rxs) -> :()
    ()
    (:wat::core::let*
      (((chosen :(i64,Option<lab::rundb::Service::Request>))
        (:wat::kernel::select rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<lab::rundb::Service::Request>)
        (:wat::core::second chosen)))
      (:wat::core::match maybe -> :()
        ((Some req)
          (:wat::core::let*
            (((entries :Vec<lab::log::LogEntry>)
              (:wat::core::first req))
             ((ack-tx :lab::rundb::Service::AckTx)
              (:wat::core::second req))
             ;; Dispatch each entry to its table. v1 ships
             ;; without an explicit BEGIN/COMMIT — auto-commit
             ;; per dispatch. A future arc wraps each batch in
             ;; one transaction once measurement shows the
             ;; commit overhead is the bottleneck.
             ((_apply :())
              (:wat::core::foldl entries ()
                (:wat::core::lambda
                  ((acc :()) (e :lab::log::LogEntry) -> :())
                  (:lab::rundb::Service/dispatch db e))))
             ;; Ack — driver-side send swallows :None if the
             ;; client dropped its ack-rx before we got here.
             ((_ :Option<()>) (:wat::kernel::send ack-tx ())))
            (:lab::rundb::Service/loop db rxs)))
        (:None
          (:lab::rundb::Service/loop
            db
            (:wat::std::list::remove-at rxs idx)))))))
```

(Open question for implementation: wat's `BEGIN`/`COMMIT`
wrapping. If `execute_ddl` accepts arbitrary SQL, the wat
side could `(:lab::rundb::execute-ddl db "BEGIN")` /
`(:lab::rundb::execute-ddl db "COMMIT")` around the foldl —
keeps txn semantics in wat. Defer to slice 2 implementer
to land OR defer to slice 4 (a follow-up perf pass) once
we have a benchmark.)

#### Client helper — single primitive, batch-only

```scheme
(:wat::core::define
  (:lab::rundb::Service/batch-log
    (req-tx :lab::rundb::Service::ReqTx)
    (ack-tx :lab::rundb::Service::AckTx)   ; client-owned, reused
    (ack-rx :lab::rundb::Service::AckRx)   ; client-owned, reused
    (entries :Vec<lab::log::LogEntry>)
    -> :())
  (:wat::core::let*
    (((req :lab::rundb::Service::Request)
      (:wat::core::tuple entries ack-tx))
     ;; If driver is gone, send→:None and recv→:None below
     ;; collapses; caller observes silent return per Cache-
     ;; Service precedent.
     ((_ :Option<()>) (:wat::kernel::send req-tx req))
     ((_ :Option<()>) (:wat::kernel::recv ack-rx)))
    ()))
```

Per Q10: **one primitive, no sugar.** Single-entry callers
pass `(:wat::core::vec :lab::log::LogEntry entry)`.

#### Setup

```scheme
(:wat::core::define
  (:lab::rundb::Service
    (path :String)
    (count :i64)
    -> :(wat::kernel::HandlePool<lab::rundb::Service::ReqTx>,
         wat::kernel::ProgramHandle<()>))
  (:wat::core::let*
    (((pairs :Vec<(lab::rundb::Service::ReqTx,
                   lab::rundb::Service::ReqRx)>)
      (:wat::core::map (:wat::core::range 0 count)
        (:wat::core::lambda
          ((_i :i64)
           -> :(lab::rundb::Service::ReqTx,
                lab::rundb::Service::ReqRx))
          (:wat::kernel::make-bounded-queue
            :lab::rundb::Service::Request 1))))
     ((req-txs :Vec<lab::rundb::Service::ReqTx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :(lab::rundb::Service::ReqTx,
                lab::rundb::Service::ReqRx))
           -> :lab::rundb::Service::ReqTx)
          (:wat::core::first p))))
     ((req-rxs :Vec<lab::rundb::Service::ReqRx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :(lab::rundb::Service::ReqTx,
                lab::rundb::Service::ReqRx))
           -> :lab::rundb::Service::ReqRx)
          (:wat::core::second p))))
     ((pool :wat::kernel::HandlePool<lab::rundb::Service::ReqTx>)
      (:wat::kernel::HandlePool::new "RunDbService" req-txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :lab::rundb::Service/loop-entry path req-rxs)))
    (:wat::core::tuple pool driver)))
```

### Step 2e — Wire new wat files into `src/shims.rs::wat_sources()`

```rust
pub fn wat_sources() -> &'static [WatSource] {
    static FILES: &[WatSource] = &[
        WatSource { path: "io/CandleStream.wat",
                    source: include_str!("../wat/io/CandleStream.wat") },
        WatSource { path: "io/RunDb.wat",
                    source: include_str!("../wat/io/RunDb.wat") },
        WatSource { path: "io/log/LogEntry.wat",                          // ← new
                    source: include_str!("../wat/io/log/LogEntry.wat") },
        WatSource { path: "io/log/schema.wat",                            // ← new
                    source: include_str!("../wat/io/log/schema.wat") },
        WatSource { path: "io/RunDbService.wat",                          // ← new
                    source: include_str!("../wat/io/RunDbService.wat") },
    ];
    FILES
}
```

### Step 2f — Smoke tests

`wat-tests/io/RunDbService.wat` — three deftests:

1. **Single-client batch round-trip.** Spawn service with
   N=1, pop one handle, build one client ack channel,
   `batch-log` a Vec of 3 PaperResolved entries (one per
   distinct `(run_name, paper_id)`), drop handle, join
   driver. Verify via `sqlite3` CLI: 3 rows in
   `paper_resolutions` with the expected `run_name` /
   `thinker` / `state` / `residue` / `loss` values.
2. **Multi-client fan-in.** Spawn N=3, three worker threads
   each holding one handle, each `batch-log`s a distinct
   `run_name`'s entries. Verify all 3 batches landed
   atomically (no torn writes mid-batch); the multi-client
   test in particular demonstrates ONE DB receiving
   distinct run_names from concurrent writers under one
   schema (per Q8).
3. **Lifecycle on disconnect.** Spawn N=2, distribute
   handles, immediately drop both, join driver. Verify
   driver exited cleanly (no panic in join), no rows
   written.

Each deftest writes to a unique `/tmp/rundb-service-test-NNN.db`
to avoid cross-test interference. Same CSP-test shape as
`wat-rs/wat-tests/std/service/Console.wat` modulo the
run-hermetic-ast wrapper (rundb writes to its own file; no
cross-thread stdio issue, so the in-process test runner
suffices).

### Verification

```bash
cargo test --release --test test 2>&1 | grep -E "rundb|RunDb|FAILED"
# Lab wat tests count climbs by 3 (the new RunDbService smoke tests).
```

**LOC budget:**
- `src/shims.rs`: 1 new method (~10 LOC) + 3 lines in `wat_sources()`.
- `wat/io/RunDb.wat`: 1 new wrapper (~8 LOC) for execute-ddl.
- `wat/io/log/LogEntry.wat`: enum + doc (~50 LOC).
- `wat/io/log/schema.wat`: schema constant + registry + doc (~50 LOC).
- `wat/io/RunDbService.wat`: typealiases (~25 LOC) + dispatcher (~20 LOC) + loop-entry (~25 LOC) + loop (~50 LOC) + batch-log helper (~15 LOC) + setup (~50 LOC) + doc comments (~50 LOC). **~235 LOC.**
- `wat-tests/io/RunDbService.wat`: ~120 LOC for 3 deftests.

**Estimated cost:** ~485 LOC + 3 tests. **~3 hours.**

---

## Slice 3 — INSCRIPTION + downstream status flip

**Status: not started.** Depends on slices 1 and 2.

`docs/arc/2026/04/029-rundb-service/INSCRIPTION.md` — same shape
as arc 027's INSCRIPTION:

- "What shipped" table (slice / surface / LOC / status).
- Lab wat test count delta (current 331 → expected 334).
- Architecture notes: divergences from DESIGN, decisions made
  during implementation. Capture if any of:
  - LogEntry sum needed a wat-rs substrate uplift (e.g.,
    enum with multi-arity constructors landed via an arc).
  - Variant pattern-match destructured cleanly OR needed
    `:wat::core::nth` workarounds (suggests struct shape
    rather than tuple-as-payload for future variants).
  - BEGIN/COMMIT wrapping in wat (Service/loop) shipped or
    deferred.
- "What this unblocks" — proof 003 status, forward implications.
- "What this arc deliberately did NOT add" — mirror DESIGN's
  out-of-scope (telemetry rate-gate emit, BEGIN/COMMIT
  batching wrapper, read APIs, generic execute(sql, params)).
- "The thread" — date timeline.

`docs/proofs/2026/04/003-thinker-significance/PROOF.md` — flip
status header from `BLOCKED on lab arc 029` to `ready — pair
file forthcoming`. The proofs lane writes the supporting
program at `wat-tests-integ/proof/003-thinker-significance/`
using `:lab::rundb::Service` + `:lab::log::LogEntry::PaperResolved`.

`docs/proofs/2026/04/002-thinker-baseline/PROOF.md` already
carries a closing addendum (added during arc 029's design
iteration) noting the file-split was a v0 misstep. After
slice 1 verification confirms the same numbers, append a
brief note that the migration landed.

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

- Slice 1: 45 minutes (shim refactor + rename + proof 002 migration to one DB)
- Slice 2: 3 hours (LogEntry + schema + service + smoke tests)
- Slice 3: 1 hour (INSCRIPTION + status flips)

**~5 hours** = most of a day of focused work. Substantially
larger than arc 027 (~half a day) because of the LogEntry-sum
+ batch+ack architecture (~485 LOC slice 2 alone). The bulk
of slice 2 is the wat-side dispatcher + DDL registry + the
batch+ack loop — patterns the substrate already supports but
the lab is wiring up for the first time.

---

## Out of scope

Mirror of DESIGN's out-of-scope; reproduced here as the honest
scope ledger for the implementer:

- **More LogEntry variants.** Only `PaperResolved` ships in
  this arc. `Telemetry`, `BrokerSnapshot`, `Diagnostic`, etc.
  land when consumer proofs surface the need.
- **Telemetry rate-gate emit callbacks** (the archive's
  `make_rate_gate(Duration)` + driver-side `emit` closure).
  No telemetry consumers yet.
- **BEGIN/COMMIT batching wrapper.** Per-batch transaction
  shipping is open in slice 2 (implementer's call). If
  deferred, a follow-up perf arc adds it once measurement
  shows commit overhead is the bottleneck.
- **Read-side query APIs.** Still out of scope per arc 027.
  Use the `sqlite3` CLI.
- **WAL mode pragma.** rusqlite's default rollback journal is
  fine for single-writer workloads.
- **Multi-database support per service.** One service, one path.
- **Schema migrations.** Defer until needed.
- **Generic `RunDb::execute(sql, params)` with heterogeneous
  Vec<Param>.** Future arc when the per-variant shim method
  count makes codegen tedious (probably ≥10 variants).

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

**Cross-thread sends of `Request = (Vec<LogEntry>, AckTx)`.**
LogEntry's PaperResolved variant carries Strings + i64s + f64s
— all `Send`. AckTx is a crossbeam Sender — `Send`. The
typealiases enforce `Send` at the type-check layer. No new
cross-thread surface.

**LogEntry pattern-match destructuring ergonomics.** Wat's
enum match should destructure variant fields cleanly (same
shape as `:trading::sim::PositionState::Grace _r`). If the
dispatcher reads ugly for a 10-field variant (PaperResolved),
the implementer should consider:
- Reordering to most-likely-changed-first.
- Capturing as a single bound variable + accessing fields via
  generated accessors (if wat's enum codegen produces them).

If neither path is clean, fall back to a `:PaperResolvedRow`
struct as the variant payload — match `(PaperResolved row)`,
then destructure `row` field-by-field via accessors. Capture
the call in INSCRIPTION.

**`:lab::log::all-schemas` evaluation.** The service's
loop-entry calls `(:lab::log::all-schemas)` once at startup.
If wat treats this as a *function* (re-evaluated each call)
vs a *constant* (memoized at compile/freeze), behavior is the
same here (called once) but matters for future hot-path
callers. Define as a top-level `define` returning a Vec —
foldl iterates fine.

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
