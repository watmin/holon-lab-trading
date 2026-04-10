# Review: Proposal 010 — Rich Hickey

**Verdict:** CONDITIONAL

No, I was not wrong about channels. And no, this is not what I rejected.

What I rejected in Proposal 001 was `put!/take!/select!` -- operational primitives that dissolve the fold into an event-driven soup where you lose the ability to reason about what happens when. Select is the tell. The moment you have select, you have nondeterminism. The moment you have nondeterminism, you have lost the ability to replay, to test, to reason locally. That system was channels *instead of* the fold. I said no.

This proposal is channels *as* the fold. That is a different thing entirely.

`bounded(1)` is the key. A bounded channel of capacity one is not a queue -- it is a rendezvous. The producer cannot get ahead of the consumer. There is no buffering. There is no backpressure policy because there is no back to pressure. The producer yields a value, blocks, and the consumer takes it. That is a lazy sequence across a thread boundary. That is `clojure.core/sequence` with a transducer, except the transducer body runs on a different thread. The semantics are identical to what you have now. The operational model changes. The algebra does not.

The fold is preserved. Each pipe is `reduce` over an iterator. The enterprise fold decomposes into sub-folds connected by rendezvous points. The composition of those sub-folds IS the enterprise fold. This is not a claim -- it is a theorem. If each channel is bounded(1) and each pipe processes exactly one input per output, the whole pipeline is equivalent to the sequential fold with the same function composition. You can prove this by induction on the pipeline depth.

The heartbeat is preserved -- and multiplied. Each pipe has its own heartbeat: receive one input, produce one output, wait. The enterprise heartbeat was always "process one candle." Now each sub-process has the same discipline at its own granularity. The heartbeat is not dissolved. It is fractally applied.

What I want to see before full acceptance:

1. **The replay guarantee.** Your current fold is deterministic -- same candles, same seed, same result. Rendezvous channels preserve ordering within a pipe, but the fan-out from `enriched` to six observers introduces scheduling nondeterminism. Observer 0 and observer 5 pull from the same source. Who gets candle N first? If the answer is "it does not matter because they are independent," prove it. Show that the final state is identical regardless of scheduling order. If observers share ANY state that is read during encoding and written during propagation, the schedule matters and you have lost determinism.

2. **Error semantics.** A fold has a clear error model: the function fails, the fold stops. In a pipeline, one pipe panics. What happens to the other 23? Do they block forever on a dead channel? `bounded(1)` means the producer blocks on send. If the consumer is dead, the producer hangs. You need a shutdown protocol. This is where channels get complex -- not in the happy path, but in the failure path.

3. **Do not add select.** The moment you need `select!` to multiplex across channels, you have left the fold and entered the event loop. If you find yourself reaching for it, stop. That is the signal that the decomposition is wrong.

The proposal is sound in principle. The fold IS a pipe. The pipe IS a fold. But "in principle" and "in Rust with crossbeam and 24 threads" are different things. Show me the replay test. Show me the shutdown. Keep the bounded(1) invariant sacred. Then this is not channels -- this is just the fold, going faster.
