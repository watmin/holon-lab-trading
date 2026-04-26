# Experiment 008 — Treasury Program

**Date:** opened 2026-04-26.
**Status:** types file shipping now; service program + driver test BLOCKED on wat-rs arc 058 (HashMap completion — `dissoc` / `keys` / `values` / `empty?` extension).
**Cross-refs:**
- Proposal 055 (Treasury-Driven Resolution) — `docs/proposals/2026/04/055-treasury-driven-resolution/`
- Archive predecessor — `archived/pre-wat-native/src/domain/treasury.rs` (433 LOC) + `archived/pre-wat-native/src/programs/app/treasury_program.rs` (431 LOC)
- Arc 029 (RunDb service) — `docs/arc/2026/04/029-rundb-service/` (telemetry hand-off via `:trading::rundb::Service`)
- Arc 030 slice 1 (LogEntry::Telemetry) — `docs/arc/2026/04/030-encoding-cache/` (`emit-metric` constructor; per-Tick batched flush)
- wat-rs arc 058 (HashMap completion) — `wat-rs/docs/arc/2026/04/058-hashmap-completion/` (the substrate work this experiment depends on)

---

## What we're building

A Treasury program in wat — the bank from proposal 055. Headless; blind to strategy. Holds papers per broker, enforces deadlines, validates exit math. The first piece of the architecture rebuild.

**Behaviorally:**
- Receives `Tick { candle, price }` events from the (synthetic, in this experiment) main loop. Per Tick: scans active papers; any past `deadline_candle` resolves to Violence.
- Receives `SubmitPaper { from-asset, to-asset, price }` requests from brokers. Always succeeds. Issues a paper with deadline = `entry_candle + 288` (fixed for now; ATR-adjusted later). Returns a `PositionReceipt`.
- Receives `SubmitExit { paper-id, current-price }` requests from brokers. Validates: paper exists, is Active, residue > 0 after fees. If yes: marks Grace, returns `Verdict::Grace { residue }`. If no: returns `Verdict::ExitDenied`.
- Receives `BatchGetPaperStates { paper-ids }` requests. Returns `Vec<(i64, Option<PositionState>)>` for broker resolution.
- Per-Tick: emits a `LogEntry::Telemetry` batch with active-paper count, ns-per-tick, ns-per-request, etc. Flushes via `:trading::rundb::Service/batch-log` (one batch per Tick — natural rhythm IS the rate gate per arc 030 slice 1).

**Architecturally** (per proposal 055 + the kill-the-mailbox direction):
- Single-thread driver. The Treasury value lives on the driver thread; updates are values-up (each event handler returns a new Treasury).
- The driver owns `Vec<Receiver<Request>>` of size N+1 (N broker request channels + 1 tick channel) and runs `:wat::kernel::select` over them inline. No Mailbox proxy.
- Per-broker response queues — Treasury holds `Vec<Sender<Response>>` indexed by `client_id`.
- HandlePool distributes the N broker-side ReqTx handles + the 1 tick-side handle.

## What's in scope (for this experiment)

- The Treasury TYPES (`wat/treasury/types.wat`) — `PaperPosition`, `RealPosition`, `ProposerRecord`, `PositionState`, `PositionReceipt`, `Verdict`, `Treasury` struct. **Both Paper AND Real positions defined** even though only Paper gets exercised in 008's test driver — RealPosition is here so 009+ doesn't need a schema migration.
- The Treasury LIB (`wat/treasury/treasury.wat`) — pure helpers on `Treasury`: `issue-paper`, `issue-real`, `validate-exit`, `resolve-grace`, `check-deadlines`, `gate-predicate`. (Blocked on arc 058 — bodies need HashMap iteration + remove.)
- The Treasury SERVICE (`wat/services/treasury.wat`) — recv-loop driver, request/response types, dispatch, telemetry. (Blocked on arc 058.)
- The driver test (`wat-tests-integ/experiment/008-treasury-program/explore-treasury.wat`) — synthetic broker fires a few SubmitPaper + Tick + SubmitExit events; verifies behavior; emits telemetry to `runs/exp-008-<epoch>.db` for SQL inspection.

