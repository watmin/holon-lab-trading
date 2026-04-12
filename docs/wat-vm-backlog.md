# wat-vm Backlog

The enterprise IS a virtual machine. This backlog tracks the
refactor from braided binary to kernel + drivers + programs.

The code already IS the VM. The refactor is RECOGNIZING it —
separating what's already there into clean directories.

## The model

The wat-vm is the kernel. Handles are file descriptors.
Services are core primitives. Programs are everything else.

- **Kernel** (the binary) — provisions handles, wires the
  circuit, manages lifecycle. Thin. ~200 lines target.
- **Core** (`src/services/`) — the three messaging primitives.
  Queue, topic, mailbox. Zero application knowledge. Zero
  domain knowledge. Pure infrastructure.
- **Stdlib** (`src/programs/stdlib/`) — generic reusable programs
  composed from core. Cache, database, console. Any wat-vm
  application would want these. Domain-independent.
- **App** (`src/programs/app/`) — domain-specific programs.
  Observer, broker, exit observer. This enterprise. This domain.
  Pop their handles at construction. Pure logic.
- **Handles** — file descriptors. Opaque references to resources
  the kernel manages. The handle IS the permission. If you don't
  have one, you can't reach the service.

## The insight

The database is a mailbox consumer. The console is a mailbox
consumer. They are PROGRAMS that use the mailbox SERVICE, not
services themselves. The cache uses queues + mailbox — it's a
program that composes from core primitives.

The test: could a DDoS lab use it? Cache — yes. Database — yes.
Console — yes. Observer — no, that's trading. Domain dependency
draws the line between stdlib and app.

Three services compose into everything:
- Queue:   1:1. The atom.
- Topic:   1:N. Composed of queues.
- Mailbox: N:1. Composed of queues.
- Cache:   a PROGRAM. Uses queues + mailbox. Owns an LRU.
- Database: a PROGRAM. Uses a mailbox. Owns a connection.
- Console: a PROGRAM. Uses a mailbox. Owns stdout.

## Build order — leaves to root

Build core. Prove each independently. Then stdlib. Then app.

### Core (src/services/) — DONE

1. **Queue** — the ONLY atom. One in, one out. A single queue
   instance is a contention-free pipe. One writer, one reader.
   Test: messages flow, backpressure, shutdown. **DONE. 4 tests.**
2. **Topic** — COMPOSED of queues. One input queue, N output queues.
   Its own thread. Reads from one queue, writes to N queues.
   Test: all consumers receive. **DONE. 3 tests.**
3. **Mailbox** — COMPOSED of queues. N input queues, one output.
   Its own thread. Selects across N queue receivers, forwards to
   one queue. The kernel creates N queues. Programs pop senders.
   The mailbox holds the receivers. Test: messages merge.
   **DONE. 4 tests.**

### Stdlib (src/programs/stdlib/)

4. **Cache** — a program. Uses queues (per-client get
   request/response pairs) + mailbox (shared set). Owns an LRU.
   Its own thread. The kernel creates handles. Programs pop them.
   Test: hit/miss/eviction/shutdown. **BUILT in src/services/cache.rs.
   Needs move to src/programs/stdlib/. 5 tests.**
5. **Database** — a program. Uses a mailbox. Owns a SQLite
   connection. Batch commits. Named instances.
   `database("ledger")` knows broker_snapshots, paper_details.
   Test: batch commits, shutdown flush.
6. **Console** — a program. Uses a mailbox. Owns stdout.
   N producers. Internally synchronous.
   Test: output ordering.

### App (src/programs/app/)

7. **Market observer** — receive candle → encode (via cache handle)
   → strip noise → predict → return (raw, anomaly, ast, prediction, edge)
8. **Exit observer** — receive candle + market outputs → encode
   (via cache handle) → extract → strip noise → return
   (raw, anomaly, ast, distances)
9. **Broker** — receive opinions + self → build AST (no encoding,
   no cache) → check gate → return (thought_ast, gate_open)

### Migration

10. **Migrate** — replace raw channels in binary with core + stdlib
    + app programs. One at a time.

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
