# Ward: Reap — Proposal 056

Scanned 9 files modified during Proposal 056 implementation.

## Findings

### 1. DEAD STRUCT — `ObsLearn` (market_observer_program.rs:39)

```rust
pub struct ObsLearn {
    pub thought: Vector,
    pub direction: Direction,
    pub weight: f64,
}
```

Defined, exported, never imported anywhere. Zero references outside its
definition. Was the learn-signal struct from the old broker-propagation
model. Market observers now self-grade from phase labels. The struct
survived the rewrite. Dead.

### 2. DEAD FIELD — `active_direction` (broker.rs:26)

```rust
pub active_direction: Option<Direction>,
```

Written once per candle in broker_program.rs:134 (`broker.active_direction = Some(direction)`).
Never read. No branch, no log, no telemetry, no downstream consumer reads it.
Write-only field. Dead.

### 3. DEAD FUNCTIONS — `market_idx()` and `regime_idx()` (broker.rs:66-73)

```rust
pub fn market_idx(&self) -> usize { self.slot_idx / self.regime_count }
pub fn regime_idx(&self) -> usize { self.slot_idx % self.regime_count }
```

Called only from tests (broker.rs:124-125). No production call site. The
`regime_count` field exists only to support these two methods.

If removed, `regime_count` field is also dead (only used in these methods
and the constructor assertion).

### 4. DEAD FUNCTION — `gate_open()` (broker.rs:77)

```rust
pub fn gate_open(&self) -> bool {
    let cold_start = self.grace_count < 50 || self.violence_count < 50;
    cold_start || self.expected_value > 0.5
}
```

Called only from tests. No production call site. The broker program uses
`wants_exit` from the gate reckoner's prediction, not `gate_open()`. The
function is a vestige of the pre-reckoner gating model.

### 5. DEAD RE-EXPORT — `compute_trade_atoms`, `select_trade_atoms` (regime_observer_program.rs:33)

```rust
pub use crate::vocab::exit::trade_atoms::{compute_trade_atoms, select_trade_atoms};
```

Re-exported for "backward compatibility" (per the comment). No file imports
these through the regime_observer_program path. The underlying functions
in `vocab/exit/trade_atoms.rs` may or may not have direct callers — but
this re-export is dead regardless.

### 6. DEAD PARAMETERS — `_cache`, `_vm`, `_scalar`, `_noise_floor` (regime_observer_program.rs:40-47)

```rust
pub fn regime_observer_program(
    slots: Vec<RegimeSlot>,
    _cache: CacheHandle<ThoughtAST, Vector>,
    _vm: VectorManager,
    _scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    regime_obs: RegimeObserver,
    _noise_floor: f64,
    regime_idx: usize,
) -> RegimeObserver {
```

Four parameters prefixed with `_` — never used inside the function body.
The regime observer builds rhythm ASTs but delegates encoding to the broker.
These parameters are accepted, passed by the caller in wat-vm.rs, but do
nothing. The caller allocates cache and console handles for these — wasted
pool slots.

### 7. DEAD FUNCTIONS — `market_lens_facts()` and `regime_lens_facts()` (lens.rs:43, 172)

```rust
pub fn market_lens_facts(lens: &MarketLens, ...) -> Vec<ThoughtAST> { ... }
pub fn regime_lens_facts(lens: &RegimeLens, ...) -> Vec<ThoughtAST> { ... }
```

Called only from tests within lens.rs. No production call site. Proposal 056
replaced fact-based encoding with rhythm-based encoding (`market_rhythm_specs`
and `regime_rhythm_specs`). The fact functions and all their vocab imports
survive only because the tests exercise them.

The 11 vocab module imports at the top of lens.rs (lines 17-32) exist
solely for these dead functions.

## Runes acknowledged

- `rune:forge(dims)` at rhythm.rs:57, rhythm.rs:116 — budget computed
  from literal 10_000; needs dims parameter when available.
- `rune:temper(disabled)` at broker_program.rs:262, market_observer_program.rs:174,
  regime_observer_program.rs:94 — rhythm AST serialization disabled due to
  multi-MB EDN size.

## Clean files

- **rhythm.rs** — no dead code found. Clean.
- **phase.rs** (vocab/exit/phase.rs) — no dead code found. All three exports
  (`encode_phase_current_facts`, `phase_rhythm_thought`, `phase_scalar_facts`)
  are consumed in lens.rs and broker_program.rs.
- **regime_observer.rs** (domain) — minimal struct, no dead code. Clean.
- **wat-vm.rs** — no orphaned handles. All senders wired. All pools finished.
  Shutdown order correct (candle_txs dropped → market observers join → topic
  handles dropped → regime observers join → brokers join → treasury tick sender
  dropped → treasury joins → cache driver joins → db driver joins → console
  joins). No deadlock risk.
