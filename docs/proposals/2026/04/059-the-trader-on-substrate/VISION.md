# 059 — Vision

## What we're building

A self-organizing BTC trader that runs on a single laptop:

- **14 cores. 54 GB RAM. No GPU. No cloud. No distributed cluster.**
- Processes 652,608 5-minute BTC candles (Jan 2019 – Mar 2025) in
  ≤40 minutes wall time.
- Three thinkers compose: Market Observer (direction), Regime
  Observer (interpretation, middleware), Broker-Observer (action).
- Treasury validates arithmetic; deadlines enforce time pressure;
  brokers propose; reckoner labels at resolution.
- Stacked binary classification: Up/Down → Hold/Exit →
  Grace/Violence.
- Documented predictive geometry: 60.2% win rate at conviction
  ≥ 0.22, 65.9% at ≥ 0.24, 70.9% at ≥ 0.25 (BOOK Chapter 1's
  baseline).

## What's distinctive about it

A mini AWS in a single process. Queues, request/reply services,
dbs, metrics, parallel workers, L1 + L2 caches — all in one
process. The substrate's chapter-65/66/67 primitives (forms as
coordinates, neighborhoods via `coincident?`, the spell of cache
sharing) are operational because the cache is there.

The trader cold-boots from zero into sustained Grace under venue
costs. No prior weights. No fine-tuned model. Six primitives, an
algebra, a substrate where the primitives compose, and reckoner
that learns from outcomes.

## Why this matters

Every binary the lab has landed on (Up/Down, Hold/Exit,
Grace/Violence) is a discrete projection of a continuous quantity
the substrate already encodes. Every "constant" the trader uses
is a function whose output happens to be invariant. Every
"thought" the broker composes is a coordinate on the algebra
grid.

The trader is the consumer demonstration that the substrate's
claims hold under real workload. Not at toy scale. At
production-shape scale — six years of real candles, hundreds of
trades, real venue costs, real time pressure.

## Where this stands in the lab's lineage

- **Proposal 055** named the game (deadline replaces interest;
  treasury enforces arithmetic; four gates; residue split).
- **Proposal 056** named the architecture (three thinkers;
  rhythms; one OnlineSubspace per thinker).
- **Proposal 057** named the cache (L1 thread-owned + L2
  shared; parallel subtree compute).
- **Substrate arcs** (003 / 023 / 053 / 057 / 058 / 068)
  shipped the primitives.
- **Proofs 016 v4 + 017** demonstrated the dual-LRU coordinate
  cache and the fuzzy-locality cache, operationally.

This umbrella ships the trader on top of all of it. The
architecture is known-good; the thoughts are dynamic;
Phase 1 builds the playground; Phase 2 iterates thoughts in it;
Phase 3 captures the sustained run.

## Honest scope

This umbrella confirms:

- The substrate's primitives compose into a working trader.
- The lab's predictive geometry holds under the new substrate.
- The cache cookbook (arcs 001 / 036 / 057 + the wat-vm's
  queue-based program shape) supports the workload at the
  ≥272 candles/sec target.
- Cold-boot self-organization from zero observations to
  sustained Grace is empirically achievable.

This umbrella does NOT confirm:

- Real-money trading. The 6-year backtest is the consumer demo
  scope; live capital is a separate question outside this work.
- Adversarial robustness. Out of scope; future arc.
- Multi-asset. BTC only; multi-asset is future arc per
  Proposal 002.
- Networked deployment. Single-process; the chapter-67 spell
  is structurally supported but not exercised here.
