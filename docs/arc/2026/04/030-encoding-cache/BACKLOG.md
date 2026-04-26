# lab arc 030 — Encoding cache + LogEntry::Telemetry — BACKLOG

**Shape:** three slices. Slice 1 lands the `LogEntry::Telemetry`
variant + `emit-metric` constructor (NO rate gate per DESIGN
Q7; the program rhythm IS the rate gate for event-driven
callers). Slice 2 builds the encoding cache (LRU on
`HolonAST → Vector`, plus pre-encoded corners) and wires cache
stats through Telemetry — and is where the rate gate question
gets answered (cache has no natural rhythm). Slice 3 ships
INSCRIPTION + flips a follow-up "perf" proof from BLOCKED to
ready. Total estimate: ~5 hours.

**Slice 1 priority bump (2026-04-26):** the proofs lane is
opening `docs/experiments/2026/04/008-treasury-program/` next,
and Treasury must emit telemetry from day 1 ("the db is our
gdb" — telemetry is critical-path observability, not optional
polish). Slice 1 is the unblock; slice 2 + cache work follows
once Treasury experiment closes.

This is the third proofs-lane → infra-lane handoff. The proofs
lane drafts (this doc); the infra session implements; the proofs
lane writes the consuming proof once the seam exists.

Builder direction (2026-04-25, after proof 003 baseline showed
~10-min wall-clock for 200k candles):

> "we had incredible telemetry and metrics rigged up into the
> logging db before - gave us great insight - the cost /is/
> the vector ops - the encoding cache is necessary"

> "we don't need a cache service until we have many concurrent
> encoders - right now we're single threaded so we can just use
> a local cache"

> "i've we can toss like 30G at this"

> "telemetry — i say this is priority - we know we don't know -
> the metrics were massively helpful - the db is our gdb.. our
> pry... into the system..."

---

## Slice 1 — `LogEntry::Telemetry` variant + `emit-metric`

**Status: shipped 2026-04-25.** Treasury (experiment 008) unblocked.

Adds the second variant on the arc 029 sum. The LogEntry,
schema, dispatcher, shim wrapper, and a `wat/io/log/telemetry.wat`
file with `emit-metric` (the constructor — pure function from
fields to a `LogEntry::Telemetry` value). **No `make-rate-gate`
in this slice** — descoped per DESIGN Q7 because event-driven
callers (Treasury per Tick, future broker per candle) batch
their own metrics and flush per event. The cache (slice 2) is
the only consumer without a natural rhythm; the rate-gate
question lives there. Two smoke tests for the variant + the
emit-metric helper.

### Step 1a — extend the LogEntry sum

`wat/io/log/LogEntry.wat` — add the Telemetry arm. Variant
shape mirrors the archive's
`archived/pre-wat-native/src/types/log_entry.rs::LogEntry::Telemetry`:

```scheme
(:wat::core::enum :trading::log::LogEntry
  (PaperResolved
    ...)
  (Telemetry                                  ; ← new
    (namespace :String)
    (id :String)
    (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String)
    (metric-value :f64)
    (metric-unit :String)))
```

`namespace` / `id` / `dimensions` are CloudWatch-style
identifiers; `dimensions` is JSON-encoded for cheap key-value
flexibility (avoids needing a `Map<String, String>` in the
sum).

### Step 1b — schema constant + registry

`wat/io/log/schema.wat`:

```scheme
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
    (:trading::log::schema-telemetry)))         ; ← added
```

No PRIMARY KEY on telemetry (every row is a unique
metric-emit observation; SQLite implicit rowid suffices).

### Step 1c — shim adds `log_telemetry`

`src/shims.rs` — new method on `WatRunDb`:

```rust
#[allow(clippy::too_many_arguments)]
pub fn log_telemetry(
    &mut self,
    namespace: String,
    id: String,
    dimensions: String,
    timestamp_ns: i64,
    metric_name: String,
    metric_value: f64,
    metric_unit: String,
) {
    self.conn.execute(
        "INSERT INTO telemetry \
         (namespace, id, dimensions, timestamp_ns, \
          metric_name, metric_value, metric_unit) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            namespace, id, dimensions, timestamp_ns,
            metric_name, metric_value, metric_unit,
        ],
    ).unwrap_or_else(|e| {
        panic!(":rust::trading::RunDb::log-telemetry: insert failed: {e}")
    });
}
```

