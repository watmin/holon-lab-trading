;; :trading::cache::L2 — paired Service spawner for cache-next + cache-terminal.
;;
;; The L2 cache layer is two parallel cache services — one for
;; (form-h → next-h) edges and one for (form-h → terminal-h) answers
;; (mirroring the L1 split). Each is a `:trading::cache::Service`
;; instance with its own HandlePool and driver thread.
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
  (next-pool :trading::cache::ReqTxPool)
  (next-driver :wat::kernel::ProgramHandle<()>)
  (terminal-pool :trading::cache::ReqTxPool)
  (terminal-driver :wat::kernel::ProgramHandle<()>))

;; Spawn both cache services. `count` is per-cache (each cache gets
;; that many request channels in its HandlePool); `cap` is per-cache
;; LRU global bound. Reasonable defaults for the trader: count =
;; thinker-count, cap = 10000 (~100 entries per slot at the default
;; dim-count).
(:wat::core::define
  (:trading::cache::L2/spawn
    (count :i64)
    (cap :i64)
    -> :trading::cache::L2)
  (:wat::core::let*
    (((next-spawn :trading::cache::Spawn)
      (:trading::cache::Service/spawn count cap))
     ((terminal-spawn :trading::cache::Spawn)
      (:trading::cache::Service/spawn count cap)))
    (:trading::cache::L2/new
      (:wat::core::first next-spawn)
      (:wat::core::second next-spawn)
      (:wat::core::first terminal-spawn)
      (:wat::core::second terminal-spawn))))
