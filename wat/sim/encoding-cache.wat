;; :trading::sim::EncodeCache — LRU on HolonAST → Vector for the
;; predictor's encode-and-cosine hot path.
;;
;; Lab arc 030 slice 2 (2026-04-25). The proof 003 baseline ran
;; ~10 minutes for 200k candles; the user's read of where the time
;; goes is "vector ops" (the four cosine calls in
;; cosine-vs-corners-predictor each encode the same surface AST).
;; This cache memoizes the AST → Vector step so each unique surface
;; encodes exactly once across the run; subsequent cosines pull
;; from cache and compose vector-vs-vector through the existing
;; (polymorphic since arc 052) :wat::holon::cosine.
;;
;; ── Two caches, one bundle ──
;;
;; The encode mapping (HolonAST → Vector) is the obvious cache.
;; Stats (hits, misses, ops) are also state that persists across
;; calls; rather than threading them values-up through every
;; encode-cached invocation (which would force the Predictor's
;; signature to grow), they live in a parallel
;; LocalCache<String, i64>. The pair is passed together into
;; encode-cached and into encode-cache-stats — caller bundles them
;; as they see fit (the cosine-vs-corners-predictor-cached lambda
;; captures both in its closure).
;;
;; Both LocalCaches use ThreadOwnedCell internally — the substrate's
;; zero-mutex shape for thread-owned mutable state. Not a Mutex.
;;
;; ── Why not values-up for the cache too? ──
;;
;; The LRU is by design in-place mutation (eviction reorders the
;; ring; you can't usefully thread a 100k-entry LRU through a
;; recursive loop without copying every iteration). Substrate-
;; provided thread-owned cells are the right tool for this kind
;; of intrinsically-mutable storage.
;;
;; ── Slice-6 telemetry shape (arc 091) ──
;;
;; The snapshot is an OBSERVATION of cache state at a moment —
;; cumulative cache aggregates (hits/misses/ops) and current size.
;; Per the metric-vs-log discipline arc 091 surfaced: snapshots are
;; Log-shaped, not Metric-shaped. (Metric rows come from per-event
;; counter bumps and per-call duration samples — the shape that
;; aggregates SUM/AVG/p99 across time. Cache stats are already
;; cumulative aggregates the LocalCache maintains; observing them
;; is recording a state, not adding a new sample.) `encode-cache-
;; stats` returns ONE Event::Log carrying the 5 stats as Tagged data.

;; ─── Stat-snapshot struct — Log payload shape ───────────────────
;;
;; Tagged at write so SQL-side parsers read back the typed fields
;; (hits/misses/ops/hit-rate/size) without ad-hoc EDN traversal.
(:wat::core::struct :trading::sim::EncodeCacheSnapshot
  (hits     :i64)
  (misses   :i64)
  (ops      :i64)
  (hit-rate :f64)
  (size     :i64))


;; The encode cache itself.
(:wat::core::typealias :trading::sim::EncodeCache
  :wat::lru::LocalCache<wat::holon::HolonAST,wat::holon::Vector>)

;; Counter holder. Three keys today: "hits", "misses", "ops"
;; (where ops = hits + misses). Capacity 16 — tiny; only stores
;; the three counters + a few cents of headroom.
(:wat::core::typealias :trading::sim::EncodeStats
  :wat::lru::LocalCache<String,i64>)


;; Construct a fresh encode cache. Capacity is the max distinct
;; ASTs to retain before LRU eviction. Default 100k slots × 32 KB
;; (4096-dim f64 vector) = ~3.2 GB; well within the user's 30 GB
;; budget headline.
(:wat::core::define
  (:trading::sim::encode-cache-new
    (capacity :i64)
    -> :trading::sim::EncodeCache)
  (:wat::lru::LocalCache::new capacity))


;; Construct fresh stats. All counters start at zero.
(:wat::core::define
  (:trading::sim::encode-stats-new -> :trading::sim::EncodeStats)
  (:wat::core::let*
    (((s :trading::sim::EncodeStats) (:wat::lru::LocalCache::new 16))
     ((_ :Option<(String,i64)>) (:wat::lru::LocalCache::put s "hits" 0))
     ((_ :Option<(String,i64)>) (:wat::lru::LocalCache::put s "misses" 0))
     ((_ :Option<(String,i64)>) (:wat::lru::LocalCache::put s "ops" 0)))
    s))