`wat/io/RunDb.wat` — mirror:

```scheme
(:wat::core::define
  (:trading::rundb::log-telemetry
    (db :trading::rundb::RunDb)
    (namespace :String) (id :String) (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String) (metric-value :f64) (metric-unit :String)
    -> :())
  (:rust::trading::RunDb::log-telemetry
    db namespace id dimensions
    timestamp-ns metric-name metric-value metric-unit))
```

### Step 1d — `Service/dispatch` gains the Telemetry arm

`wat/io/RunDbService.wat`:

```scheme
(:wat::core::define
  (:trading::rundb::Service/dispatch
    (db :trading::rundb::RunDb)
    (entry :trading::log::LogEntry)
    -> :())
  (:wat::core::match entry -> :()
    ((:trading::log::LogEntry::PaperResolved
        run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss)
      (:trading::rundb::log-paper-resolved
        db run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss))
    ((:trading::log::LogEntry::Telemetry                    ; ← new
        namespace id dimensions timestamp-ns
        metric-name metric-value metric-unit)
      (:trading::rundb::log-telemetry
        db namespace id dimensions timestamp-ns
        metric-name metric-value metric-unit))))
```

### Step 1e — `wat/io/log/telemetry.wat` — `emit-metric` constructor

```scheme
;; wat/io/log/telemetry.wat — convenience constructor for
;; Telemetry LogEntries. Mirrors archived/pre-wat-native/src/
;; programs/telemetry.rs::emit_metric.

(:wat::load-file! "LogEntry.wat")

;; Pure constructor: build a Telemetry LogEntry from its fields.
;; Caller accumulates a Vec<LogEntry> per event (per-Tick for
;; Treasury, per-candle for future broker/observer programs)
;; and flushes via Service/batch-log per event. The "rate" is
;; implicit in the event cadence — no separate gate primitive
;; needed in this slice (see DESIGN Q7).
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

(`make-rate-gate` is NOT in this slice. It comes back when
slice 2's encoding cache needs throttled emission — that's
where the substrate-mutable-cell question gets answered.)

### Step 1f — Wire new wat file into `src/shims.rs::wat_sources()`

```rust
pub fn wat_sources() -> &'static [WatSource] {
    static FILES: &[WatSource] = &[
        ...,
        WatSource { path: "io/log/telemetry.wat",                   // ← new
                    source: include_str!("../wat/io/log/telemetry.wat") },
        ...,
    ];
    FILES
}
```

### Step 1g — Smoke tests

`wat-tests/io/log/telemetry.wat` — two deftests:

1. **Variant constructor + dispatch round-trip.** Build one
   `LogEntry::Telemetry`, batch-log via Service to a temp DB,
   query back via sqlite3 CLI. Verify namespace / metric_name
   / metric_value match.
2. **emit-metric helper.** Construct via `:trading::log::emit-metric`,
   compare to direct `:trading::log::LogEntry::Telemetry`
   constructor with same fields — must produce equal entries.

### Verification

```bash
cargo test --release --test test 2>&1 | grep -E "telemetry|FAILED"
# Lab wat tests count climbs by 2 (new telemetry smoke tests).
```

**LOC budget:**
- `wat/io/log/LogEntry.wat`: +1 variant arm. ~15 LOC delta.
- `wat/io/log/schema.wat`: +1 schema constant + registry update. ~20 LOC delta.
- `wat/io/log/telemetry.wat`: new file (constructor only — no rate gate). ~30 LOC.
- `src/shims.rs`: +1 method (~15 LOC) + 1 line in `wat_sources()`.
- `wat/io/RunDb.wat`: +1 wrapper. ~15 LOC.
- `wat/io/RunDbService.wat`: +1 dispatcher arm. ~10 LOC delta.
- `wat-tests/io/log/telemetry.wat`: ~80 LOC for 2 deftests.

**Estimated cost:** ~185 LOC + 2 tests. **~1.5 hours.**

---

## Slice 2 — Encoding cache + corners pre-encode + cache emits

**Status: not started.** Depends on slice 1.

Adds `:wat::lru::LocalCache<HolonAST, Vector>`-backed encode
caching to `cosine-vs-corners-predictor`. Pre-encodes the four
corner ASTs at predictor construction. Cache emits hit/miss/size
metrics via `LogEntry::Telemetry` on a rate-gated cadence.

### Step 2a — substrate audit (Q8 from DESIGN)

Before writing the cache: confirm whether `:wat::holon::cosine`
takes ASTs (and encodes internally) OR vectors (already
encoded). If the former, the cache value type is `Vector` but
the consuming `cosine` call still re-encodes — defeating the
cache. Two possible paths:

(a) **`:wat::holon::cosine-vec va vb` substrate addition** — a
    new arm/dispatch on the cosine primitive accepting two
    already-encoded vectors. ~30 LOC of Rust + check arm. Same
    arc carry-along (per arc 026's pattern of substrate uplifts
    riding alongside lab work).

(b) **Synthetic-AST wrapper** — wrap the cached `Vector` in an
    AST node that the existing cosine recognizes as
    "already-encoded, skip the encode step." Uglier; preserves
    the substrate. ~10 LOC of wat.

Implementer picks; INSCRIPTION captures. Path (a) is preferred
unless the substrate has objection.

### Step 2b — `wat/sim/encoding-cache.wat` — the cache wrapper

```scheme
;; wat/sim/encoding-cache.wat — LRU on HolonAST → Vector for
;; the predictor's encode-and-cosine hot path.

