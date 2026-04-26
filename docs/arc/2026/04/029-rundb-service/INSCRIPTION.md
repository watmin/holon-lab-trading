# lab arc 029 — RunDb service — INSCRIPTION

**Status:** shipped 2026-04-25. Three slices: per-message
`run_name` shim refactor (slice 1), LogEntry sum + CSP service
with batch+ack (slice 2), this INSCRIPTION + downstream status
flips (slice 3). ~640 LOC of wat + ~30 LOC of Rust + 3 new
smoke tests.

Builder direction (mid-implementation, after the proofs lane
tried to hack 10 sequential `:lab::rundb::open` calls into proof
003):

> "hold on - we need a db service for this... go study the
> archived rust and wat's service pattern"

> "i think we should have one database per run with as many
> tables as we need... that db can have as many tables as you
> want"

> "do you wanna review how the archived rust did database
> writes?.. the request pattern?.... it was very nice... i
> want to repeat that... the metrics we had and the records-
> as-logs system was phenomenal - we modeled it like a mini
> cloudwatch"

> "batch with ack - the perf matters"

> "only batch - if the user has one message its an array-of-one"

The arc closes the shape gap before more proofs build on the
arc-027 shim's per-handle `run_name` binding (a wedge shape that
worked for proof 002's one-window case but couldn't scale to
proof 003's 10-window comparison).

---

## What shipped

| Slice | Surface | LOC | Status |
|-------|---------|-----|--------|
| 1     | Shim refactor — `run_name` from struct field to per-call param; `log_paper` → `log_paper_resolved` rename. Proof 002 collapses to one deftest writing one DB (per Q8). | ~30 Rust + ~30 wat delta | shipped |
| 2     | `wat/io/log/LogEntry.wat` (enum), `wat/io/log/schema.wat` (DDL constants + registry), `wat/io/RunDbService.wat` (CSP service), `execute_ddl` shim addition, 4 typealiases (`ReqChannel`, `ReqTxPool`, `Spawn`, `AckChannel`), 3 smoke tests. | ~510 wat + ~10 Rust | shipped |
| 3     | This INSCRIPTION + proof 003 status flip + BACKLOG slice statuses. | doc-only | shipped |

**Lab wat test count: 331 → 334.** +3 from RunDbService smoke
tests; proof 002's one-deftest/one-DB consolidation kept its
test count the same (one deftest now does what two used to).

Verified end-to-end:
- proof 002 produces the same per-thinker numbers in the new
  consolidated DB shape (`always-up | 34 | 0 | 34`,
  `sma-cross | 34 | 5 | 29`).
- service smoke tests' SQL output matches what the deftests
  sent (single-batch 3 rows, fan-in 3 rows under distinct
  run_names, disconnect 0 rows).

---

## Architecture notes

### Type aliases for tuple-return shapes (builder direction)

Four new aliases at `:lab::rundb::Service::*`:
- `ReqChannel` — `:(ReqTx, ReqRx)` — the pair
  `make-bounded-queue :Service::Request 1` returns; the setup
  function builds N of these and splits into pool + driver-rxs
- `ReqTxPool` — `:wat::kernel::HandlePool<ReqTx>` — the pool
  variant returned alongside the driver-handle
- `Spawn` — `:(ReqTxPool, ProgramHandle<()>)` — the pair the
  Service function returns
- `AckChannel` — `:(AckTx, AckRx)` — the pair
  `make-bounded-queue :() 1` returns when a client sets up its
  per-batch ack

