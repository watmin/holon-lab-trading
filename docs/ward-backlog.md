# Ward Backlog — Post-055 Cleanup

Five wards cast on 2026-04-15 after stripping the old paper system.
Each finding must be agreed on before implementation. One at a time.

## DONE

### 1. ~~Grace direction logic always true~~ ✓
**Reap, Sever, Gaze, Forge** — four wards converged.
**Fix:** Market observer teaches itself from phase labeler. Broken
direction_correct logic removed. Market learn pipe stripped entirely.
Broker no longer teaches market observer. Commit `9b1ed7a`, `2c14b0f`.

### 2. ~~paper_id lies for real positions~~ ✓
**Gaze, Forge**
**Fix:** `paper_id` → `position_id` on TreasuryVerdict and
TreasuryResponse. The field name says what it carries. Commit `59beb7d`.

### 3. ~~papers_failed incremented for real position Violence~~ ✓
**Gaze, Forge**
**Fix:** ProposerRecord split into paper stats and real stats.
paper_submitted/survived/failed/grace_residue for proof of thoughts.
real_submitted/survived/failed/grace_residue/violence_loss for proof
of execution. Gate reads paper stats only. Commit `2ab5640`.

### 4. ~~Real position Violence returns amount, not market value~~ ✓
**Forge**
**Fix:** check_deadlines takes current_price. Real positions reclaim at
market value minus exit fee. Conservation violation fixed. real_violence_loss
tracks actual loss. Commit `dc11506`.

### 5. ~~Braided resolution logic in retain()~~ ✓
**Sever**
**Fix:** Two duplicate arms collapsed into one path. Match extracts
outcome, one propagate call, one position learn send. Unparseable
weight expression killed — weight = 1.0. Commit `2bb2006`, `411b6c9`.

### 6. ~~Three unused broker params~~ ✓
**Reap, Forge**
**Fix:** `_trade_tx` removed (wrong direction — broker owns gate 4).
`cache` and `vm` activated (broker encodes anxiety atoms).
Broker stripped: PropagationFacts, scalar accumulators, dollar P&L,
distances, swap_fee — all dead. propagate() → record_outcome().
Position observer → pure encoder (Vec<ThoughtAST> on chain).
428 lines removed. Commit `e3cd96f`, `6964c5a`.

## Open
`broker_program.rs:47-49` — `_trade_tx`, `_cache`, `_vm`. Wired at
construction, never used. Each consumes a resource from its pool.

## Medium — single ward

### 7. Dead struct: ExitProposal
**Reap**
`treasury.rs:101-104` — defined, exported, never imported or used.

### 8. Dead field: total_violence_loss
**Reap**
`treasury.rs:80` — on ProposerRecord. Never written in production.
Only set in test literals. The field was added for expectancy but
never wired.

### 9. Dead field: resolution_count
**Reap**
`broker.rs:65` — written, never read. Dead accumulation.

### 10. Dead method: get_real_position
**Reap**
`treasury.rs:273-275` — defined, never called.

### 11. Dead methods: submit_real, submit_exit
**Reap**
`treasury_program.rs:107-143` — defined on TreasuryHandle, never
called. The corresponding request variants and response handling
in handle_request are also dead.

### 12. Dead cascade computation
**Reap**
`broker_program.rs:81` — `let _distances = broker.cascade_distances(...)`.
Computed every candle, result discarded.

### 13. Dead atr on TreasuryEvent::Tick
**Reap**
`treasury_program.rs:25, wat-vm.rs:774` — atr computed and sent
every tick, never read by the treasury program.

### 14. ~~Hardcoded asset pair~~ ✓
**Sever**
**Fix:** Asset fields (`source_asset`, `target_asset`) added to enriched
Candle, passed through from Ohlcv via IndicatorBank. Broker reads
from `chain.candle` instead of hardcoded strings. The pair flows
on the data, not the construction.

### 15. reference = 10_000.0 duplicated
**Forge**
`broker.rs:186` and `treasury.rs:149`. Two places own the same
truth. If one changes, the other breaks silently.

### 16. client_id / slot_idx / owner identity seam
**Forge**
Three names for what should be one type. No newtype enforcement.
If client_id != slot_idx, accounting diverges silently.

### 17. weight semantic overload in propagate()
**Forge**
`broker.rs` — weight means excursion for Grace, stop_distance for
Violence. Same f64 parameter, different meanings. Caller must know.

### 18. Stale "paper" comments in broker.rs
**Gaze**
Lines 66-68, 200 — comments say "per Grace paper", "half-life ~50
papers". The broker no longer owns papers.

### 19. Placeholder weight without WHY
**Gaze**
`broker_program.rs:100` — `let weight = 0.01; // stop distance
placeholder`. No explanation of what replaces it or when.

### 20. Tick price/atr unused
**Reap, Forge**
`treasury_program.rs` — Tick carries price and atr but the program
only reads candle. Dead data on the event.

## Clean

### Cleave — CLEAN
No shared mutation. No deadlock. No interleaving hazard. The
treasury mailbox boundary is a clean split. One benign observation:
tick/request ordering is non-deterministic (off-by-one candle,
0.2% on 500-candle deadlines).