;; Internal — increment a counter slot by 1 (creates if absent).
(:wat::core::define
  (:trading::sim::encode-stats/incr
    (stats :trading::sim::EncodeStats)
    (key :String)
    -> :())
  (:wat::core::let*
    (((current :i64)
      (:wat::core::match (:wat::lru::LocalCache::get stats key) -> :i64
        ((Some n) n)
        (:None 0))))
    (:wat::core::let*
      (((_ :Option<(String,i64)>)
        (:wat::lru::LocalCache::put stats key (:wat::core::+ current 1))))
      ())))


;; Read a counter slot (0 if absent).
(:wat::core::define
  (:trading::sim::encode-stats/get
    (stats :trading::sim::EncodeStats)
    (key :String)
    -> :i64)
  (:wat::core::match (:wat::lru::LocalCache::get stats key) -> :i64
    ((Some n) n)
    (:None 0)))


;; Cached encode. Lookup, miss → encode + put + return; hit →
;; return cached vector. Updates `hits`/`misses`/`ops` counters
;; in `stats`.
(:wat::core::define
  (:trading::sim::encode-cached
    (cache :trading::sim::EncodeCache)
    (stats :trading::sim::EncodeStats)
    (ast :wat::holon::HolonAST)
    -> :wat::holon::Vector)
  (:wat::core::let*
    (((_ops :()) (:trading::sim::encode-stats/incr stats "ops")))
    (:wat::core::match (:wat::lru::LocalCache::get cache ast) -> :wat::holon::Vector
      ((Some v)
        (:wat::core::let*
          (((_ :()) (:trading::sim::encode-stats/incr stats "hits")))
          v))
      (:None
        (:wat::core::let*
          (((_ :()) (:trading::sim::encode-stats/incr stats "misses"))
           ((v :wat::holon::Vector) (:wat::holon::encode ast))
           ((_ :Option<(wat::holon::HolonAST,wat::holon::Vector)>)
            (:wat::lru::LocalCache::put cache ast v)))
          v)))))


;; Snapshot — returns ONE Event::Log carrying the 5 stats fields as
;; Tagged data. Caller picks WHEN to call (per-window, per-Tick,
;; whatever their natural cadence is) and ships the result via
;; `Service/batch-log` as a single-element batch.
;;
;; Tags carry run identity (so SQL queries can filter per-run).
;; namespace = `:trading.encode-cache`; caller = `:predictor` (the
;; site that owns the cache); level = `:info`.
(:wat::core::define
  (:trading::sim::encode-cache-stats
    (cache    :trading::sim::EncodeCache)
    (stats    :trading::sim::EncodeStats)
    (run-name :String)
    (time-ns  :i64)
    -> :wat::telemetry::Event)
  (:wat::core::let*
    (((hits   :i64) (:trading::sim::encode-stats/get stats "hits"))
     ((misses :i64) (:trading::sim::encode-stats/get stats "misses"))
     ((ops    :i64) (:trading::sim::encode-stats/get stats "ops"))
     ((size   :i64) (:wat::lru::LocalCache::len cache))
     ((hit-rate :f64)
      (:wat::core::if (:wat::core::> ops 0) -> :f64
        (:wat::core::/ (:wat::core::i64::to-f64 hits)
                       (:wat::core::i64::to-f64 ops))
        0.0))
     ((snap :trading::sim::EncodeCacheSnapshot)
      (:trading::sim::EncodeCacheSnapshot/new
        hits misses ops hit-rate size))
     ((data-ast :wat::holon::HolonAST) (:wat::holon::Atom snap))
     ((uuid :String) (:wat::telemetry::uuid::v4))
     ((ns-ast    :wat::holon::HolonAST) (:wat::holon::Atom :trading.encode-cache))
     ((cal-ast   :wat::holon::HolonAST) (:wat::holon::Atom :predictor))
     ((level-ast :wat::holon::HolonAST) (:wat::holon::Atom :info))
     ((tags :wat::telemetry::Tags)
      (:wat::core::assoc
        (:wat::core::HashMap :wat::telemetry::Tag)
        (:wat::holon::Atom :run) (:wat::holon::Atom run-name))))
    (:wat::telemetry::Event::Log
      time-ns
      (:wat::edn::NoTag/new ns-ast)
      (:wat::edn::NoTag/new cal-ast)
      (:wat::edn::NoTag/new level-ast)
      uuid
      tags
      (:wat::edn::Tagged/new data-ast))))
