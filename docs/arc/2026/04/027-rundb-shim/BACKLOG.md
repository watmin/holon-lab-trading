# lab arc 027 — RunDb shim — BACKLOG

**Shape:** three slices. Rust shim + Cargo dep first; wat wrapper
second; smoke test + INSCRIPTION third. Total estimate: half a day.

This arc is the **infra-lane handoff** from the proofs-lane. The
proofs lane (this Claude's session named "proofs") opens stub
proofs that name their infra deps; the infra lane (separate session)
ships them as arcs. Coordination is via disk — DESIGN.md states
the spec; implementation flips status from `ready` to `shipped` and
adds INSCRIPTION; downstream proofs flip from `BLOCKED` to `ready`.

---

## Slice 1 — Rust shim + Cargo dep

**Status: shipped 2026-04-25.**

`Cargo.toml` — append to `[dependencies]`:

```toml
rusqlite = { version = "0.31", features = ["bundled"] }
```

`src/shims.rs` — add the `WatRunDb` newtype + `#[wat_dispatch]`
impl block. Same in-crate pattern as `WatCandleStream` already in
the file.

```rust
pub struct WatRunDb {
    conn: Connection,
    run_name: String,
}

#[wat_dispatch(path = ":rust::lab::RunDb", scope = "thread_owned")]
impl WatRunDb {
    pub fn open(path: String, run_name: String) -> Self {
        // open or create at path; ensure schema; bind run_name.
        // Construction errors panic with diagnostic per
        // feedback_shim_panic_vs_option.
    }

    pub fn log_paper(
        &mut self,
        thinker: String, predictor: String,
        paper_id: i64, direction: String,
        opened_at: i64, resolved_at: i64,
        state: String, residue: f64, loss: f64,
    ) {
        // single INSERT, auto-commit. Per-call rusqlite errors
        // panic in v1; future arc returns Result<()>.
    }

    pub fn close(&mut self) {
        // Connection close; Drop also handles it.
    }
}
```

Schema creation at `open`:

```sql
CREATE TABLE IF NOT EXISTS paper_resolutions (
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
);
```

Verify: `cargo build --release` clean.

**Estimated cost:** ~120 LOC + Cargo.toml line. ~2 hours.

---

## Slice 2 — wat wrapper

**Status: shipped 2026-04-25.**

`wat/io/RunDb.wat` — typealias + thin define wrappers, same shape
as `wat/io/CandleStream.wat`:

```scheme
(:wat::core::use! :rust::lab::RunDb)
(:wat::core::typealias :lab::rundb::RunDb :rust::lab::RunDb)

(:wat::core::define
  (:lab::rundb::open
    (path :String) (run-name :String)
    -> :lab::rundb::RunDb)
  (:rust::lab::RunDb::open path run-name))

(:wat::core::define
  (:lab::rundb::log-paper
    (db :lab::rundb::RunDb)
    (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String)
    (residue :f64) (loss :f64)
    -> :())
  (:rust::lab::RunDb::log-paper db thinker predictor paper-id direction
                                 opened-at resolved-at state residue loss))

(:wat::core::define
  (:lab::rundb::close
    (db :lab::rundb::RunDb)
    -> :())
  (:rust::lab::RunDb::close db))
```

`wat/main.wat` — add load line in Phase 0 section (near
`io/CandleStream.wat`):

```scheme
(:wat::load-file! "io/RunDb.wat")
```

**Estimated cost:** ~30 LOC. ~30 minutes.

---

## Slice 3 — Smoke test + INSCRIPTION

**Status: shipped 2026-04-25.**

`wat-tests/io/RunDb.wat` — three deftests in the always-run
suite. SQLite roundtrip is fast (<1 second per test), so this is
NOT gated behind a feature — it lives in `wat-tests/` and runs
on every `cargo test --test test`.

```scheme
;; Default-prelude — no load needed; the deps mechanism
;; auto-registers wat/io/RunDb.wat via the shim's wat_sources()
;; (post-arc-054 idempotent redeclaration handles dual-source).
(:wat::test::make-deftest :deftest ())

(:deftest :trading::test::io::rundb::test-open-creates-schema
  (:wat::core::let*
    (((db :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-001.db" "test-run"))
     ((_ :()) (:lab::rundb::close db)))
    ;; Reopening should not error → schema persists.
    (:wat::core::let*
      (((db2 :lab::rundb::RunDb)
        (:lab::rundb::open "/tmp/rundb-test-001.db" "test-run-2")))
      (:lab::rundb::close db2))
    (:wat::test::assert-eq true true)))

(:deftest :trading::test::io::rundb::test-log-paper-round-trip
  ;; Log one row, close, reopen, verify (TBD: needs a query API
  ;; to verify; v1 has no read API. For now, just assert that
  ;; log-paper doesn't crash. Future arc adds read API + tighter
  ;; round-trip assertion.)
  (:wat::core::let*
    (((db :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-002.db" "test-run-rt"))
     ((_ :()) (:lab::rundb::log-paper db "always-up" "cosine"
                                       1 "Up" 100 388 "Grace" 0.04 0.0))
     ((_ :()) (:lab::rundb::close db)))
    (:wat::test::assert-eq true true)))

(:deftest :trading::test::io::rundb::test-multiple-rows
  (:wat::core::let*
    (((db :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-003.db" "test-run-multi")))
    ;; Log 10 rows in a tight loop. No crash = pass.
    ;; (foldl over a vec of 10 ids would be cleaner; this is the
    ;; minimum-viable shape.)
    ...))
```

Smoke tests live under `wat-tests/io/` next to the existing
`CandleStream.wat`.

INSCRIPTION.md captures:
- LOC delta per slice (Rust + wat).
- Test count delta (lab wat-tests goes 328 → 331).
- Confirmation that proof 002 can now proceed.

`docs/proofs/2026/04/002-thinker-baseline/PROOF.md` — flip status
from `BLOCKED on arc 027` to `ready`.

**Estimated cost:** ~60 LOC + 3 tests. ~1.5 hours.

---

## Verification end-to-end

After all three slices land:

```bash
cargo test --release --test test 2>&1 | grep rundb
```

Should show three deftests passing. Lab wat tests 328 → 331.

```bash
sqlite3 /tmp/rundb-test-002.db "SELECT * FROM paper_resolutions;"
```

Should show one row with the values from the round-trip test.

The proofs-lane consumer (proof 002) then writes a supporting
program that uses the shim and produces real numbers.

---

## Total estimate

- Slice 1: 2 hours (Rust shim)
- Slice 2: 30 minutes (wat wrapper)
- Slice 3: 1.5 hours (smoke tests + INSCRIPTION)

**~half a day.** Lighter than arc 026's 21 days; lighter than arc
025's 6 days. Shim arcs follow this small shape.

---

## Out of scope

- **Batched writes / driver thread / CSP shape.** Phase 7
  `wat-rusqlite` work.
- **Multi-program shared access.** Phase 7 work.
- **Read APIs.** v1 is write-only; queries happen via `sqlite3`
  CLI out-of-band. Future arc when a wat consumer surfaces.
- **Schema migrations.** Defer until needed.
- **Result-typed errors.** v1 panics; future arc adds Option/Result.

---

## Risks

**SQLite filesystem behavior.** Tests write to `/tmp/`; assume
that's writable. If not, slice 3 fails loudly.

**rusqlite version compatibility.** Pinning to 0.31 (matches
archived); if the archived enterprise's rusqlite features have
shifted in the wat-rs ecosystem, watch for build issues. Bundled
sqlite avoids system-libsqlite version mismatches.

**Schema collisions if the test DB persists across runs.** The
smoke tests use `/tmp/rundb-test-NNN.db`; if a prior run leaves a
DB with conflicting rows under the same `(run_name, paper_id)`
PRIMARY KEY, INSERT will fail. Slice 3 should `unlink` the test
DB at the start of each test to ensure idempotent runs (or use
`/tmp/<unique>.db` with a per-test discriminator).

---

## What this unblocks

- Proof 002 stub flips to ready.
- Proof 003 (sma-cross vs always-up comparison) becomes trivial.
- Proof 004 (full 6-year stream) just calls log-paper at scale.
- Phase 7's eventual `wat-rusqlite` crate has a working v1 to
  reference / inherit / supersede.

PERSEVERARE.