The user surfaced the first three mid-slice-2 ("those type
names are awful — what's an alias we need?") and `ReqChannel`
later in the same review pass ("this looks like another type to
clean up?"). Tests + the Service signature now read against the
named pairings instead of nested generics. Cleaner reads
matter at the contract surface where readers form intuition.

A drive-by gotcha during the rename: `replace_all` on the tuple
shape clobbered the typealias's own RHS, creating
`ReqChannel = ReqChannel` — wat's cycle detector caught it
("typealias forms a cycle through the current alias graph —
refused at registration time so unification doesn't loop").
Restoring the tuple definition + verifying via
`grep -c "typealias"` resolved it; lesson recorded for future
rename passes.

### Lifetime discipline — inner-let* trick (Console pattern)

Per-thread crossbeam senders are Clone, so `(:wat::kernel::spawn
:worker tx ...)` clones into the spawned thread; the parent's
local binding stays alive until its `let*` scope exits. The
driver loop converges to empty only when EVERY ReqRx has
disconnected — which requires every parent-side ReqTx to drop
too.

The fix: the test wraps client-side bindings (popped handles,
ack channels, worker spawns + joins) inside an INNER `let*`
whose scope exits BEFORE the outer `let*`'s
`(:wat::kernel::join driver)`. Same shape as
`wat-rs/wat-tests/std/service/Console.wat` test-multi-writer.

Fell into this on the first run — multi-client test deadlocked.
Captured in test file's header comment so the next reader
doesn't repeat.

### Helper visibility — defines go in the deftest's prelude

`:wat::test::deftest` runs its body inside a hermetic-by-default
sandbox; top-level defines in the same wat file aren't visible
inside the body. Per the test-harness docs ("pass helpers via
`deps:` or inline them when a sandbox body needs them"), the
multi-client test's `:worker` define moved from the file's top
level into the deftest's prelude (the second arg to deftest).

### v1 ships without explicit BEGIN/COMMIT

DESIGN Q3 + Q10 both flagged this. Per the open-question note
in BACKLOG slice 2: defer transaction wrapping to a follow-up
perf arc that fires when measurement shows commit overhead is
the bottleneck. The current write volume (~340 inserts per
proof) makes auto-commit fine; adding BEGIN/COMMIT now would
obscure the lifecycle contract for negligible measured benefit.
The wat-side surface (`(:lab::rundb::execute-ddl db "BEGIN")`)
exists to layer the wrapping later without shim changes.

### Schema autoinstall stays in `open()`

DESIGN sketched moving schema ownership entirely into wat
(service installs from `:lab::log::all-schemas` at startup).
BACKLOG slice 1 walked this back: keep auto-schema in `open()`
for backward compat with direct-shim callers (proof 002
bypasses the service). Service-mode callers still get fresh
schemas via `execute_ddl` at driver startup; both paths use
CREATE TABLE IF NOT EXISTS so the redundant install is a no-op.
A future arc removes the auto-install once all callers go
through wat-managed schemas.

### One DB per run, many tables (Q8 — proof 002 v0 misstep)

The shipped arc-027 proof 002 split per-thinker results into
two DB files. User correction: one DB per run, distinguished
inside by columns (`thinker`, `run_name`, etc.). Slice 1
collapsed proof 002 to one deftest writing one DB at
`runs/proof-002-<epoch>.db`. The schema's `thinker` column was
always there — the v0 file-split simply ignored it. Pre-
migration per-thinker DBs stay on disk per
`feedback_never_delete_runs`.

### LogEntry as the unit of communication (Q9)

Mirrors the archive's 13-variant `LogEntry` enum
(`archived/pre-wat-native/src/types/log_entry.rs`) at a much
smaller v1 footprint: ONE variant (`PaperResolved`). The
service is generic over `LogEntry`; future variants
(`Telemetry`, `BrokerSnapshot`, `Diagnostic`, etc.) land as
new enum arms + new shim wrappers + new dispatch arms in
`Service/dispatch`. Existing matches stay correct without
modification.

The variant dispatch lives in wat (per builder direction "as
much as we can in wat"). The shim only owns typed INSERT
wrappers — one per table.

### CacheService-style request/reply, not Console fire-and-forget

DESIGN initially picked Console's fire-and-forget pattern.
Builder reframed mid-design ("batch with ack — the perf matters"):
the archive's batched send+ack pattern gives back-pressure (slow
disks slow producers) and atomic batch commits (a `Vec<LogEntry>`
becomes one transaction). v1 ships the back-pressure semantics
without the transaction wrapping — same shape, transaction
opt-in is the deferred perf pass.

---

## What this unblocks

- **Proof 003** — flipped from BLOCKED to ready. Multi-window
  comparison (`always-up` vs `sma-cross` across 10 windows
  spread over the 6-year stream) becomes a clean
  service-based supporting program: spawn one service, hand
  N ReqTx handles to N window-runners, each batches its
  outcomes under a distinct `run_name`, fan-in on one DB at
  `runs/proof-003-<epoch>.db`.
- **Proof 004** — full 6-year stream. Service spans single vs
  many clients seamlessly; the same shape works at any scale.
- **Future proof N** — per-broker logging in the multi-asset
  enterprise. Each broker holds its own ReqTx; the driver
  serializes writes. Pattern unchanged regardless of client
  count.
- **Future LogEntry variants** (Telemetry, BrokerSnapshot,
  Diagnostic) — three-step add: enum arm, schema constant +
  registry, shim wrapper + dispatch arm. No service rewire.
- **Phase 7's eventual `wat-rusqlite` sibling crate** has a
  reference Service shape to either inherit or supersede.

---

## What this arc deliberately did NOT add

Reproduced from DESIGN's "What this arc does NOT add":

- **More LogEntry variants.** Only `PaperResolved` ships.
  Telemetry, BrokerSnapshot, Diagnostic land when consumer
  proofs surface them.
- **Telemetry rate-gate emit callbacks.** The archive's
  `make_rate_gate(Duration)`-style coalescing is out of scope.
- **Explicit BEGIN/COMMIT around batch foldl.** v1 ships
  auto-commit per dispatch; future perf arc adds transaction
  wrapping once measurement shows commit overhead matters.
- **Read-side query APIs.** Still out of scope per arc 027.
  Use the `sqlite3` CLI.
- **WAL mode pragma.** Default rollback journal is fine for
  single-writer workloads.
- **Multi-database support per service.** One service, one
  path. Spawn two services if you need two paths.
- **Schema migrations.** Defer until needed.
- **Result-typed write errors.** Future arc when a caller
  surfaces graceful failure handling.
- **Generic `RunDb::execute(sql, params)` with heterogeneous
  Vec<Param>.** Future arc when per-variant shim method count
  makes codegen tedious (probably ≥10 variants).

---

## The thread

- **2026-04-25** — DESIGN.md + BACKLOG.md drafted by the
  proofs lane after the proof-003 hack attempt.
- **2026-04-25** (this session) — slice 1 (shim refactor +
  proof 002 migration) → slice 2 (LogEntry + service + smoke
  tests) → slice 3 (this INSCRIPTION + proof 003 unblock).
- Lab side next: proofs lane writes proof 003's pair file at
  `wat-tests-integ/proof/003-thinker-significance/` against
  `:lab::rundb::Service` + `:lab::log::LogEntry::PaperResolved`.

PERSEVERARE.
