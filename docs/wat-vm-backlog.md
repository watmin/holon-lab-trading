# wat-vm Backlog

The enterprise IS a virtual machine. This backlog tracks the
refactor from braided binary to kernel + drivers + programs.

The code already IS the VM. The refactor is RECOGNIZING it —
separating what's already there into clean directories.

## The model

The wat-vm is the kernel. Handles are file descriptors.
Services are drivers. Thread bodies are programs.

- **Kernel** (the binary) — provisions handles, wires the
  circuit, manages lifecycle. Thin. ~200 lines target.
- **Drivers** (`src/services/`) — the service loops. Each one
  owns its state. Each one is its own concurrent IO loop.
  Internally sequential. The driver does the actual work.
- **Programs** (`src/programs/`) — the thread bodies. Pop their
  handles at construction. Read and write to handles. Pure logic.
  Don't know what's on the other end.
- **Handles** — file descriptors. Opaque references to resources
  the kernel manages. The handle IS the permission. If you don't
  have one, you can't reach the service.

## The drivers (services)

Each driver is a free entity. Named. Independent IO loop.
Concurrent with other drivers. Sequential internally.

- [ ] `src/services/mod.rs`
- [ ] `src/services/cache.rs` — generic key-value with eviction.
      Named instances. `cache("encoder")` holds ThoughtAST → Vector.
      Could have `cache("engram")`, `cache("scales")` etc.
      One implementation. N instances. Each its own loop.
- [ ] `src/services/database.rs` — write + flush interface.
      Named instances with specific schemas.
      `database("ledger")` knows broker_snapshots, paper_details.
      Each its own loop with batch commits.
- [ ] `src/services/console.rs` — N input pairs (stdout, stderr).
      One instance. IO loop. Internally synchronous.
- [ ] `src/services/queue.rs` — point-to-point. One producer,
      one consumer. Bounded or unbounded. Its own thread, own
      IO loop. Generic over message type.
- [ ] `src/services/topic.rs` — fan-out. One producer, N consumers.
      Its own thread. Receives one message, copies to all outputs.
      The candle broadcast IS a topic.
- [ ] `src/services/mailbox.rs` — fan-in. N producers, one consumer.
      Its own thread. Selects across all inputs, forwards to one
      output. The learn channels ARE mailboxes — settlements,
      market signals, and runner resolutions all write to the same
      broker. Multiple writers, one reader.

## The programs

Each program pops its handles at construction. Returns values.

- [ ] `src/programs/mod.rs`
- [ ] `src/programs/market_observer.rs` — receive candle →
      encode (via cache handle) → strip noise → predict →
      return (raw, anomaly, ast, prediction, edge)
- [ ] `src/programs/exit_observer.rs` — receive candle +
      market outputs → encode (via cache handle) → extract →
      strip noise → return (raw, anomaly, ast, distances)
- [ ] `src/programs/broker.rs` — receive opinions + self →
      build AST (no encoding, no cache) → check gate →
      return (thought_ast, gate_open)

## The kernel

- [ ] Circuit specification — which programs, which drivers,
      which handles connect where. The fd table.
- [ ] Handle provisioning — create handles, fill pools,
      programs pop from pools.
- [ ] Lifecycle — spawn threads, feed candles, collect results,
      shutdown cascade (drop sends → threads exit → join).

## Pending fixes (do alongside)

- [ ] Remove direction flip on runners — flip affects NEW papers
      only, not running trades. Runners have their own trail/stop.
- [ ] Exit observers on proper persistent threads (currently
      scoped threads per candle)
- [ ] Market observer weights should be net (fees are reality)
- [ ] Vocab audit (Proposal 032) — RSI encoding, dead atoms
- [ ] Adopt reflexive noise subspace from holon-rs

## Key insight

The `pop()` pattern already exists:
```rust
let brk_enc = broker_encoder_handles.pop().unwrap();
let brk_log = log_handles.pop().unwrap();
```

That's `open()`. The pool was filled by the kernel. The program
takes what was provisioned. The circuit determined what was
provisioned. The compiler checks the types. The absence of a
handle IS the permission denial.
