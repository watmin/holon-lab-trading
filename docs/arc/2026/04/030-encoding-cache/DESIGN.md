# lab arc 030 — Encoding cache + LogEntry::Telemetry

**Status:** opened 2026-04-25.
**Predecessor arc:** [`docs/arc/2026/04/029-rundb-service/`](../029-rundb-service/DESIGN.md) (closed 2026-04-25).
**Consumer:** proof 003 baseline ships ~10 minutes for 200k candles (10 windows × 2 thinkers × 10k); the user's read of where the time goes is "vector ops" (cosine + encoding). This arc closes the per-call redundancy.

Builder direction (2026-04-25, after profiling discussion):

> "we had incredible telemetry and metrics rigged up into the
> logging db before - gave us great insight - the cost /is/ the
> vector ops - the encoding cache is necessary"

> "we don't need a cache service until we have many concurrent
> encoders - right now we're single threaded so we can just use
> a local cache"

> "i've we can toss like 30G at this"

Two surfaces in this arc, intentionally coupled:

1. **`LogEntry::Telemetry` variant** — second variant on the
   arc 029 sum. CloudWatch-style row payload. Mirrors
   `archived/pre-wat-native/src/types/log_entry.rs`'s
   `Telemetry` shape. Lives in its own table; emit helpers
   for callers.
2. **Encoding cache** — `:wat::lru::LocalCache<HolonAST, Vector>`
   wrapping the `:wat::holon::cosine`'s implicit encode step.
   Plus pre-encoding the four corner ASTs in `cosine-vs-corners-predictor`
   so they bypass the cache entirely. Cache emits hit/miss/size
   metrics via the new Telemetry variant.

Cross-references:
- `archived/pre-wat-native/src/types/log_entry.rs` — `LogEntry::Telemetry { namespace, id, dimensions, timestamp_ns, metric_name, metric_value, metric_unit }` (Arc<str> on namespace/id/dims so callers build them once per candle and refcount-clone per metric).
- `archived/pre-wat-native/src/programs/telemetry.rs` — `emit_metric` / `flush_metrics` / `make_rate_gate` helpers.
- `archived/pre-wat-native/src/domain/ledger.rs` — `LogEntry::Telemetry` → `telemetry` table dispatch.
- `archived/pre-wat-native/src/bin/wat-vm.rs` — encoding cache wiring (cache_telemetry_tx, cache_emit, gate-pattern).
- `wat-rs/crates/wat-lru/wat/lru/lru.wat` — `:wat::lru::LocalCache<K,V>` surface. v1 of this arc consumes; future cache-service variant lives in arc N>30.
- `wat/sim/v1.wat:107-139` — `cosine-vs-corners-predictor` (the hot path; 4 `cosine` calls per invocation).

---

## Why this arc, why now

Proof 003 baseline confirms ~30s/window on 10k candles. With
200k candles in flight (10 windows × 2 thinkers), wall-clock
is ~10 minutes. Per the user, the bottleneck is vector ops in
`cosine-vs-corners-predictor`'s four `cosine` calls per
invocation.

Looking at `wat/sim/v1.wat:107-139`:

```scheme
(:wat::core::lambda
  ((surface :wat::holon::HolonAST) -> :trading::sim::Action)
  (:wat::core::let*
    (((c-gu :f64) (:wat::holon::cosine surface (:trading::sim::corner-grace-up)))
     ((c-gd :f64) (:wat::holon::cosine surface (:trading::sim::corner-grace-dn)))
     ((c-vu :f64) (:wat::holon::cosine surface (:trading::sim::corner-violence-up)))
     ((c-vd :f64) (:wat::holon::cosine surface (:trading::sim::corner-violence-dn))))
    ;; argmax → Action
    ...))
```

Each `cosine` call must encode both ASTs to vectors (4096-dim
holon space) then compute the dot product. Per predictor
invocation:

- **The four corner ASTs are constants.** Encoded 4× per call,
  but evaluate to the same vector every time. Pre-compute once
  at predictor construction → 4× redundant encode work
  eliminated.
- **The surface AST is encoded 4× per call** (once per
  cosine). Memoize in-call → 75% encode work eliminated.
- **The surface AST may repeat across papers** (similar
  indicator states recur across the candle stream). Cache
  across calls → ?% additional work eliminated, depending on
  pattern recurrence rate. The Telemetry tells us.

