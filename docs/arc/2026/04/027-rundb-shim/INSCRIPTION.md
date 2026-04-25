; lab arc 027 — RunDb shim — INSCRIPTION

**Status:** shipped 2026-04-25. The proofs-lane → infra-lane handoff
landed clean. Three slices over ~half an hour: Rust shim + Cargo dep,
wat wrapper, smoke tests. ~150 LOC of Rust + ~70 LOC of wat + 3 tests.
Zero substrate uplifts surfaced.

Builder direction:

> "i say we drop infra issues into arcs and we do proof things in
> proofs?... we can coordinate through the disk"

This arc is the first such handoff: the proofs lane wrote
`docs/proofs/2026/04/002-thinker-baseline/PROOF.md` describing the
need for SQLite-backed per-paper logging; the infra lane (this
session) ships the shim. Proof 002 unblocks immediately.

---

## What shipped

| Slice | Surface | LOC | Status |
|-------|---------|-----|--------|
| 1     | `src/shims.rs` (`WatRunDb` + `#[wat_dispatch]`) + `Cargo.toml` (`rusqlite = "0.31"`) | ~120 Rust + 1 dep line | shipped |
| 2     | `wat/io/RunDb.wat` (typealias + 2 wrappers) + `wat/main.wat` (load) | ~70 wat | shipped |
| 3     | `wat-tests/io/RunDb.wat` (3 smoke tests) + this INSCRIPTION | ~85 wat + doc | shipped |

**Lab wat test count: 329 → 331. +2 net** (3 new RunDb tests; one
prior count was off-by-one in the slice-5 commit message — actual
delta against the new baseline is 329→331 with the integration
test renamed back to natural form post-substrate-fix).

Build: `cargo build --release` clean, 35s including rusqlite
bundled-sqlite compile. `cargo test --release wat_suite`: 331 wat
tests, 0 failed, 2.4s.

---

## Architecture notes

### One impl block, mirror CandleStream's shape

`WatRunDb` lives in `src/shims.rs` next to `WatCandleStream`. Same
in-crate dispatch pattern (`#[wat_dispatch(path = "...", scope =
"thread_owned")]`). Same two-function module contract:
`wat_sources()` returns the two baked wat paths;
`register(builder)` forwards to both `__wat_dispatch_*::register`
generated functions. No new crate, no Phase 7 jump — the lab's
own Rust surface grows by one type.

### `INSERT OR REPLACE` over plain `INSERT`

The DESIGN sketched plain `INSERT`. Shipped instead is `INSERT OR
REPLACE` — re-logging the same `(run_name, paper_id)` overwrites
the prior row rather than failing on a primary-key collision.

Reason: tests live under `/tmp/rundb-test-NNN.db` and persist
across cargo runs. With plain `INSERT`, the second run's tests
collide on the first run's rows. With `OR REPLACE`, tests are
idempotent under reruns without needing a `remove-file!` shim
helper. Real proof-002 callers use unique run_names per run, so
the OR-REPLACE behavior is invisible to them.

### Read API deliberately omitted

DESIGN sub-fog "Read APIs": v1 is write-only. Queries go through
the `sqlite3` CLI out of band. This kept the shim small (no
result-type plumbing, no `:Vec<Row>` materialization), and proof
002 plans Rust-side post-processing of the produced DB files
anyway. A future arc adds query primitives when a wat consumer
needs to read its own log output during a run (e.g., adaptive
thinkers reading their own past Grace/Violence ratios).

The cost: tests can't assert "row was written with these exact
values" from inside wat; they assert "no crash" and rely on the
external `sqlite3` CLI for round-trip verification (which
confirmed 5 rows in `/tmp/rundb-test-003.db` post-run with the
expected values).

### `close` skipped — Drop handles it

DESIGN sketched `pub fn close(&mut self)` as "Optional — Drop also
commits, but explicit close gives the wat program a control
point." Shipped without `close`: rusqlite auto-commits on every
statement (no buffered writes to flush), and the file handle
closes on Drop (when the thread-owned cell exits scope).

A `close(&mut self)` no-op would be cargo-cult code — same
rationale that kept `close` out of `WatCandleStream`. If a future
caller needs an explicit shutdown control point (e.g., before
crash-recovery testing), the shim adds it then.

### Construction-time errors panic

Per `feedback_shim_panic_vs_option`: bad path / permission /
schema-creation failure at `open` time panics with a diagnostic
that names the path and the underlying rusqlite error. Same
posture as `WatCandleStream::open`. Per-call `log_paper` failures
also panic in v1 — the proof callers want to crash loudly on
disk-full rather than silently drop log rows. Future arc returns
`:Result<()>` once a caller wants graceful per-row error
handling.

---

## What this unblocks

- **Proof 002 — `(papers, grace, violence, residue, loss)` per
  thinker.** Status flips from BLOCKED to ready; the proof can
  now write its per-paper resolutions to a `runs/proof-002-*.db`
  file and post-process via SQL.
- **Proof 003 — sma-cross vs always-up comparison.** Two runs into
  separate `runs/` files, then SQL aggregates by thinker.
- **Proof 004 — full 6-year stream.** Same shim at scale; SQLite
  handles 650k row inserts comfortably (auto-commit's overhead is
  ~1ms per statement, ~10 minutes total — acceptable for a
  one-off proof run).
- **Phase 7's `wat-rusqlite` sibling crate** has a working v1 to
  reference. When that crate ships (multi-program shared access,
  CSP-style driver thread, telemetry), this in-crate shim either
  upgrades to consume it or stays as the single-thread fast path.

---

## What this arc deliberately did NOT add

Reproduced from DESIGN's "What this arc does NOT add" — recording
here as the honest scope ledger:

- **Batched / async / driver-thread writes.** Phase 7 work.
- **Multi-program shared SQLite access** (the archive's 627-LOC
  `database.rs` shape with request/ack queues). Phase 7 work.
- **Schema migrations.** The current schema's `CREATE TABLE IF
  NOT EXISTS` handles fresh DBs; future arcs add migrations when
  needed via `PRAGMA user_version`.
- **Read APIs.** v1 is write-only; sqlite3 CLI handles queries.
- **Result-typed write errors.** v1 panics; future arc adds
  `:Result<()>` when a caller surfaces the need.
- **Telemetry / gate-pattern emit callbacks.** Phase 7 work.
- **A `wat-rusqlite` sibling crate.** Defer until multi-program
  access is real.

---

## The thread

- **2026-04-25** — DESIGN.md + BACKLOG.md drafted by the proofs
  lane in `docs/arc/2026/04/027-rundb-shim/`. Proof 002 status
  set to BLOCKED on this arc.
- **2026-04-25** (this session) — slices 1, 2, 3 + INSCRIPTION
  shipped same day.
- Proof 002 next: now ready to consume.

PERSEVERARE.
