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

## Build order — leaves to root

Build the services. Prove each independently. Then migrate.

1. **Queue** — the ONLY atom. One in, one out. A single queue
   instance is a contention-free pipe. One writer, one reader.
   Test: messages flow, backpressure, shutdown.
2. **Topic** — COMPOSED of queues. One input queue, N output queues.
   Its own thread. Reads from one queue, writes to N queues.
   Test: all consumers receive.
3. **Mailbox** — COMPOSED of queues. N input queues, one output.
   Its own thread. Selects across N queue receivers, forwards to
   one queue. The kernel creates N queues. Programs pop senders.
   The mailbox holds the receivers. Test: messages merge.
4. **Cache** — a driver. Its own thread. The kernel creates queues
   for it. Programs get queue senders. The driver holds receivers.
   Test: hit/miss/eviction.
5. **Database** — a driver. Its own thread. The kernel creates N
   queues (one per writer). The driver holds a mailbox of those
   queue receivers. Test: batch commits.
6. **Console** — a driver. Its own thread. Same mailbox pattern.
   Test: output ordering.
7. **Migrate** — replace raw channels in binary with service instances. One at a time.

## The drivers (services)

Each driver is a free entity. Named. Independent IO loop.
Concurrent with other drivers. Sequential internally.

- [x] `src/services/mod.rs` — DONE
- [x] `src/services/queue.rs` — DONE. THE atom. One producer, one
      consumer. Bounded or unbounded. Contention-free. 4 tests pass.
- [x] `src/services/topic.rs` — DONE. Fan-out. One input, N output.
      Own thread. 3 tests pass.
- [x] `src/services/mailbox.rs` — DONE. Fan-in. N independent queues
      composed. Each producer gets its own sender (contention-free).
      Fan-in thread selects across N receivers. 4 tests pass.
- [ ] `src/services/cache.rs` — generic key-value with eviction.
      Named instances. `cache("encoder")` holds ThoughtAST → Vector.
      One implementation. N instances. Each its own loop.
- [ ] `src/services/database.rs` — write + flush interface.
      Named instances with specific schemas.
      `database("ledger")` knows broker_snapshots, paper_details.
      Each its own loop with batch commits.
- [ ] `src/services/console.rs` — N input pairs (stdout, stderr).
      One instance. IO loop. Internally synchronous.

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

## Shutdown cascade

Drop IS disconnect. The absence IS the signal. No shutdown
message. No flag. No special form.

1. SIGTERM → kernel drops the candle source
2. Topic drains, exits, drops output queues
3. Observers see Disconnected, drain, return, drop their senders
4. Main thread sees Disconnected, stops feeding grid, drops broker senders
5. Brokers drain, return, drop their senders
6. Mailbox receivers see Disconnected, drain remaining writes
7. Database driver flushes, commits, closes
8. Done.

The cascade is: recv returns Disconnected → drain → function
returns → handles go out of scope → Drop runs → downstream
sees Disconnected. Rust enforces this — Drop runs when the
value leaves scope. The select loop exits when ALL inputs
disconnect.

The wat form for shutdown: stop recursing. The function returns.
The locals drop. No new form needed.

```scheme
(define (observer-loop input output)
  (let ((candle (recv input)))
    (when candle
      (send output (observe candle))
      (observer-loop input output))))
;; recv returns nothing → when skips → function returns
;; output leaves scope → Drop → downstream sees nothing
```

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
