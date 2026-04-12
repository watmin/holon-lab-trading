# wat-vm Backlog

The enterprise is a virtual machine. This backlog tracks the
refactor from braided binary to services + programs.

## Phase 1: Services directory

- [ ] `src/services/mod.rs` — module declarations
- [ ] `src/services/cache.rs` — the encoder cache service. Extract from binary. Trait for the interface. One implementation (LRU + pipe protocol). EncoderHandle lives here.
- [ ] `src/services/database.rs` — the log/ledger service. Extract from binary. Trait for the interface. One implementation (SQLite + batch commits). LogHandle lives here.
- [ ] `src/services/console.rs` — stdout/stderr service. N input pairs. IO loop. One of these. Internally synchronous.

## Phase 2: Programs directory

- [ ] `src/programs/mod.rs` — module declarations
- [ ] `src/programs/market_observer.rs` — the observer program. Receives candle + window. Returns (raw, anomaly, ast, prediction, edge). Uses cache service handle.
- [ ] `src/programs/exit_observer.rs` — the exit program. Receives candle + market outputs. Returns (raw, anomaly, ast, distances). Uses cache service handle.
- [ ] `src/programs/broker.rs` — the broker program. Receives opinions + self + derived. Returns (thought_ast, gate_open). Pure arithmetic. No cache needed.

## Phase 3: VM wiring

- [ ] `src/vm/mod.rs` — the virtual machine. Creates services. Creates programs. Wires pipes. The circuit.
- [ ] `src/vm/circuit.rs` — the wiring specification. Which program gets which service handles. The permissions.
- [ ] The binary (`src/bin/enterprise.rs`) becomes thin — create VM, feed candles, collect results.

## Phase 4: Pending fixes (do alongside or after)

- [ ] Remove direction flip on runners — the flip should affect NEW papers, not kill OLD runners
- [ ] Exit observers on proper threads with full pipe protocol (partially done — scoped threads, not persistent threads)
- [ ] Market observer learn signals should also be net-weight (same principle as exit — fees are reality)
- [ ] Vocab audit (Proposal 032) — RSI encoding, dead atoms, redundancies. Deferred until services are clean.
- [ ] Reflexive noise subspace — holon-rs has it, trading lab hasn't adopted it yet

## The target

The binary shrinks from ~1400 lines to ~200 lines:
1. Parse args
2. Create VM (services + programs + circuit)
3. Feed the candle stream
4. Collect results
5. Print summary

The programs are pure. The services are reusable. The circuit
is the permissions. The compiler enforces the wiring. You can't
fall off the clock.

## Key principles

- A program that doesn't have a pipe to a service CANNOT access
  that service. The absence of a wire IS the permission denial.
- Services own their state. Programs own their logic. The VM
  owns the wiring.
- Values up. Programs return data. Services handle effects.
- The ThoughtAST is the transparent form. The Vector is the
  opaque form. Encoding is deferred to the consumer who needs
  algebra.
- The fold IS the VM's heartbeat. `f(state, candle) → state`.
  Each program is a fold. The VM composes the folds.