(:wat::load-file! "../io/log/telemetry.wat")
(:wat::load-file! "../io/RunDbService.wat")

(:wat::core::typealias :trading::sim::EncodeCache
  :wat::lru::LocalCache<wat::holon::HolonAST,wat::holon::Vector>)

;; Construct a fresh cache. capacity = max distinct ASTs to
;; retain before LRU eviction. Default 100k slots × 32KB
;; (4096-dim f64 vector) = ~3.2 GB; well within 30 GB budget.
(:wat::core::define
  (:trading::sim::encode-cache-new
    (capacity :i64)
    -> :trading::sim::EncodeCache)
  (:wat::lru::LocalCache::new capacity))

;; Cached encode. Lookup, miss → encode + put + return; hit →
;; return cached vector. The internal counter state lives on
;; the cache (LRU's internal stats) plus a thread-owned
;; counter for hit/miss accumulation between emits.
(:wat::core::define
  (:trading::sim::encode-cached
    (cache :trading::sim::EncodeCache)
    (ast :wat::holon::HolonAST)
    -> :wat::holon::Vector)
  (:wat::core::match (:wat::lru::LocalCache::get cache ast) -> :wat::holon::Vector
    ((Some v) v)
    (:None
      (:wat::core::let*
        (((v :wat::holon::Vector) (:wat::holon::encode ast))
         ((_ :()) (:wat::lru::LocalCache::put cache ast v)))
        v))))

;; Telemetry emitter. Reads the cache's stats, builds
;; LogEntry::Telemetry rows for hits / misses / size /
;; capacity / hit-rate / evictions, returns the Vec. Caller
;; batch-logs via Service.
(:wat::core::define
  (:trading::sim::encode-cache-stats
    (cache :trading::sim::EncodeCache)
    (run-name :String)
    (timestamp-ns :i64)
    -> :Vec<trading::log::LogEntry>)
  ...)
```

### Step 2c — `cosine-vs-corners-predictor-cached` in `wat/sim/v1.wat`

Replace (or sibling-add — keeping the original cache-less
form for comparison) the predictor:

```scheme
(:wat::core::define
  (:trading::sim::cosine-vs-corners-predictor-cached
    (cache :trading::sim::EncodeCache)
    -> :trading::sim::Predictor)
  (:wat::core::let*
    ;; Pre-encode corners ONCE — they're constants. Their
    ;; vectors are captured in the closure below; no per-call
    ;; cosine touches the cache for corners.
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
          ;; Cache-encode the surface ONCE per predictor call —
          ;; not 4× as the uncached predictor does.
          (((v-surface :wat::holon::Vector)
            (:trading::sim::encode-cached cache surface))
           ;; cosine on already-encoded vectors (per Q8 substrate
           ;; choice — cosine-vec OR synthetic-AST wrapper).
           ((c-gu :f64) (:wat::holon::cosine-vec v-surface v-gu))
           ((c-gd :f64) (:wat::holon::cosine-vec v-surface v-gd))
           ((c-vu :f64) (:wat::holon::cosine-vec v-surface v-vu))
           ((c-vd :f64) (:wat::holon::cosine-vec v-surface v-vd))
           ;; ... argmax → Action, same shape as uncached version
           ...)
          ...)))))
