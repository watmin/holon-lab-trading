# Ward Backlog — Post-055 Cleanup

Five wards cast on 2026-04-15 after stripping the old paper system.
Each finding must be agreed on before implementation. One at a time.

## Critical — four wards converged

### 1. Grace direction logic always true
**Reap, Sever, Gaze, Forge**
`broker_program.rs:175-186`
Both match arms check `price > 0.0` — always true for BTC.
`direction_correct` is always true. The else branch is dead.
Grace always teaches the predicted direction unchanged.
**Risk:** the market observer's Grace learning signal may be wrong.

## High — multiple wards

### 2. paper_id lies for real positions
**Gaze, Forge**
`treasury.rs:369` — `TreasuryVerdict::Violence { paper_id: id }` where
`id` is a real position ID. The enum has no way to distinguish paper
from real verdicts. The field name promises paper, delivers real.

### 3. papers_failed incremented for real position Violence
**Gaze, Forge**
`treasury.rs:367` — `record.papers_failed += 1` for a real position.
The ProposerRecord conflates paper and real outcomes. Pollutes the
gate predicate's survival rate.

### 4. Real position Violence returns amount, not market value
**Forge**
`treasury.rs:364` — `+= amount` (original borrowed). But the position
may have lost value. The function doesn't receive current_price.
Conservation violation — returns capital that may not exist.

### 5. Braided resolution logic in retain()
**Sever**
`broker_program.rs:95-205` — Violence and Grace arms are structural
copies. Five concerns interleaved: discovery, phase weight, propagate,
learn direction, dispatch. Extract a `resolve_outcome()` helper.

### 6. Three unused broker params
**Reap, Forge**
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

### 14. Hardcoded asset pair
**Sever**
`broker_program.rs:84-85` — `"USDC"` / `"WBTC"` hardcoded. Should
come from the chain or post configuration.

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
