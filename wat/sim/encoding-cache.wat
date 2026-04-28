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
;; of intrinsically-mutable storage. The rate gate at
;; wat/io/log/rate-gate.wat is the foil — its state is one Instant,
;; small enough to thread values-up cheanly.

(:wat::load-file! "../io/log/LogEntry.wat")
(:wat::load-file! "../io/log/telemetry.wat")


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


;; Snapshot accessor — pure read of the stats holder. Builds a
;; Vec<LogEntry::Telemetry> ready for `Service/batch-log`. The
;; caller picks WHEN to call this (per-window, per-Tick, every
;; rate-gate fire — whatever their natural batch boundary is).
;;
;; Per arc 030 DESIGN Q7: the cache imposes no rhythm; the
;; consumer's natural cadence is the rate gate. For the encoding
;; cache that means callers thread `tick-gate` state through their
;; loop and call this snapshot when the gate fires — see
;; `wat/io/log/rate-gate.wat`.
;;
;; Five rows per snapshot:
;;   hits / misses / ops / hit-rate / size
;; (capacity is constant per cache; emit once at construction if
;; useful — not on every snapshot.)
(:wat::core::define
  (:trading::sim::encode-cache-stats
    (cache :trading::sim::EncodeCache)
    (stats :trading::sim::EncodeStats)
    (run-name :String)
    (timestamp-ns :i64)
    -> :Vec<trading::log::LogEntry>)
  (:wat::core::let*
    (((hits :i64)   (:trading::sim::encode-stats/get stats "hits"))
     ((misses :i64) (:trading::sim::encode-stats/get stats "misses"))
     ((ops :i64)    (:trading::sim::encode-stats/get stats "ops"))
     ((size :i64)   (:wat::lru::LocalCache::len cache))
     ((hit-rate :f64)
      (:wat::core::if (:wat::core::> ops 0) -> :f64
        (:wat::core::/ (:wat::core::i64::to-f64 hits)
                       (:wat::core::i64::to-f64 ops))
        0.0))
     ;; Build a JSON-encoded dimensions map: {"run":"<run-name>"}
     ((dims :String)
      (:wat::core::string::concat
        "{\"run\":\""
        (:wat::core::string::concat run-name "\"}"))))
    (:wat::core::vec :trading::log::LogEntry
      (:trading::log::emit-metric
        "encode-cache" "predictor" dims timestamp-ns
        "hits"     (:wat::core::i64::to-f64 hits)     "Count")
      (:trading::log::emit-metric
        "encode-cache" "predictor" dims timestamp-ns
        "misses"   (:wat::core::i64::to-f64 misses)   "Count")
      (:trading::log::emit-metric
        "encode-cache" "predictor" dims timestamp-ns
        "ops"      (:wat::core::i64::to-f64 ops)      "Count")
      (:trading::log::emit-metric
        "encode-cache" "predictor" dims timestamp-ns
        "hit-rate" hit-rate                            "Percent")
      (:trading::log::emit-metric
        "encode-cache" "predictor" dims timestamp-ns
        "size"     (:wat::core::i64::to-f64 size)     "Count"))))