Single-thread context per builder direction; `LocalCache`
(thread-owned) suffices. Multi-broker / multi-thread era
upgrades to a `CacheService` (a future arc, not this one).

Coupling with telemetry: a cache without observability is
guesswork. The archive shipped them together for that reason
("incredible telemetry and metrics rigged up... gave us great
insight"). Arc 030 keeps that coupling — Slice 1 lands
`LogEntry::Telemetry` (also useful for non-cache emits going
forward); Slice 2 builds the cache that consumes it.

---

## What ships

Three surfaces.

### Slice 1 surface — `LogEntry::Telemetry` variant

```scheme
;; wat/io/log/LogEntry.wat — second variant added.
(:wat::core::enum :trading::log::LogEntry
  (PaperResolved
    ...)
  (Telemetry
    (namespace :String)        ; "cache" | "predictor" | ...
    (id :String)               ; "encode-cache" | etc.
    (dimensions :String)       ; serialized JSON, e.g. {"window":"w0"}
    (timestamp-ns :i64)        ; epoch nanos at emit
    (metric-name :String)      ; "hits" | "misses" | "size" | ...
    (metric-value :f64)        ; the measured value
    (metric-unit :String)))    ; "Count" | "Bytes" | "Microseconds" | ...
```

```scheme
;; wat/io/log/schema.wat — new DDL constant + registry entry.
(:wat::core::define
  (:trading::log::schema-telemetry -> :String)
  "CREATE TABLE IF NOT EXISTS telemetry (
     namespace     TEXT NOT NULL,
     id            TEXT NOT NULL,
     dimensions    TEXT NOT NULL,
     timestamp_ns  INTEGER NOT NULL,
     metric_name   TEXT NOT NULL,
     metric_value  REAL NOT NULL,
     metric_unit   TEXT NOT NULL
   );")

(:wat::core::define
  (:trading::log::all-schemas -> :Vec<String>)
  (:wat::core::vec :String
    (:trading::log::schema-paper-resolved)
    (:trading::log::schema-telemetry)))   ; ← added
```

Shim adds `log_telemetry`:

```rust
pub fn log_telemetry(
    &mut self,
    namespace: String, id: String, dimensions: String,
    timestamp_ns: i64,
    metric_name: String, metric_value: f64, metric_unit: String,
);
```

`Service/dispatch` gains the Telemetry arm. Standard four-step
add-a-variant work per arc 029 Q9.

### Slice 1 surface — emit helper (constructor only)

Mirrors `archived/.../programs/telemetry.rs::emit_metric`:

```scheme
;; wat/io/log/telemetry.wat — convenience wrapper.

(:wat::core::define
  (:trading::log::emit-metric
    (namespace :String) (id :String) (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String) (metric-value :f64) (metric-unit :String)
    -> :trading::log::LogEntry)
  (:trading::log::LogEntry::Telemetry
    namespace id dimensions timestamp-ns
    metric-name metric-value metric-unit))
```

Pure constructor — builds a `Telemetry` LogEntry value from
its fields. Caller accumulates these in a local `Vec<LogEntry>`
and flushes via `Service/batch-log` per natural event cadence
(see Q7).

**No `make-rate-gate` in slice 1** — descoped per Q7 below.
The first batch of telemetry consumers (Treasury, future
broker/observer programs) all have natural event rhythms
(per-Tick, per-candle); the program rhythm IS the rate gate
when one exists. The cache (slice 2) is the only consumer
WITHOUT a natural rhythm; that's where a rate gate becomes
load-bearing, and it lands in slice 2 (or a follow-up arc)
when the substrate path is clearer.

### Slice 2 surface — encoding cache

Single-thread `:wat::lru::LocalCache<:wat::holon::HolonAST, :wat::holon::Vector>`
wraps the encode step. Plus the predictor's corners pre-encoded
at construction.

```scheme
;; wat/sim/encoding-cache.wat — new file.

(:wat::core::typealias :trading::sim::EncodeCache
  :wat::lru::LocalCache<wat::holon::HolonAST,wat::holon::Vector>)

;; Construct a fresh cache. capacity = max distinct ASTs to retain
;; before LRU eviction. With ~10k candles per window and surface
;; ASTs unlikely to exceed candle count, capacity 100k covers a
;; 6-year run with headroom.
(:wat::core::define
  (:trading::sim::encode-cache-new
    (capacity :i64)
    -> :trading::sim::EncodeCache)
  (:wat::lru::LocalCache::new capacity))

;; Cached encode: lookup, miss → encode + put + return; hit → return.
;; Emits a metric on lookup (gated externally).
(:wat::core::define
  (:trading::sim::encode-cached
    (cache :trading::sim::EncodeCache)
    (ast :wat::holon::HolonAST)
    -> :wat::holon::Vector)
  ;; (lookup; if Some return; else encode + put + return)
  ...)
```

Predictor changes — `cosine-vs-corners-predictor` becomes
`cosine-vs-corners-predictor-cached`:

```scheme
(:wat::core::define
  (:trading::sim::cosine-vs-corners-predictor-cached
    (cache :trading::sim::EncodeCache)
    -> :trading::sim::Predictor)
  (:wat::core::let*
    ;; Pre-encode the corners ONCE — they're constants. Goes into
    ;; the cache as the first four entries; subsequent surface lookups
    ;; will fight with these for LRU slots, but the corners always
    ;; re-promote on hit so they stay warm.
    (((v-gu :wat::holon::Vector)
      (:trading::sim::encode-cached cache (:trading::sim::corner-grace-up)))
     ((v-gd :wat::holon::Vector)
      (:trading::sim::encode-cached cache (:trading::sim::corner-grace-dn)))
     ((v-vu :wat::holon::Vector)
      (:trading::sim::encode-cached cache (:trading::sim::corner-violence-up)))
     ((v-vd :wat::holon::Vector)
      (:trading::sim::encode-cached cache (:trading::sim::corner-violence-dn))))
    (:trading::sim::Predictor/new
      (:wat::core::lambda
        ((surface :wat::holon::HolonAST) -> :trading::sim::Action)
        (:wat::core::let*
          ((v-surface :wat::holon::Vector)
           (:trading::sim::encode-cached cache surface))
          ;; cosine on already-encoded vectors — no AST→Vector dance per call
          (:wat::core::let*
            (((c-gu :f64) (:wat::holon::cosine-vec v-surface v-gu))
             ((c-gd :f64) (:wat::holon::cosine-vec v-surface v-gd))
             ...)
            ...))))))
```

(`:wat::holon::cosine-vec` is the vector-vs-vector form. If
the substrate doesn't expose that distinct from `:wat::holon::cosine`
— i.e., today's cosine always takes ASTs — a small substrate
addition lands as part of slice 2. Or the cache's value type
shifts to `Vector`-wrapped-as-AST so `cosine` accepts it
unchanged. Implementer's call.)

### Slice 2 surface — cache emits Telemetry

Inside `encode-cached`: on lookup, increment internal counters
(hit / miss). After every N operations OR when a rate gate
opens, emit a Telemetry batch via `:trading::rundb::Service/batch-log`
(if a service handle is in scope) or accumulate locally for
later flush.

The metrics emitted (cluster of one row per metric per emit
window):

| metric_name | unit | meaning |
|-------------|------|---------|
| `hits`      | `Count` | cache hits since last emit |
| `misses`    | `Count` | cache misses since last emit |
| `size`      | `Count` | current cache occupancy |
| `capacity`  | `Count` | cache max capacity (constant per emit) |
| `hit_rate`  | `Percent` | hits / (hits + misses) since last emit |
| `evictions` | `Count` | LRU evictions since last emit |

`namespace = "encode-cache"`, `id = "predictor:cosine-vs-corners"`,
`dimensions = '{"window":"<run-name>"}'`. Mirrors archive's
shape.

---

## Decisions resolved

### Q1 — Why couple cache + telemetry in one arc?

The user surfaced both in the same exchange:

> "we had incredible telemetry and metrics rigged up into the
> logging db before - gave us great insight - the cost /is/
> the vector ops - the encoding cache is necessary"

A cache without observability is guesswork. Hit rate, eviction
churn, capacity-vs-occupancy — without these, you can't tell
if the cache is working, oversized, undersized, or actively
degrading the workload via cache thrashing. The archive
shipped them together for this reason; this arc preserves
that coupling.

`LogEntry::Telemetry` is also useful independent of the cache
(future emitters: simulator throughput, predictor latency,
RunDb commit duration, candle stream rate). So the variant
itself isn't cache-coupled — it's the second LogEntry variant
on a sum that will keep growing.

### Q2 — Why `LocalCache`, not `CacheService`?

Builder direction:

> "we don't need a cache service until we have many concurrent
> encoders - right now we're single threaded so we can just
> use a local cache"

Proof 003 runs single-threaded; the predictor's cache lives
on the simulator's thread. `:wat::lru::LocalCache<K,V>` is the
right shape — thread-owned, no MutEx, no driver loop.

Future multi-broker concurrency (the multi-asset enterprise
shape from CLAUDE.md) replaces the local cache with a
`:wat::lru::CacheService<K,V>` request/reply driver. That's a
future arc; the predictor's cache parameter just changes type
from `LocalCache` to a `CacheService::ReqTx + AckTx + AckRx`
triple. Same interface shape.

### Q3 — Cache key is `HolonAST`, value is `Vector`. Hashable?

`:wat::holon::HolonAST` is a tree-of-symbols; it must support
structural equality + hash for use as `LocalCache` key. The
substrate already supports this for `Atom<HolonAST>` (per
`wat-rs` Phase 4 work), so the constraint should be met. If
the implementer hits a concrete gap during slice 2, capture
in INSCRIPTION as a substrate-uplift carry-along.

`:wat::holon::Vector` — likely an Arc<Vec<f64>> internally
based on archive shape. Cheap to clone (Arc bump). 4096-dim ×
8 bytes = 32 KB per vector. With 30 GB budget and capacity
100k, total memory ~3 GB; well within budget.

### Q4 — Cache capacity?

100,000 entries default. Configurable at construction.
Sizing rationale:

- 10k candles per window; ~10k unique surface ASTs per window
  (loose upper bound — many candles will have similar surfaces).
- 10 windows; ~100k distinct ASTs across the proof 003 corpus
  (also loose; surfaces likely repeat across windows).
- 100k slots × 32 KB = 3.2 GB per cache instance. 30 GB
  budget supports ~10 such caches (or one of 10× capacity if
  the encoding-vs-recall ratio favors it).

The user's 30 GB note suggests "don't be cheap on capacity";
err on the high side. The Telemetry will tell us the right
size empirically — capacity vs occupancy ratio + eviction
rate + hit rate together pin the right number for this
workload.

### Q5 — What's the cache's lifetime / scope?

**One cache per simulator-pass** (per `run-loop` invocation).
Built fresh inside `cosine-vs-corners-predictor-cached` at
predictor construction; lives until the predictor is dropped.

This means: no cross-thinker reuse (always-up's surfaces
won't warm sma-cross's cache). Reasonable v1 — the surfaces
DIFFER between thinkers anyway (different paper lifecycles
→ different SimState → different surfaces). Cross-window
reuse within one thinker IS achieved (cache survives across
all 10 windows of one thinker pass).

A future arc could lift the cache to per-(thinker, predictor)
or per-process for cross-thinker reuse, but the gain is
unclear without measurement. v1 stays per-predictor-construction.

### Q6 — Pre-encode corners: cache or precompute?

**Both, with the cache as the source of truth.** At predictor
construction:

```scheme
(let* ((v-gu (:trading::sim::encode-cached cache (corner-grace-up))) ...)
  (Predictor/new (lambda (surface) ...
                   (cosine-vec v-surface v-gu) ...)))
```

The four corners go through the cache (one miss + one put
each at predictor construction). The closure captures the
already-encoded vectors. Subsequent calls use captured
vectors, never touch the cache for corners.

This means: corners are NOT re-fetched per cosine call, so
they don't compete with surface ASTs for LRU slots after
construction. Win: single-pass encode at construction;
cache stays focused on surfaces.

### Q7 — Rate gate for telemetry emit (descoped from slice 1)

**The program rhythm IS the rate gate when one exists.**
Looking at how the archive actually used telemetry: every
event-driven program (treasury, broker, market_observer,
regime_observer) accumulates a `Vec<LogEntry>` per event
(per-Tick or per-candle), then `flush_metrics(db, &mut pending)`
ONCE per event. The "rate" is implicit in the event cadence —
no separate gate needed.

The archive's `make_rate_gate(Duration)` was specifically for
the cache (no natural event cadence — the cache is hit
asynchronously by brokers) and the database driver (its own
internal telemetry). Most callers never used it.

**Slice 1 ships JUST `emit-metric` (the constructor).** Pure
function `(namespace, id, dimensions, ts, name, value, unit)`
→ `LogEntry::Telemetry`. Callers accumulate + flush via
`Service/batch-log` per event.

**`make-rate-gate` defers to slice 2 (or a follow-up arc).**
The first wat-side need is the cache's hit/miss emit, which
is slice 2's concern. Slice 2 picks the implementation:
either (a) time-based gate via a substrate mutable-cell
primitive (gap; needs substrate work), or (b) counter-based
gate (open every N ops; trivial in wat with a thread-owned
cell or Reckoner-style mutable). Implementer's call when
slice 2 lands.

**Why this matters for slice 1's scope:** dropping the rate
gate descopes slice 1 to ~150 LOC (variant + schema +
dispatch + emit-metric + 2 smoke tests instead of 3) and
removes the substrate-mutable-cell risk from the critical
path. Treasury (the first telemetry consumer in
`docs/experiments/2026/04/008-treasury-program/`) doesn't
need the gate — it emits per Tick.

### Q8 — `wat::holon::cosine-vec` — does it exist?

Open. If today's `:wat::holon::cosine` only accepts ASTs (encoding
internally), slice 2 either:
(a) adds a substrate-side `cosine-vec` that takes already-encoded
vectors directly — small carry-along arc, ~30 LOC of Rust + check,
or
(b) wraps the encoded vector in a synthetic AST (e.g., a "literal"
node) that the existing cosine recognizes and bypasses encoding for.

(a) is cleaner; (b) is uglier but requires no substrate change.
Implementer picks; INSCRIPTION captures.

---

## Implementation sketch

Three slices, tracked in [`BACKLOG.md`](BACKLOG.md):

- **Slice 1** — `LogEntry::Telemetry` variant + `emit-metric`
  constructor (NO rate gate per Q7). Schema, dispatch, shim
  method, two smoke tests (variant round-trip + emit-metric
  helper). ~150 LOC.
- **Slice 2** — Encoding cache + corners pre-encode +
  predictor-cached + cache emits Telemetry. Possible
  substrate carry-along (`cosine-vec`). ~400 LOC depending
  on the substrate path.
- **Slice 3** — INSCRIPTION + flip a downstream proof from
  BLOCKED to ready. The downstream consumer is a follow-up
  proof (proof-perf-001 or similar) that re-runs proof 003
  with caching enabled and measures the speedup + cache stats.

Total estimate: ~6 hours = a day of focused work. Heavier
than arc 029 because of the substrate-carry-along risk on Q8.

---

## What this arc does NOT add

- **CacheService variant.** Single-thread `LocalCache` only
  per Q2; multi-broker future arc adds the service variant.
- **Cross-process cache.** Per-process only.
- **Persistence.** Cache is in-memory; doesn't survive
  process restart. Future arc when a long-running daemon
  surfaces.
- **More LogEntry variants beyond Telemetry.** `BrokerSnapshot`,
  `Diagnostic`, `ObserverSnapshot`, etc. — future arcs as
  consumer proofs surface them.
- **Auto-instrumentation of other call sites.** Telemetry
  emission is opt-in per call site. Future arc adds a tracing
  layer if/when manual emit becomes tedious.
- **Cache-key normalization.** Two ASTs that are semantically
  equivalent but structurally different (e.g., reordered
  bundle args) hash differently and miss the cache. If the
  encoder normalizes pre-hash, fine; if not, future arc adds
  normalization.
- **Variable-rate emit windows.** Fixed 1s interval for v1.
  Future arc when bursty workloads need adaptive cadence.

---

## What this unblocks

- **Proof-perf-001** (proposed follow-up) — re-runs proof 003
  with cache enabled, captures cache-hit-rate + speedup
  numbers. The first quantified perf-gain claim from VSA
  caching in this codebase.
- **6-year stream proofs** (proof 004 and beyond) — make a
  650k-candle run feasible inside a single test session
  (current uncached extrapolation: 10s per 1k candles ×
  650 = ~108 min; cached, depending on hit rate, potentially
  10× faster).
- **Multi-thinker comparison proofs** (proof 005+) — caching
  gain compounds across thinker variants if surfaces overlap.
- **Cache-tuning observability** — every future cache
  consumer (engram libraries, accumulator state, etc.)
  inherits the Telemetry surface for its own size/hit-rate
  monitoring.

PERSEVERARE.
