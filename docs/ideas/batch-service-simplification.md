# Service simplification: revisit the select loop now that batching is the unit

**Status:** reminder. Not a proposal. Something to investigate when perf becomes the focus again.

## The observation

After 057 (L1/L2 cache) and the grind from 1 c/s to 7.1 c/s, the service drivers (cache, log, etc.) use a sweep-and-batch pattern:

1. `try_recv` across ALL client queues in a loop
2. Collect everything pending into a working set
3. Partition (e.g., sets before gets in the cache)
4. Process the whole working set
5. Respond to all clients at once

This pattern was designed for high-frequency SMALL requests — many clients each sending one item at a time, batching across clients to amortize fixed driver costs.

## What changed

The callers now send BATCHES of work per request. The encode pipeline uses `batch_get` and `batch_set` with many keys per call. Each single message IS already a batch.

The driver is now double-batching: the client's batch + the cross-client sweep. The second layer may not carry its weight anymore.

## The hypothesis

A simpler driver might be faster now:

```
loop {
    match select(all_client_receivers) {
        Some((client_idx, request)) => {
            // request is a batch — process it end-to-end
            let response = handle(request);
            send_back(client_idx, response);
        }
        None => break,  // all disconnected
    }
}
```

One select. One complete work unit per iteration. No sweep. No partitioning across clients. The client's batch IS the work unit.

Why it might be faster:
- No `try_recv` loop overhead per iteration
- No cross-client partitioning logic
- Cache locality — the driver handles one client's batch before moving on, keeping working memory hot
- Clearer flow control — one client blocks waiting for response, others block waiting in their channels (which they already do with bounded(1))

Why it might NOT be faster:
- Cross-client parallelism in the sweep phase might matter for specific workloads
- Partitioning (sets before gets) might be load-bearing for correctness if callers rely on consistency within a round
- Measurement dependent — hard to predict without benchmark

## What to measure

A benchmark that compares:
- Current sweep-and-batch driver
- Simplified select-loop-one-batch driver

Against typical workloads:
- 100-candle warmup (cache cold)
- 1000-candle steady state (cache warm)
- 5000-candle full run (cache dynamic)

Metrics:
- Candles per second (primary)
- Median batch-processing latency
- P99 batch-processing latency
- CPU utilization per thread

If the simplified driver is equal or faster, migrate. If it's slower, the sweep pattern is earning its keep and the note was wrong.

## Why this hasn't been done

The sweep-and-batch pattern works. Throughput is acceptable at 7.1 c/s. The perf grind of 057 didn't identify this as the bottleneck — the cache pipe latency was. Changing driver topology mid-flight would risk regressions in a proven code path.

But once the algebra surface proposals (058+) settle and we're back to pure performance focus, this is a clean win candidate. Lower complexity code. Possibly faster. Worth measuring.

## Where this touches

- `src/programs/stdlib/cache.rs` — the cache driver loop
- `src/programs/stdlib/database.rs` — the log service driver loop
- Any future stdlib program with a sweep pattern

One change per driver. Isolated. Reversible.

## Not a priority

Algebra surface work (058) is the current focus. This note just marks the territory so we don't forget when perf is the lens again.
