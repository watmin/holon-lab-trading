# Resolution: Proposal 046 — Pivot Pipes

**Decision: APPROVED. Option A. Unanimous.**

Five designers. Five reviews. Zero disagreement.

## Option A — enrich the chain on the main thread

The PivotTrackers live on the main thread. One tracker per
market observer (11 total). Between collecting MarketChains
and sending to exit observers, the main thread:

1. Ticks each tracker with the conviction, direction, candle
2. Attaches a bounded slice of recent PivotRecords to the chain
3. Attaches the current period state

The MarketChain grows by two fields:

```rust
pub struct MarketChain {
    // ... existing fields ...
    pub pivot_records: Vec<PivotRecord>,   // bounded ~20
    pub current_period: CurrentPeriod,
}
```

The exit observer receives the enriched chain. Reads the
records. Applies a stateless significance filter. Builds
its Sequential thought. No new pipes. No new threads.

## Why Option A

- **Hickey:** "A richer value is still a value. Making the
  value richer is a value-level change. Adding pipes is a
  topology-level change. Values are simple. Topology is not."

- **Beckman:** "The enrichment is a functor applied at the
  composition site. The naturality square commutes."

- **Seykota:** "Zero new channels, zero new threads, zero
  duplicated state machines."

- **Van Tharp:** "Option C's 500-sample window buys precision
  the coarse gate doesn't need."

- **Wyckoff:** "The tape reader hands the trader a reading,
  not the full tape."

## Why not B or C

**Option B (dedicated pipes):** rejected unanimously. Two
messages about the same candle on separate pipes creates a
join problem. Fragmenting one event adds synchronization
complexity for zero benefit.

**Option C (trackers on exit threads):** rejected unanimously.
Contradicts Proposal 045's resolution (post detects, exit
interprets). Creates M redundant Mealy machines consuming
the same conviction stream. Beckman's factoring error.

## The filter

The exit's significance filter is **stateless**. A pure
function over the PivotRecord's fields (duration, conviction,
volume). Not a learner. The deeper learning about which pivots
predict good distances belongs in the exit's reckoner — which
already learns. Do not conflate gating with learning.

## The slice

Bounded. ~20 entries (10 pivots + 10 gaps). Not a growable Vec.
The tracker on the post holds the full rolling state. The chain
carries a bounded snapshot. History belongs to the post.

## What changes

1. Main thread gains 11 PivotTrackers (one per market observer)
2. Main thread ticks trackers between step 2 and step 3
3. MarketChain gains `pivot_records` and `current_period` fields
4. Exit observer reads pivot records from the chain
5. Exit observer applies stateless significance filter
6. Exit observer builds Sequential thought from filtered records

## What doesn't change

- The pipe topology. No new channels. No new threads.
- The chain is still a value — born, transmitted, consumed.
- The exit observer's role: interpret, not detect.
- Zero Mutex. The main thread is the only writer.

## The full 044-045-046 picture

```
044: WHAT — pivot vocabulary, biography atoms, Sequential form
045: WHO  — post detects, exit interprets, N=500, 80th pctile
046: HOW  — enrich the chain, stateless filter, bounded slice
```

Three proposals. One architecture. Ready to build.
