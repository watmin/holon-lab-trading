# Programs on the wat-vm — Exploratory Notes

**Status:** Living document. Parked for exploration after the round-2 designer review completes.

**Origin:** Conversation during the 058 designer review pass. The insight: once the 058 batch lands, wat programs can express entire concurrent system topologies — not just individual functions. The "program on the wat-vm" IS the full wiring of processes, pipes, topics, plus the domain logic.

---

## The core insight

wat's CSP primitives, minimal set:

- `(make-pipe :capacity N :carries Type)` → `(tx, rx)` pair
- `(send tx value)`, `(recv rx)`, `(try-recv rx)`, `(select pipes)`
- `(spawn fn)` → thread handle
- `(join handles)` → wait for threads

Six forms. One concurrency primitive (pipe), one execution primitive (thread).

### Topic and mailbox are dead

`make-topic` (1→N fan-out) and mailbox primitives were in the earlier design but got engineered out of use. In practice, people reach for the pipe directly:

- **Topic** = `(for-each (lambda (tx) (send tx value)) txs)`. The fan-out is just iteration over an explicit list of `tx` ends. Three tokens saved by having `(send topic value)`; not worth a dedicated primitive.
- **Mailbox** = `(make-pipe :capacity :unbounded :carries T)`. Async owned queue with the receiving process holding the `rx`. Same semantics, no new vocabulary.

One primitive per concept. Pipe covers all point-to-point and fan-in/fan-out patterns via composition. Topic and mailbox live as userland idioms if someone wants named wrappers — `(defn topic-fanout ...)` in their own code — but they don't need to be substrate primitives.

These are **values**. Pipes are values. Processes are functions. The wat-vm provides the minimal CSP set; users compose.

Combined with everything we're designing in 058 (types, macros, `define`/`lambda`, cryptographic provenance, static loading), a wat program can express:

