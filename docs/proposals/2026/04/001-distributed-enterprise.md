# Sketch: Distributed Enterprise

**Status:** notes / thinking out loud  
**Date:** 2026-04-03

## The Insight

The enterprise is already decomposed. The wat says:
- Desks don't own the treasury
- Desks don't know about other desks
- The desk recommends. The treasury executes.

The coupling between components is narrow and well-typed. This means the enterprise can be split across processes, hosts, or even geographies — with queues between them.

## The Candle Feed

One source of truth: a raw candle stream. OHLCV + timestamp. Today it's a parquet file iterated locally. Tomorrow it's a websocket from an exchange. The feed is a broadcast — every consumer gets every candle.

```
Exchange WSS ──→ Candle Feed (broadcast)
                    │
                    ├──→ Desk: BTC-USDC (host A)
                    ├──→ Desk: ETH-USDC (host B)
                    ├──→ Desk: SOL-USDC (host C)
                    └──→ Risk Department (host D)
```

The candle feed is the only shared input. Each consumer subscribes independently. NATS, Redis Streams, Kafka, ZeroMQ pub/sub — the transport doesn't matter. The message is 6 floats and a timestamp.

## Desk as Independent Process

A desk is a complete trading unit:
- Indicator bank (steps from raw OHLCV)
- Candle window (ring buffer)
- 6 observers (each with journal, window sampler, proof gate)
- Manager (reads observer opinions, predicts)
- Exit expert (learns hold/exit from position state)
- Positions (managed allocations)
- Pending entries (learning queue)
- Conviction + curve

**Input:** raw candle stream (subscribe to feed)  
**Output:** trade signal

```
Signal {
    desk_id:    String,      // "btc-usdc"
    timestamp:  String,
    direction:  Direction,   // Buy | Sell
    conviction: f64,
    sizing_rec: f64,         // half-kelly from desk's curve
    band:       (f64, f64),  // proven conviction band
    observers:  Vec<(Lens, f64, bool)>,  // lens, conviction, gate_open
}
```

The signal is small. A few hundred bytes. The desk doesn't know if anyone is listening. It publishes every candle. The queue carries it.

## Treasury as Independent Process

The treasury is the execution engine:
- Holds all assets (map of token → balance)
- Receives signals from N desks via queue
- Applies risk gate (risk_mult from risk department)
- Executes swaps (or paper-trades)
- Manages position lifecycle
- Writes the ledger

**Input:** trade signals (from desks), risk_mult (from risk department), price feed (from candle feed)  
**Output:** execution confirmations, portfolio state

```
Treasury (host)
    ├── Subscribe: signal queue (from all desks)
    ├── Subscribe: risk queue (from risk department)
    ├── Subscribe: candle feed (for price updates)
    │
    ├── For each signal:
    │     if risk_mult > gate_threshold
    │       && signal.conviction in signal.band
    │       && market_moved(...)
    │     then: swap(source, target, amount, price, fee)
    │
    └── Publish: execution confirmations
        Publish: portfolio state (for risk department)
```

The treasury's fold is sequential — signals arrive, get processed in order. No parallelism needed. The treasury is the serialization point.

## Risk Department as Independent Process

Risk measures portfolio health across ALL desks:
- 5 OnlineSubspace branches (drawdown, accuracy, volatility, correlation, panel)
- Consumes portfolio state from treasury
- Publishes risk_mult to treasury

**Input:** portfolio state (from treasury)  
**Output:** risk_mult (single f64, published every recalib interval)

Risk is the slowest-changing signal. It evaluates every N candles, not every candle. A single float published on a slow cadence.

## Desk Learning Loop

The desk needs to know what happened after its signal. Two options:

**Option A: Desk is self-contained.** The desk tracks its own pending entries and resolves them from the price stream. It doesn't need to know if the treasury executed. It learns from price movement relative to its predictions, not from trade outcomes. This is what the current architecture does — the desk's learning is independent of execution.

**Option B: Desk receives confirmations.** The treasury publishes execution events. The desk subscribes and uses actual fill prices for learning. More accurate P&L tracking per desk, but adds a feedback channel.

Option A is simpler and already implemented. The desk learns whether or not the treasury acts. The pending entries resolve from price movement. The treasury's execution is orthogonal to the desk's learning.

## The Topology

```
                    ┌─────────────────────────────┐
                    │       Candle Feed            │
                    │   (exchange WSS → broadcast) │
                    └──────────┬──────────────────-┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
     ┌────────────┐   ┌────────────┐   ┌────────────┐
     │  Desk:     │   │  Desk:     │   │  Desk:     │
     │  BTC-USDC  │   │  ETH-USDC  │   │  SOL-USDC  │
     │  (host A)  │   │  (host B)  │   │  (host C)  │
     └─────┬──────┘   └─────┬──────┘   └─────┬──────┘
           │                │                │
           └────────────────┼────────────────┘
                            │ signal queue
                            ▼
                   ┌─────────────────┐
                   │    Treasury     │◄──── risk_mult
                   │   (host D)     │
                   └────────┬────────┘
                            │ portfolio state
                            ▼
                   ┌─────────────────┐
                   │ Risk Department │
                   │   (host D)     │
                   └─────────────────┘
```

## What This Enables

1. **Geographic distribution.** Desk near the exchange for low-latency candle feed. Treasury near the execution venue.

2. **Independent scaling.** Add a desk by deploying a new process that subscribes to the candle feed and publishes to the signal queue. The treasury doesn't change.

3. **Independent deployment.** Update a desk's vocabulary, retrain its observers — redeploy one process. Other desks and treasury are unaffected.

4. **Fault isolation.** A desk crashes. Other desks keep signaling. Treasury keeps executing. The crashed desk restarts and catches up from the candle feed.

5. **Multi-venue.** Different desks on different exchanges. Each subscribes to its own feed. All signal to the same treasury.

6. **Backtesting at scale.** Spin up 100 desks with different vocabularies. Each processes the same parquet stream independently. The signals collect in a queue. Analyze which desks produce the steepest curves.

## What Doesn't Change

- The algebra (six primitives)
- The fold (sequential at each node)
- The wat specs (desk.wat, enterprise.wat describe the same logic)
- The learning loop (pending entries resolve from price)
- The curve (judges each desk independently)

## What Changes

- The enterprise binary splits into: desk binary, treasury binary, risk binary
- The in-process function calls become queue messages
- State that was shared via &mut references becomes messages on queues
- The backtest harness replays a parquet stream to a local queue instead of iterating a Vec

## Transport Candidates

| Transport | Pros | Cons |
|-----------|------|------|
| NATS | Simple pub/sub, subjects, lightweight | No persistence by default |
| Redis Streams | Consumer groups, persistence, familiar | Heavier, single-node bottleneck |
| ZeroMQ | Zero-broker, pure library, fast | Manual topology, no persistence |
| Kafka | Persistence, replay, partitions | Heavy, operational overhead |
| Unix domain sockets | Simplest for single-host | No distribution |

For the first cut: NATS or ZeroMQ. The messages are small (< 1KB). The cadence is one per 5-minute candle per desk. This is not a high-throughput problem. The transport barely matters.

## Relationship to pmap

The wat proposal 001-parallel-map (in the wat repo) addresses parallelism WITHIN a single process — observers encoding in parallel within one desk. This sketch addresses parallelism ACROSS processes — desks running independently. Both are valid. Both compose. pmap is the micro-parallelism. Distribution is the macro-parallelism. Neither requires the other.
