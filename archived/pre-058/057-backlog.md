# 057 Backlog — Remaining Work

## Done

- [x] L1 per-entity LruCache (16K) — absorbs repeated lookups
- [x] L2 shared cache with u64 keys — no recursive hashing
- [x] Precomputed hash on ThoughtAST struct — O(1) cache lookups
- [x] Confirmed batch_set — backpressure, no queue growth
- [x] Batch treasury get_paper_states — 157 round-trips → 1
- [x] Grouped driver loop — writes/reads Vecs, no partition swap
- [x] Rayon tried and removed — overhead exceeded benefit at this granularity

## Current: 18 c/s at 500 candles, degrades to 14.7 c/s at 2750

## Next: DB writer backpressure

The database writer receives LogEntries through unbounded queues.
33 entities × ~20 metrics per candle = ~12K entries/sec at 18 c/s.
The writer flushes ~10K rows/sec. It falls behind. Queues grow
without bound. Memory grows. Swap at ~6000 candles.

Fix: batch + confirmed write. Same pattern as cache batch_set.
- Entity collects its ~20 metrics into a Vec<LogEntry>
- Sends one batch message to the DB writer
- Blocks until the writer acks
- No queue growth. Backpressure is honest.

## Next: RSS tracking

Add VmRSS metric to the main thread candle loop.
Read `/proc/self/status` once per candle. Emit as telemetry.
This is how we detect memory growth — from data, not speculation.

## Next: Treasury paper cleanup

`treasury.papers: HashMap<u64, PaperPosition>` never removes entries.
Papers accumulate forever. Not the swap cause (small) but dishonest.
Resolved papers (Grace/Violence) should be removed after outcome
is recorded.
