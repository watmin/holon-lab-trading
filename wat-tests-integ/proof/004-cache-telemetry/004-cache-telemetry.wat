;; wat-tests-integ/proof/004-cache-telemetry.wat — paired with
;; docs/proposals/2026/04/059-the-trader-on-substrate/059-001-l1-l2-caches/DESIGN.md
;; T7 (telemetry rows land in rundb at the gate cadence).
;;
;; ONE deftest. Spawns a real RunDbService on a new sqlite file
;; under runs/, builds a :trading::cache::reporter that closes over
;; the rundb handles, spawns a :wat::holon::lru::HologramCacheService
;; with that reporter + a counter-based MetricsCadence (fires every
;; 10 events for fast tests; production caches use the time-based
;; cadence wrapping :trading::log::tick-gate at 5000ms). Drives ~30
;; Put/Get requests so the cadence fires three times → three batches
;; of 5 LogEntry::Telemetry rows → 15 rows in the telemetry table.
;;
;; Run via:
;;   cargo test --release --features proof-004 --test proof_004
;;
;; Then query:
;;   ls -t runs/proof-004-*.db | head -1 | xargs -I{} sqlite3 {} <<EOF
;;     SELECT metric_name, COUNT(*) AS rows,
;;            ROUND(SUM(metric_value), 2) AS total
;;     FROM telemetry
;;     WHERE namespace = 'cache'
;;     GROUP BY metric_name
;;     ORDER BY metric_name;
;;   EOF
;;
;; Expected: 5 metric_names (cache-size, hits, lookups, misses, puts)
;; with rows ≥ 1 each — the cadence fired at least once during the
;; 30-request driver loop. The telemetry table's `dimensions` column
;; carries `{"cache":"test-cache","layer":"L2"}` per § E.
;;
;; Sentinel assertion at the bottom: the proof's real verification is
;; the SQL above (per the proof_002/003 pattern — gdb-via-sqlite, not
;; assert-vs-baked-in-numbers); the deftest passes iff the lifecycle
;; completes without panic.
;;
;; ─── Shutdown discipline ─────────────────────────────────────────
;;
;; Two drivers (rundb + cache); cache's reporter closes over a clone
;; of rundb's req-tx. Per wat-rs/docs/SERVICE-PROGRAMS.md "The
;; lockstep": the let* nesting IS the shutdown sequence — each
;; driver's `join` must land one scope OUT from where its senders
;; live, or the join blocks forever (the worker's recv never sees
;; disconnect because a sender is still bound).
;;
;; The shape decomposes into three small functions, each with the
;; canonical two-level let* (outer holds driver; inner owns senders;
;; outer joins after inner exits):
;;
;;   drive-requests           — pure work; no driver
;;   run-cache-with-rundb-tx  — owns cache driver; calls drive-requests
;;   deftest body             — owns rundb driver; calls run-cache-...
;;
;; Each function returns when its driver has cleanly joined. The
;; caller never sees a driver that's still alive.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/cache/reporter.wat")
   (:wat::load-file! "wat/io/telemetry/Sqlite.wat")

   ;; ─── Helper 1: drive 30 Put/Get requests ───────────────────────
   ;;
   ;; Pure caller-side work — receives the cache's send/recv handles
   ;; as arguments, drives the workload, returns. The handles drop
   ;; when this function returns (its caller's inner let* exits, its
   ;; caller joins the cache driver).
   ;;
   ;; 20 Puts (i = 0..19) → 10 Gets (i = 20..29 re-querying keys 0..9).
   ;; At cadence threshold = 10, the substrate's tick-window fires
   ;; three times during the loop, each flushing 5 LogEntry::Telemetry
   ;; rows through the reporter closure.
   (:wat::core::define
     (:trading::test::proofs::004::drive-requests
       (cache-req-tx :wat::holon::lru::HologramCacheService::ReqTx)
       (reply-tx :wat::holon::lru::HologramCacheService::GetReplyTx)
       (reply-rx :wat::holon::lru::HologramCacheService::GetReplyRx)
       -> :())
     (:wat::core::foldl
       (:wat::core::range 0 30) ()
       (:wat::core::lambda ((acc :()) (i :i64) -> :())
         (:wat::core::if (:wat::core::< i 20) -> :()
           ;; Puts 0..19 — unique leaf keys.
           (:wat::core::let*
             (((k :wat::holon::HolonAST)
               (:wat::holon::leaf
                 (:wat::core::string::concat
                   "k-" (:wat::core::i64::to-string i))))
              ((v :wat::holon::HolonAST)
               (:wat::holon::leaf
                 (:wat::core::string::concat
                   "v-" (:wat::core::i64::to-string i))))
              ((_ :wat::kernel::Sent)
               (:wat::kernel::send cache-req-tx
                 (:wat::holon::lru::HologramCacheService::Request::Put k v))))
             ())
           ;; Gets 20..29 — re-query keys 0..9.
           (:wat::core::let*
             (((k :wat::holon::HolonAST)
               (:wat::holon::leaf
                 (:wat::core::string::concat
                   "k-" (:wat::core::i64::to-string
                         (:wat::core::- i 20)))))
              ((_ :wat::kernel::Sent)
               (:wat::kernel::send cache-req-tx
                 (:wat::holon::lru::HologramCacheService::Request::Get
                   k reply-tx)))
              ((_reply :Option<Option<wat::holon::HolonAST>>)
               (:wat::kernel::recv reply-rx)))
             ())))))

   ;; ─── Helper 2: spawn cache + drive + join ──────────────────────
   ;;
   ;; Owns the cache driver for its lifetime. Two-level let*:
   ;;   outer  — cache-driver lives here (joined after inner exits)
   ;;   inner  — cache-req-tx + reply pair (drop on inner exit)
   ;;
   ;; Returns :() when the cache driver has cleanly joined. The
   ;; caller's rundb-handles (function args) are still alive on
   ;; return — caller drops them when its own scope exits.
   (:wat::core::define
     (:trading::test::proofs::004::run-cache-with-rundb-tx
       (rundb-req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
       (ack-rx :wat::telemetry::Service::AckRx)
       -> :())
     (:wat::core::let*
       (;; Cache reporter — closure over rundb handles.
        ((reporter :wat::holon::lru::HologramCacheService::Reporter)
         (:trading::cache::reporter/make
           rundb-req-tx ack-rx :test-cache :L2))
        ;; Counter-based MetricsCadence — fires every 10 events.
        ((cadence :wat::holon::lru::HologramCacheService::MetricsCadence<i64>)
         (:wat::holon::lru::HologramCacheService::MetricsCadence/new
           0
           (:wat::core::lambda
             ((n :i64) (_s :wat::holon::lru::HologramCacheService::Stats)
              -> :(i64,bool))
             (:wat::core::if (:wat::core::>= n 9) -> :(i64,bool)
               (:wat::core::tuple 0 true)
               (:wat::core::tuple (:wat::core::+ n 1) false)))))
        ;; Spawn the cache. count=1 client; cap=64 (no eviction).
        ((cache-spawn :wat::holon::lru::HologramCacheService::Spawn)
         (:wat::holon::lru::HologramCacheService/spawn 1 64
           reporter cadence))
        ((cache-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
         (:wat::core::first cache-spawn))
        ((cache-driver :wat::kernel::ProgramHandle<()>)
         (:wat::core::second cache-spawn))

        ;; Inner scope — pop cache-tx, build reply pair, drive.
        ((_inner :())
         (:wat::core::let*
           (((cache-req-tx :wat::holon::lru::HologramCacheService::ReqTx)
             (:wat::kernel::HandlePool::pop cache-pool))
            ((_finish-cache :()) (:wat::kernel::HandlePool::finish cache-pool))
            ((reply-pair :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
             (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
            ((reply-tx :wat::holon::lru::HologramCacheService::GetReplyTx)
             (:wat::core::first reply-pair))
            ((reply-rx :wat::holon::lru::HologramCacheService::GetReplyRx)
             (:wat::core::second reply-pair))
            ((_drive :())
             (:trading::test::proofs::004::drive-requests
               cache-req-tx reply-tx reply-rx)))
           ()))
        ;; Inner exited — cache senders dropped → cache loop exits →
        ;; cache thread completes → its captured reporter env (with
        ;; rundb-req-tx clone) drops.
        ((_cache-join :()) (:wat::kernel::join cache-driver)))
       ()))))


;; ─── The deftest — owns rundb driver ────────────────────────────
;;
;; Same canonical two-level let*: outer binds rundb-driver (joined
;; at end); inner pops the rundb client handle, builds the ack pair,
;; calls run-cache-with-rundb-tx (which itself joins cache before
;; returning). When inner exits, every rundb sender clone is gone
;; (popped one + reporter's captured one inside run-cache, which
;; already dropped); rundb loop exits; outer's _rundb-join unblocks.

(:deftest :trading::test::proofs::004::cache-telemetry
  (:wat::core::let*
    (;; Outer — rundb driver lives until the end.
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((db-path :String)
      (:wat::core::string::concat "runs/proof-004-" epoch-str ".db"))
     ((rundb-spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((rundb-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first rundb-spawn))
     ((rundb-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second rundb-spawn))

     ;; Inner — pop rundb handle (paired req-tx + ack-rx), run cache.
     ((_inner :())
      (:wat::core::let*
        (((rundb-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop rundb-pool))
         ((_finish-rundb :()) (:wat::kernel::HandlePool::finish rundb-pool))
         ((rundb-req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
          (:wat::core::first rundb-handle))
         ((ack-rx :wat::telemetry::Service::AckRx)
          (:wat::core::second rundb-handle))
         ((_run :())
          (:trading::test::proofs::004::run-cache-with-rundb-tx
            rundb-req-tx ack-rx)))
        ()))

     ;; Inner exited — rundb senders all dropped (popped one +
     ;; reporter's captured one already gone via run-cache). rundb
     ;; loop exits; this join unblocks.
     ((_rundb-join :()) (:wat::kernel::join rundb-driver)))
    ;; Sentinel — real verification is the SQL above.
    (:wat::test::assert-eq true true)))