```

### Step 2d — Smoke tests

`wat-tests/sim/encoding-cache.wat` — three deftests:

1. **Cache hit on repeated encode.** Encode AST x; cache should
   miss, encode happens. Encode AST x again; cache should hit,
   no encode. Verify via Telemetry emit (hit_count == 1, miss_count == 1).
2. **LRU eviction at capacity.** Capacity 2; encode three
   distinct ASTs; the first should be evicted by the third.
   Verify by re-encoding the first → miss again.
3. **Predictor-cached produces same Action as uncached.**
   Build a predictor with cache + a predictor without; feed
   the same surface AST; assert both return the same Action.
   Pure correctness check — caching must not change behavior.

### Verification

```bash
cargo test --release --test test 2>&1 | grep -E "encoding-cache|FAILED"
# Lab wat tests count climbs by 3.
```

**LOC budget:**
- Substrate Q8 path (a): `wat-rs/src/runtime.rs` + `check.rs` for `cosine-vec`. ~50 LOC.
  (Or path (b): synthetic-AST wrapper in wat. ~30 LOC.)
- `wat/sim/encoding-cache.wat`: typealias + cache wrappers + telemetry emitter + doc. ~150 LOC.
- `wat/sim/v1.wat`: new predictor sibling (~50 LOC delta — keep both forms for proof comparisons).
- `src/shims.rs::wat_sources()`: 1 line.
- `wat-tests/sim/encoding-cache.wat`: ~120 LOC for 3 deftests.

**Estimated cost:** ~370-400 LOC + 3 tests + possible substrate carry-along. **~3.5 hours.**

---

## Slice 3 — INSCRIPTION + flip downstream proof

**Status: not started.** Depends on slices 1 and 2.

`docs/arc/2026/04/030-encoding-cache/INSCRIPTION.md` — same
shape as arc 029's INSCRIPTION:

- "What shipped" table per slice.
- Lab wat test count delta (current 334 → expected 340).
- Architecture notes / divergences:
  - Substrate path chosen for Q8 (cosine-vec vs synthetic-AST).
  - Whether a substrate carry-along arc was needed for `cosine-vec`.
  - Cache-key hashability: did `HolonAST` work as `LocalCache` key
    out of the box, or did it need a hash-derive?
  - Rate gate implementation: which mutable-cell shape was used.
- "What this unblocks" — the proof-perf-001 follow-up that
  re-runs proof 003 with caching enabled and quantifies the
  speedup.
- "What this arc deliberately did NOT add" — mirror DESIGN's
  out-of-scope (CacheService variant, persistence, multi-DB
  per service, key normalization, adaptive emit cadence).
- "The thread" — date timeline.

`docs/proofs/2026/04/004-perf-encoding-cache/PROOF.md` (or
similar — let the proofs lane name it; the proofs lane
writes the doc + pair file post-arc-shipped) — flip from
BLOCKED to ready.

**Estimated cost:** ~30 minutes. Doc only.

---

## Verification end-to-end

After all three slices land:

```bash
cd /home/watmin/work/holon/holon-lab-trading

# 1. Build clean.
cargo build --release

# 2. All lab wat-tests pass.
cargo test --release --test test 2>&1 | grep -E "test result|FAILED"
# Expected: 340 wat tests, 0 failed (was 334 pre-arc-030).

# 3. Proof 003 still produces the same numbers under the
#    NEW cosine-vs-corners-predictor-cached (when the
#    proof's pair file is updated to use it; that update is
#    part of the perf proof, not this arc).
cargo test --release --features proof-003 --test proof_003