## What's NOT in scope

- **Brokers, observers, regime middleware.** Treasury runs ALONE in 008. The synthetic test driver replaces the broker for now.
- **Real positions in the test path.** `RealPosition` is defined; `issue-real` will be implemented; but the test exercises only papers. (009+ adds the broker that earns real positions through proven record.)
- **Candle stream feeding.** Synthetic Tick events from inside the deftest, not real BTC candles.
- **ATR-adjusted deadline.** Fixed `288` candles per paper. Dynamic-with-trust comes when we wire candles in.
- **The full conservation invariant ward.** Skeletal `balances: HashMap<String, f64>` is in the Treasury struct (initialized USDC=100_000 etc.) but the per-tick assertion that "balances unchanged after every paper op" lands in 009 when real positions enter. Papers don't move balances per 055.
- **Rate gate for telemetry emission.** Treasury batches per Tick; per-Tick frequency IS the rate (per arc 030 slice 1 design Q7). No `make-rate-gate` needed.

## How to run (when unblocked)

```bash
cd /home/watmin/work/holon/holon-lab-trading
cargo test --release --features experiment-008 --test experiment_008 -- --nocapture
```

Output: `runs/exp-008-<epoch>.db`. Inspect via:

```bash
sqlite3 $(ls -t runs/exp-008-*.db | head -1) <<'EOF'
-- Paper resolutions
SELECT thinker, state, COUNT(*), ROUND(SUM(residue), 4), ROUND(SUM(loss), 4)
FROM paper_resolutions GROUP BY thinker, state;

-- Treasury per-tick telemetry
SELECT id, metric_name, ROUND(metric_value, 6), metric_unit
FROM telemetry
WHERE namespace='treasury'
ORDER BY timestamp_ns;

-- Active paper count over time
SELECT id, metric_value
FROM telemetry
WHERE namespace='treasury' AND metric_name='active_papers'
ORDER BY timestamp_ns;
EOF
```

## What we hope to learn

This experiment is the first piece of the rebuild. Specific things we want the DB to tell us:

1. **The lifecycle works.** Papers open, age, resolve at deadline (Violence) or via SubmitExit (Grace). The ProposerRecord counters increment correctly. Conservation skeleton (balances unchanged) holds.
2. **The select-loop driver is correct.** Treasury serializes Tick events with broker requests in arrival order; no event lost; clean shutdown when all senders drop.
3. **Throughput floor.** ns_tick + ns_request per event tells us where Treasury sits on the cost curve. Comparison point: arc 029's RunDb service ships ~340 batched inserts per proof in microseconds. Treasury per-event work is similar order of magnitude (no encoding, just HashMap ops + telemetry build). Rough expectation: hundreds of microseconds per Tick.
4. **The batch-per-Tick telemetry rhythm works in practice.** Confirm: telemetry rows per Tick land cleanly in the DB; no flooding (the natural rhythm IS the rate gate); per-Tick metrics are queryable.
5. **What the DB queries actually feel like as a debug interface.** "The DB is our gdb." Does the per-row telemetry shape make it pleasant to ask "what was the active-paper count at candle N?" / "where did the 95th-percentile-slow ticks happen?" If queries feel awkward, we learn what to add to the schema in the next experiment.

## What this unblocks

- **Experiment 009** — first broker. Treasury already exists; broker is added that opens a paper EVERY tick (multi-paper accumulation per proposal 055) and proposes exits on signal. Treasury's per-broker handle distribution lights up. ProposerRecord starts accumulating real numbers.
- **Experiment 010** — multiple brokers, single asset. The N×M shape from CLAUDE.md begins. HandlePool sees real exercise.
- **Experiment 011 onward** — observers (market, regime), the chain types from `archived/.../programs/chain.rs`, the candle stream wired in.

The Treasury IS the foundation everything else hangs off of. Get it right here; everything later inherits the contract.

PERSEVERARE.
