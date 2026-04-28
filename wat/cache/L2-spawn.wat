;; :trading::cache::L2 — paired Service spawner for cache-next + cache-terminal.
;;
;; The L2 cache layer is two parallel cache services — one for
;; (form-h → next-h) edges and one for (form-h → terminal-h) answers
;; (mirroring the L1 split). Each is a
;; `:wat::holon::lru::HologramCacheService` instance with its own
;; HandlePool and driver thread.
;;
;; This file ships the orchestrator: one `L2/spawn count cap` call
;; returns both spawns wrapped in a `:trading::cache::L2` struct.
;; Thinkers consume the L2 by popping handles from each pool to
;; build their per-thinker request channels.
;;
;; Lifecycle: caller's outer scope holds the L2 struct (so both
;; ProgramHandles survive); inner scope owns the pool tails and
;; per-thinker handles. When the inner scope drops the pools, both
;; drivers' recv channels disconnect, both loops exit cleanly,
;; outer joins both drivers.

(:wat::core::struct :trading::cache::L2
  (next-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
  (next-driver :wat::kernel::ProgramHandle<()>)
  (terminal-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
  (terminal-driver :wat::kernel::ProgramHandle<()>))

;; Spawn both cache services. `count` is per-cache (each cache gets
;; that many request channels in its HandlePool); `cap` is per-cache
;; LRU global bound. Reasonable defaults for the trader: count =
;; thinker-count, cap = 10000 (~100 entries per slot at the default
;; dim-count).
;;
;; The reporter + metrics-cadence pair is shared across both services
;; (next + terminal). Caller passes once; both services use them.
;; Each service runs its own cadence-gate independently — they don't
;; coordinate. Pass `:wat::holon::lru::HologramCacheService/null-reporter`
;; (fn-by-path) and
;; `(:wat::holon::lru::HologramCacheService/null-metrics-cadence)`
;; (nullary call returning the struct) for the no-reporting case.
(:wat::core::define
  (:trading::cache::L2/spawn<G>
    (count :i64)
    (cap :i64)
    (reporter :wat::holon::lru::HologramCacheService::Reporter)
    (metrics-cadence :wat::holon::lru::HologramCacheService::MetricsCadence<G>)
    -> :trading::cache::L2)
  (:wat::core::let*
    (((next-spawn :wat::holon::lru::HologramCacheService::Spawn)
      (:wat::holon::lru::HologramCacheService/spawn
        count cap reporter metrics-cadence))
     ((terminal-spawn :wat::holon::lru::HologramCacheService::Spawn)
      (:wat::holon::lru::HologramCacheService/spawn
        count cap reporter metrics-cadence)))
    (:trading::cache::L2/new
      (:wat::core::first next-spawn)
      (:wat::core::second next-spawn)
      (:wat::core::first terminal-spawn)
      (:wat::core::second terminal-spawn))))
