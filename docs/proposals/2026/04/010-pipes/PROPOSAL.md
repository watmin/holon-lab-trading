# Proposal 010: Everything Is a Pipe

**Date:** 2026-04-10
**Author:** watmin + machine
**Status:** PROPOSED

## Context

The designers rejected channels in Proposal 001 (March 2026).
Hickey: "The heartbeat is your greatest asset. Don't dissolve it."
Beckman: "Channels replace a clean categorical structure with an
operational model that doesn't compose."

Both said: the fold IS the answer.

They were right. And the fold IS a pipe.

## The point

```ruby
# The enterprise is a chain of lazy enumerators.
# Each one yields when asked. The consumer pulls.
# The producer blocks until the consumer asks.
# Lock step. But all pipes run independently.

# The source — yields one candle at a time
candles = parquet.lazy.each

# The indicator bank — streaming state, sequential
enriched = candles.map { |rc| indicator_bank.tick(rc) }

# Fan-out: one producer, 6 consumers.
# Each observer is its own enumerator chain.
observer_pipes = MARKET_LENSES.map { |lens|
  enriched.map { |candle|
    window = candle_window.last(sampler.sample(encode_count))
    facts  = vocab_for_lens(lens, candle, window)
    observer[lens].observe(encode(facts))
    # yields: (thought, prediction, edge, misses)
  }
}

# 6 producers, 24 consumers — the N×M wiring.
# Each broker pulls from its market observer AND its exit observer.
broker_pipes = (0...N*M).map { |slot|
  mi = slot / M
  ei = slot % M
  observer_pipes[mi].map { |thought, pred, edge, misses|
    exit_facts  = exit_vocab_for_lens(exit_lenses[ei], candle)
    composed    = bundle(thought, encode(exit_facts))
    distances   = exit_observers[ei].recommended_distances(composed)
    broker[slot].propose(composed)
    broker[slot].register_paper(composed, price, distances)
    # yields: (proposal, composed, distances)
  }
}

# 24 producers, 24 consumers — paper tick.
# Each broker ticks its own papers. Disjoint.
tick_pipes = broker_pipes.each_with_index.map { |(pipe, slot)|
  pipe.map { |proposal, composed, distances|
    resolutions = broker[slot].tick_papers(price)
    # yields: (proposal, resolutions)
  }
}

# The treasury consumes all 24 proposal streams.
# The propagation feeds back to observers.
# The fold advances. The pipes flow.
```

Every `.map` is a lazy enumerator. Producer and consumer exist in
lock step — coupled. But between pipes, all pipes run independently.
As fast as possible.

Observer 0 and observer 5 are both pulling from `enriched`. They
run at their own pace. Broker 0 pulls from observer 0. Broker 23
pulls from observer 5. All 24 broker pipes run concurrently.

While the indicator bank computes candle N+1:
- Observer 0 is encoding candle N
- Observer 3 is encoding candle N
- Broker 7 is composing candle N-1
- Broker 15 is ticking papers from candle N-2

The pipeline fills. Every pipe has work. The throughput is the
slowest pipe, not the sum of all pipes.

## The fold IS the pipe

Each pipe IS a fold:

```ruby
# The observer's fold
observer_state = observer_pipe.reduce(initial_state) { |state, candle|
  state.observe(candle)  # → new state
}

# The broker's fold
broker_state = broker_pipe.reduce(initial_state) { |state, thought|
  state.compose(thought)  # → new state
}
```

The enterprise fold `f(state, candle) → state` decomposes into
N+M+N×M sub-folds, each running on its own thread, connected by
channels. The composition of folds IS the enterprise fold.

Hickey said don't dissolve the heartbeat. The heartbeat isn't
dissolved — each pipe HAS a heartbeat. Process one input. Produce
one output. Wait. The heartbeat is per-pipe.

Beckman said channels don't compose. These compose — the morphisms
are the pipes, the channels are the arrows. The diagram commutes.

## In Rust

```rust
// Bounded(1) = lock step. Exactly a lazy enumerator across threads.
let (candle_tx, candle_rx) = crossbeam::channel::bounded(1);

// Each observer is a thread with its own channel pair
let observer_handles: Vec<_> = (0..N).map(|i| {
    let rx = candle_rx.clone();  // fan-out
    let tx = broker_txs[i].clone();
    thread::spawn(move || {
        for candle in rx {
            let thought = observer.observe(encode(candle));
            tx.send(thought).unwrap();
        }
    })
}).collect();
```

`crossbeam::channel::bounded(1)` — the producer writes and blocks.
The consumer reads and the producer unblocks. Lock step. The lazy
enumerator, across thread boundaries.

## What changes

The binary. Not the library. The library modules ARE the pipe bodies.
The binary creates channels, spawns threads, wires them. The N×M
grid IS the channel topology.

## The question

The designers rejected channels. We built the fold they approved.
The fold IS channels. Each pipe IS a fold. Do the designers agree
that the system they approved IS the system they rejected?