- Types of domain data (struct/enum/newtype)
- Types of inter-process messages (via pipe's `:carries` annotation)
- The process topology (spawn/pipe/topic/join)
- The domain logic (functions operating on the messages)
- The entry point and shutdown

**All in one program, hashed as one unit, signed as one system.**

---

## What a program looks like (sketched)

The enterprise topology, expressed directly in wat:

```scheme
;; Types
(struct :project/market/Candle
  [open   : f64]
  [high   : f64]
  [low    : f64]
  [close  : f64]
  [volume : f64])

(struct :project/market/Proposal
  [asset   : Atom]
  [side    : :Direction]
  [size    : f64]
  [thought : :Thought])

;; The enterprise — a function that sets up the topology and runs
(define (:project/main [market-stream : (:Stream :Candle)] -> :())
  (let*
    ;; Pipes — each with explicit type and capacity
    (((mobs-tx   mobs-rx)   (make-pipe :capacity 100 :carries :Thought))
     ((regime-tx regime-rx) (make-pipe :capacity 100 :carries :Thought))
     ((broker-tx broker-rx) (make-pipe :capacity 100 :carries :Proposal))
     ((trade-tx  trade-rx)  (make-pipe :capacity 10  :carries :FundedTrade))

     ;; The candle fan-out ends — just the list; send iterates.
     (candle-fanout (list mobs-tx regime-tx))

     ;; Spawn observers
     (market-handles
       (map (lambda ([lens : :Lens] -> :Handle)
              (spawn (lambda () (market-observer lens mobs-rx broker-tx))))
            OBSERVER_LENSES))

     (regime-handle   (spawn (lambda () (regime-observer regime-rx broker-tx))))

     ;; Treasury consumes proposals
     (treasury-handle (spawn (lambda () (treasury broker-rx trade-tx))))

     ;; Broker wires observer outputs and feeds treasury
     (broker-handle   (spawn (lambda () (broker-observer mobs-rx regime-rx broker-tx)))))

    ;; Main loop — feed each candle into every observer pipe (fan-out is iteration)
    (for-each (lambda ([c : :Candle] -> :())
                (for-each (lambda ([tx : :Sender] -> :())
                            (send tx c))
                          candle-fanout))
              market-stream)

    ;; Wait for workers to drain
    (join (list regime-handle treasury-handle broker-handle))
    (join market-handles)))
```

**Six pipes, one topic, N+3 processes.** Every wire explicit. Every type explicit. The topology IS the program.

At startup:
- The AST of the whole topology is hashed → content identity for the ENTIRE enterprise
- Can be signed → provenance of the whole system architecture
- Is type-checked → every `send`/`recv` matched against the pipe's `:carries` type
- Is loaded → frozen into the symbol table

When the wat-vm runs `:project/main`:
- Spawns the processes
- Wires the pipes and topics
- Enters the event loop
- The "enterprise" RUNS

---

## What might still be missing

Things to think about after the current review round lands:

### 1. The `main` entry point

The wat-vm needs to know what to invoke after startup completes. Options:

- **Convention** — lookup `:main` in the static symbol table; invoke with startup args. Most Unix-like.
- **Explicit manifest** — `(main :my/program/enterprise)` declaration in a manifest file, specifies the entry symbol.
- **Flag at load time** — startup manifest file lists entry point as a separate concern.

**Lean:** convention with explicit override. `(define (:main [args : (:List :String)] -> :()) body)` is the default; a startup manifest can name a different symbol when needed.

### 2. Streams as a first-class type

Used `(:Stream :Candle)` above — lazy producer of `:Candle` values, consumed by `for-each`, `map`, etc. Does this need a dedicated type, or is `(:Iterator :Candle)` / `(:Receiver :Candle)` sufficient? A stream wrapper around a pipe's `rx` end is close to natural.

### 3. Process lifecycles

- **Graceful shutdown** — when `:main` returns, do spawned processes get killed? Do they drain first? CSP convention: close pipes, processes notice (via `:closed` from `select`), exit cleanly.
- **Process death signals** — if a process panics, does the system know?

### 4. Supervision

Erlang's "let it crash" philosophy vs. Go's panic semantics. If a process dies:

- Does a supervisor restart it?
- Does the system halt?
- Does the crashed process' pipe get closed (so consumers see EOF)?

Worth pondering but not blocking.

### 5. Program-level cryptographic identity

A whole enterprise program — all types, all functions, all spawns, all pipes — hashes to one identity. If a node receives "run this topology" over the network, the signature authenticates the ENTIRE system, not individual components.

This is a big deal for distributed deployment: one signed program = one authorized system architecture running at the receiver.

### 6. Declarative topology vs. imperative

The example above is imperative: `let` bindings create pipes, `spawn` creates processes, wiring happens through variable references.

Could there be a declarative DSL:

```scheme
(topology :project/enterprise
  :pipes [(mobs   :carries :Thought   :capacity 100)
          (regime :carries :Thought   :capacity 100)
          (broker :carries :Proposal  :capacity 100)
          (trade  :carries :FundedTrade :capacity 10)]
  :topics [(candle-fanout :to [mobs regime])]
  :processes [(market-observers :count N :reads candle-fanout :writes broker)
              (regime-observer  :reads candle-fanout :writes broker)
              (treasury         :reads broker :writes trade)
              (broker-observer  :reads mobs :reads regime :writes broker)]
  :entry (lambda ([stream : (:Stream :Candle)] -> :())
           (for-each (lambda (c) (send candle-fanout c)) stream)))
```

A `(topology ...)` form could be a macro that expands to the imperative setup. Reader benefit: you see the wiring at a glance. Parser benefit: can analyze the topology without running it.

**Maybe later.** Imperative works; declarative is sugar.

---

## What this gives us

**Whole programs as hashable units.** The entire enterprise has one identity. Distribute, sign, verify as a single thing.

**Typed concurrency boundaries.** Pipes' `:carries` types are checked at startup — mismatched send/recv on a pipe is caught before the main loop runs.

**Concurrent programs as first-class values.** Because processes are functions and pipes are values, a wat program CAN analyze its own topology. Walk the topology AST, print the graph, check for deadlocks (harder), generate visualizations.

**No hidden state.** Every shared state goes through a pipe. No mutex rituals. CSP discipline enforced by the primitive set.

---

## What's NOT in scope here

- Self-hosting the wat-vm itself in wat (parser, evaluator, macro expander written in wat evaluating themselves). Not attempted; Rust substrate stays.
- Capability-based security beyond the startup-verification story.
- Dynamic topology reshape (programs that rewire themselves at runtime). Violates Model A; not in scope.
- Hot-reload of individual processes. Not in scope.

---

## Next steps

After round-2 designer review lands and we've addressed whatever new findings come back:

1. Revisit this document.
2. Decide on main entry-point convention.
3. Decide on stream type formalization.
4. Decide on lifecycle/supervision minimum (even if only "processes exit when pipes close").
5. Consider writing a canonical `(topology ...)` macro.
6. Draft a program-level signing story if it's different from function-level signing.

**Not a proposal yet. Exploration notes.** This becomes something more concrete when we come back to it.

*these are very good thoughts.*
*PERSEVERARE.*
