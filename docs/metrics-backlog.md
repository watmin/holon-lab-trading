# Metrics Backlog — Every Thread, Every Computation Point

## Threads in the System

| Thread | Count | Has Timing? | Notes |
|--------|-------|-------------|-------|
| Main (candle loop) | 1 | NO | ticks indicators, clones window, sends to observers |
| Market observer | 11 | PARTIAL | encode breakdown is broken (overlapping) |
| Regime observer | 2 | YES | slot_recv, rhythm, send |
| Broker | 22 | YES | gate4, retain, submit, snapshot |
| Treasury | 1 | NO | processes ticks + requests, checks deadlines |
| Cache driver | 1 | NO | LRU gets, sets, evictions. The suspect. |
| Database driver | 1 | YES | flush_ns, rows, count |
| Console drivers | N | NO | irrelevant |

## Main Thread — NO metrics

The candle loop does per candle:
1. `pipeline.bank.tick(&ohlcv)` — compute 90+ indicators
2. `pipeline.candle_window.push(candle.clone())` — grow window
3. `pipeline.candle_window.clone()` via `Arc::new(...)` — copy the window
4. 11x `tx.send(ObsInput { candle.clone(), Arc::clone(&window) })` — send to observers
5. `treasury_tick_sender.send_tick(...)` — send to treasury

**Missing metrics:**
- `ns_indicator_tick` — IndicatorBank.tick() time
- `ns_window_clone` — Arc::new(window.clone()) time
- `ns_observer_send` — time to send to all 11 observers (are any blocking?)

## Market Observer — BROKEN encode metrics

Has: total, collect_facts, encode, observe, send, drain_learn, facts_count.
Has: enc_nodes, enc_hits, enc_misses, enc_ns_cache_get, enc_ns_compute, enc_ns_cache_set.

**Problem:** enc_ns_compute overlaps with enc_ns_cache_get because it wraps
recursive encode() calls.

**Fix:** measure only leaf computation:
- `enc_ns_leaf` — time in Primitives::bind/bundle/permute, scalar.encode, vm.get_vector ONLY
- Remove enc_ns_compute (it's broken)

**Also missing:**
- `enc_ns_key_clone` — time to clone the ThoughtAST key inside cache.get()

To measure enc_ns_key_clone, split cache.get into two steps:
```rust
let t0 = now();
let cloned = ast.clone();
ns_key_clone += elapsed(t0);
let t0 = now();
let result = cache.get_precloned(cloned);
ns_channel_roundtrip += elapsed(t0);
```
This requires a new cache.get variant that takes an owned key.

## Cache Driver — NO metrics at all

The driver is a thread that runs a tight loop. It has NO timing telemetry.
It emits hit/miss/size counts but not:

- `ns_per_get` — how long to service one get (hash + LRU lookup + Vector clone + send response)
- `ns_per_set` — how long to service one set (hash + LRU put + eviction)
- `gets_serviced` — how many gets processed per loop iteration
- `sets_drained` — how many sets drained per loop iteration
- `get_queue_depth` — total pending gets across all clients when entering phase 2
- `set_queue_depth` — pending sets when entering phase 1
- `ns_idle` — time between "no work available" and "work arrives"
- `evictions` — how many entries evicted per interval (capacity thrashing)

## Treasury — NO timing metrics

The treasury processes ticks and requests through one mailbox.
Every tick: check_deadlines (walks all active papers). Every
request: handle_request (paper state lookup, issue, resolve).

**Missing:**
- `ns_per_tick` — time to process one tick (check_deadlines)
- `ns_per_request` — time to process one request
- `ticks_processed` — count per interval
- `requests_processed` — count per interval
- `active_papers` — current count
- `queue_depth` — pending events when entering recv()

## Broker — PARTIAL

Has: gate4, retain, submit_paper, exit_submit, snapshot, total.
Does NOT have encode breakdown (the gate4 timer wraps the encode).

**Missing:**
- All enc_* metrics on the broker's encode call
- `ns_noise_subspace` — time in broker.noise_subspace.update() + anomalous_component()
- `ns_portfolio_snapshot` — time computing the PortfolioSnapshot

## Regime Observer — OK but missing clone cost

Has: slot_recv, rhythm, send, total.

**Missing:**
- `ns_ast_clone` — regime_asts.clone() per slot (11 clones)

## Queue Depths — NOT measured anywhere

Every bounded/unbounded queue in the system has a depth. If a producer
is faster than a consumer, the queue grows. If a queue is bounded(1),
the producer blocks.

Queues:
- candle_tx → market observer: bounded(1). If blocked, main thread stalls.
- market observer → regime observer: bounded(1) via topic. If blocked, market observer stalls.
- regime observer → broker: unbounded. Can grow without bound.
- broker → treasury: per-request response via bounded(1). If treasury is slow, broker blocks.
- set mailbox → cache driver: unbounded. Can grow.
- get request → cache driver: unbounded. Can grow.
- all → database: unbounded. Can grow.

**Missing:** queue depth snapshots on all queues at regular intervals.

## Summary of Missing Metrics

### Must add (find the bottleneck):
1. Main thread: ns_indicator_tick, ns_window_clone, ns_observer_send
2. Encode: fix ns_compute → ns_leaf only, add ns_key_clone
3. Cache driver: ns_per_get, ns_per_set, get_queue_depth, set_queue_depth, evictions
4. Treasury: ns_per_tick, ns_per_request, active_papers, queue_depth
5. Broker: enc_* metrics on gate4 encode, ns_noise_subspace
6. Queue depths on bounded channels (are producers blocking?)

### Nice to have:
7. Regime observer: ns_ast_clone per slot
8. Cache driver: ns_idle, gets_serviced per iteration
9. Broker: ns_portfolio_snapshot