# 4. The new perf proof (perf-001 or similar) produces a
#    measurable speedup vs proof 003 baseline (586s) AND
#    captures cache-stats Telemetry rows in its DB.
```

---

## Total estimate

- Slice 1: 1.5 hours (LogEntry::Telemetry variant + emit-metric + 2 smoke tests; rate gate descoped per Q7)
- Slice 2: 3.5 hours (cache + corners pre-encode + smoke tests + possible substrate carry-along; rate-gate question lands here when cache emits)
- Slice 3: 30 minutes (INSCRIPTION + status flips)

**~5.5 hours** total. Slice 1 is the priority — proofs lane
is opening experiment 008 (Treasury) next and needs Telemetry
emission from day 1.

---

## Out of scope

Mirror of DESIGN's out-of-scope; reproduced here as the honest
scope ledger:

- **CacheService variant.** Single-thread `LocalCache` only.
  Multi-broker future arc adds the service variant when
  concurrency surfaces.
- **Cross-process / persistent cache.** In-memory only.
- **More LogEntry variants beyond Telemetry.** `BrokerSnapshot`,
  `Diagnostic`, `ObserverSnapshot`, etc. land per consumer
  proof.
- **Auto-instrumentation of other call sites.** Telemetry
  emission is opt-in per call site; no tracing layer.
- **Cache-key normalization.** Two ASTs that are semantically
  equivalent but structurally different miss the cache. If the
  encoder normalizes pre-hash, fine; if not, future arc.
- **Variable-rate emit windows.** Fixed-interval gate for v1.
  Future arc when bursty workloads need adaptive cadence.
- **Cache eviction policy beyond LRU.** Future arc when LRU
  pathologies surface (ARC, LFU, etc.).
- **Auto-sizing the cache.** v1 takes capacity at construction;
  no auto-grow / auto-shrink. Future arc when measurement
  shows manual tuning is wrong.

---

## Risks

**Substrate gap on `cosine-vec`.** Per Q8: if today's
`:wat::holon::cosine` only accepts ASTs and there's no
vector-vs-vector form, slice 2 needs either a substrate-side
addition (path a, cleaner) or a synthetic-AST wrapper (path b,
uglier but no substrate change). The risk is that path (a)
turns out to need more than a small carry-along — at which
point pause slice 2, open a substrate arc, finish arc 030 once
that lands. INSCRIPTION captures the path taken.

**`HolonAST` hashability for `LocalCache` key.** If the
substrate's HolonAST doesn't derive Hash + Eq, `LocalCache`
won't accept it as K. Probably already supported (per Phase 4
work on `Atom<HolonAST>`), but verify before slice 2 deep-end.

**Rate-gate state holder.** The archived rate-gate used a
`Mutex<Instant>`. Wat avoids Mutex by design; slice 1's gate
needs a thread-owned mutable cell OR a counter-based form
(open every N calls instead of every T ms). Implementer's
call; if neither shape is clean, slice 1 ships with a counter
gate and a doc note that time-based gating awaits a substrate
mutable-cell primitive.

**Cache-vs-thrash regime.** If the cache capacity is too small
relative to the working set, hit rate stays low and the cache
adds overhead (lookup + LRU bookkeeping) without benefit.
Telemetry will tell us; slice 2's smoke tests aren't long
enough to surface this. The follow-up perf proof
(post-slice-3) is what catches it. Mitigation: default capacity
high (100k); the user said "30G" — err on the high side.

**Telemetry write rate degrading the test workload.** A 1s
emit interval × 200k candles ÷ ~30s/window ≈ 600 telemetry
rows total — should be a rounding error vs the 694 paper rows.
But verify via `EXPLAIN QUERY PLAN` if the telemetry table
ever needs an index.

**Caching invariance.** A correctness regression in the cached
predictor would surface as "proof 003 numbers shifted." Slice
2's smoke test #3 is the canary, but it only tests one surface
AST. The full proof 003 re-run (post-slice-3) is the deep
correctness check — same numbers as the uncached baseline
(modulo any encoder non-determinism, which there shouldn't
be).

---

## What this unblocks

- **proof-perf-001** (proposed follow-up) — re-runs proof 003
  with cache enabled, captures cache hit-rate + speedup +
  Telemetry rows. The first quantified cache-perf claim.
- **Proof 004** — full 6-year stream (652k candles). Without
  cache: ~108 min wall-clock at proof 003's rate. With cache:
  the speedup determines whether this is a single-test-session
  proof or an overnight one.
- **Proof 005+** — multi-thinker / multi-predictor comparisons.
  Caching gain compounds across thinker variants if surfaces
  overlap.
- **Future Telemetry consumers** — every later cache /
  encoder / engram library can emit hit-rate / size / latency
  metrics on the same Telemetry surface. The CloudWatch-style
  shape is reusable.

PERSEVERARE.
