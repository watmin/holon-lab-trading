# Metrics Backlog — Every Thread, Every Computation Point

## Threads in the System

| Thread | Count | Has Timing? | Difficulty |
|--------|-------|-------------|------------|
| Main (candle loop) | 1 | NO | trivial — wrap existing calls |
| Market observer | 11 | BROKEN | fix — leaf-only compute timer |
| Regime observer | 2 | YES | done |
| Broker | 22 | PARTIAL | trivial — add take_encode_metrics |
| Treasury | 1 | NO | trivial — wrap event processing |
| Cache driver | 1 | NO | medium — timing inside the closure, widen emit |
| Database driver | 1 | YES | done |
| Console driver | 1 | NO | irrelevant |

## 1. Main Thread — trivial

Wrap existing calls. Emit via stream_handles or a db_tx.

```
ns_indicator_tick    — IndicatorBank.tick()
ns_window_clone      — Arc::new(pipeline.candle_window.clone())
ns_observer_send     — the loop sending to 11 observers (blocking on bounded(1)?)
```

## 2. Market Observer Encode — fix

Replace broken enc_ns_compute (overlapping) with enc_ns_leaf (non-overlapping).
Time only the Primitives call, not recursive children.

Also split ns_cache_get into:
- `enc_ns_key_clone` — ast.clone() before send
- `enc_ns_channel_rt` — send + recv (waiting for driver)

This requires splitting the `cache.get()` call in encode.rs — clone
the key explicitly, then send the owned key. CacheHandle.get currently
takes `&K` and clones internally. Change to take owned K, or add a
second method.

## 3. Cache Driver — medium

The driver is an anonymous closure inside `cache()`. We control it.
The existing `emit` callback takes `(hits, misses, cache_size)`.
Widen it to include timing:

```
emit(hits, misses, cache_size, ns_gets, ns_sets, evictions, get_queue_depth, set_queue_depth)
```

Inside the driver loop, accumulate:
- `ns_gets` — total time in `cache.get(&key).cloned()` + `resp_tx.send()`
- `ns_sets` — total time in `cache.put(key, value)`
- `evictions` — count LRU evictions (LruCache doesn't expose this directly;
  check if `cache.len() == capacity` before put, if so +1 eviction)
- `get_queue_depth` — sum of `alive_get_rxs[i].len()` at start of phase 2
- `set_queue_depth` — `set_rx.len()` at start of phase 1

The emit closure at the call site in wat-vm.rs already constructs
telemetry entries. Widen it to emit the new fields.

## 4. Treasury — trivial

Wrap the event processing in treasury_program.rs. The recv loop
already matches Tick vs Request.

```
ns_tick             — check_deadlines time
ns_request          — handle_request time
active_papers       — papers.len()
```

Emit via the existing db_tx (treasury already has one).

## 5. Broker Encode — trivial

Call `take_encode_metrics()` after the gate4 encode. Emit the
same enc_* fields the market observer emits. Add ns_noise_subspace
around the subspace update + anomalous_component calls.

## 6. Queue Depths — trivial per queue

Crossbeam `.len()` on each queue at emit time. The main thread
can check `candle_tx.len()` to see if observers are backed up.
The cache driver already sees queue depths in the emit extension.

The regime observer → broker queues are unbounded. Check their
depth in the broker's telemetry via the chain_rx.

## Order

1. Fix encode leaf timer + key clone split (enables diagnosis)
2. Cache driver timing (the prime suspect)
3. Main thread timing (is it blocking on sends?)
4. Treasury timing (is it slow processing?)
5. Broker encode metrics (is the broker's encode different?)
6. Queue depths (where is backpressure?)
