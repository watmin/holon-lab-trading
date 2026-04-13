# Proposal 046 — Pivot Pipes

**Scope:** userland

**Depends on:** Proposal 045 (pivot mechanics — who owns detection)

**Spawned by:** 045's resolution. Ownership resolved: post detects,
exit interprets. This proposal resolves HOW the data flows.

## The architecture question

The post holds 11 PivotTrackers — one per market observer. Each
tracker produces PivotRecords (completed pivot/gap periods with
duration, close-avg, volume, conviction, direction). The exit
observer needs these records to build its Sequential thought and
apply its significance filter.

How does the data move from the post to the exit observer
without contention?

## The current pipeline

```
Main thread:
  1. Send candle → 11 market observer threads (bounded(1))
  2. Collect 11 MarketChains back
  3. Send MarketChains → exit observer slots
  4. Collect MarketExitChains
  5. Send MarketExitChains → 22 broker threads (bounded(1))
  6. Collect broker outputs
  7. Propagate learn signals
```

The main thread is the orchestrator. It sits between every
stage. It collects values and routes them. Zero shared mutable
state. The channels are the only synchronization.

## Option A: Enrich the chain on the main thread

The PivotTrackers live on the main thread. Between step 2
(collect MarketChains) and step 3 (send to exit), the main
thread:

```scheme
;; Step 2.5: update pivot trackers, enrich chains
(for-each (lambda (i chain)
  ;; Update the tracker with this candle's conviction
  (tracker-tick! (ref pivot-trackers i)
    (:conviction chain) (:direction chain) (:candle chain))

  ;; Attach the current pivot state to the chain
  (set! chain.pivot-records
    (tracker-recent-records (ref pivot-trackers i)))
  (set! chain.current-period
    (tracker-current-period (ref pivot-trackers i))))
  market-chains)
```

The MarketChain type grows:

```rust
pub struct MarketChain {
    // ... existing fields ...
    pub pivot_records: Vec<PivotRecord>,   // NEW — completed periods
    pub current_period: CurrentPeriod,     // NEW — what we're in now
}
```

The exit observer receives the enriched chain. No new pipes.
The existing bounded(1) channel carries the larger chain. The
main thread is the only writer. The exit observer is the only
reader. No contention.

**Pros:**
- No new pipes. No new threads. The existing fan-out carries it.
- The main thread already has the conviction (it's in the chain).
- Sequential: the main thread processes one candle at a time.
  No concurrent writes to the PivotTracker.
- Values flow through the chain — the same pattern as everything
  else.

**Cons:**
- The MarketChain grows. Each chain now carries a Vec of up to
  20 PivotRecords. At ~100 bytes per record, that's 2KB per
  chain. 11 chains per candle = 22KB. Not significant.
- The main thread does more work between steps 2 and 3.
  PivotTracker tick is cheap (percentile lookup + state update).

## Option B: Dedicated pivot pipe per exit observer

Each exit observer gets a dedicated pipe for pivot records.
The main thread sends pivot updates through these pipes
separately from the MarketChain.

```
Main thread:
  2. Collect MarketChains
  2.5a. Update PivotTrackers
  2.5b. Send PivotUpdate to each exit slot (bounded(1))
  3. Send MarketChains → exit observer slots
```

**Pros:**
- The chain stays lean. Pivot data travels on its own pipe.
- The exit observer can process pivots and market data
  independently.

**Cons:**
- New pipes. 2 exit observers × 11 market observers = 22
  new bounded(1) channels. Or 2 new channels (one per exit),
  each receiving all 11 market observers' pivot updates.
- Ordering: the pivot update and the market chain arrive on
  separate pipes. The exit must synchronize them — "this
  pivot update belongs with this candle." The chain already
  carries the candle. Adding a separate pipe creates a join
  problem.
- More complexity for no measurable benefit. The pivot data
  is small and the chain is the natural carrier.

## Option C: PivotTrackers on the exit observer threads

Each exit observer maintains its own 11 PivotTrackers (one
per market observer it's paired with). The conviction arrives
through the existing MarketChain. The exit observer updates
its own tracker.

```scheme
;; Inside the exit observer thread:
(for-each-slot (lambda (slot chain)
  ;; Update MY tracker for this market observer
  (tracker-tick! (ref my-pivot-trackers (:market-idx slot))
    (:conviction chain) (:direction chain) (:candle chain))
  ;; Build Sequential from MY tracker's records
  ...))
```

**Pros:**
- No changes to the chain type. No changes to the main thread.
- Each exit observer owns its own trackers — no contention.
- Per-exit significance filters are natural — each exit's
  tracker can have its own threshold.

**Cons:**
- 2 exit observers × 11 market observers = 22 PivotTrackers.
  With N=500 rolling windows each, that's 22 × 500 = 11,000
  f64 values. ~88KB. Not significant.
- Redundant computation: both exit observers process the same
  conviction stream from the same market observer. The state
  machines produce identical results (same conviction, same
  threshold, same debounce). Beckman flagged this as a
  factoring error in the review.
- But: if the exit applies its own significance filter AFTER
  the tracker, the trackers ARE identical. The differentiation
  is in the filter, not the detection. This is Beckman's
  "M redundant Mealy machines" argument.

## The recommendation

Option A is the simplest. The main thread updates the trackers.
The chain carries the records. No new pipes. No contention. No
redundancy. Values flow through the existing channel.

But the question is open. The designers may see what we don't.

## Questions for designers

### Strategy designers (Seykota, Van Tharp, Wyckoff)

1. **Does the exit observer need the FULL pivot history or just
   the recent records?** If the exit only needs the last 20
   periods, the chain carries a bounded slice. If the exit needs
   to maintain its own running state (significance filter, per-
   trade pivot counts), it needs something persistent — not just
   what arrives on the chain.

2. **The exit's significance filter — is it stateless or stateful?**
   If stateless (a pure function of the PivotRecord), Option A
   works — the exit reads the chain and filters. If stateful
   (the filter learns over time), the exit needs its own
   persistent pivot state regardless of where detection lives.

### Architecture designers (Hickey, Beckman)

3. **Option A vs B vs C:** given zero Mutex, bounded channels,
   and the existing pipeline, which option is simplest? Which
   avoids complecting? Which composes?

4. **The chain as carrier:** is it appropriate for the MarketChain
   to grow by 2KB to carry pivot records? Or does putting
   streaming state on a per-candle message complect the snapshot
   (this candle's facts) with the history (the pivot series)?

5. **The 045 resolution said "post detects, exit interprets."**
   Option A has the post detecting AND attaching. Option C has
   the exit detecting AND interpreting. Option B splits them
   across pipes. Which matches the resolution?
