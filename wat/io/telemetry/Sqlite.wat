;; :trading::telemetry::Sqlite — lab thin wrapper over substrate's
;; :wat::std::telemetry::Service<E,G>.
;;
;; Lab proposal 059-002 sub-slice B. Replaces :trading::rundb::Service
;; from arc 029. The substrate ships the queue + driver + cadence
;; machinery generic over E; this wrapper wires the lab's
;; LogEntry-specific dispatcher + stats-translator + clock.
;;
;; Per CIRCUIT.md: RunDb is thread-owned. The worker entry function
;; opens the Db inside its own thread, then calls substrate's
;; Service/loop with closures-over-the-local-Db. :user::main never
;; sees the Db — it sees the (HandlePool<ReqTx>, ProgramHandle) pair
;; this returns and wires that into the rest of the program.
;;
;; The wrapper has TWO functions, each with one outer let*:
;;
;;   loop-entry — runs in the spawned worker thread. Opens Db,
;;     installs schemas, builds closures, calls substrate
;;     Service/loop. Never returns until rxs disconnect.
;;
;;   Sqlite/spawn — runs in the caller's thread. Builds the request
;;     channel pairs, wraps senders in a HandlePool, spawns
;;     loop-entry on a new thread, returns (pool, driver).

(:wat::load-file! "../RunDb.wat")
(:wat::load-file! "../log/LogEntry.wat")
(:wat::load-file! "../log/schema.wat")
(:wat::load-file! "maker.wat")
(:wat::load-file! "dispatch.wat")
(:wat::load-file! "translate-stats.wat")


;; ─── Worker entry — opens Db, builds closures, runs Service/loop

;; Worker thread's body. Captures all local thread-owned state
;; here; the substrate's generic Service/loop never sees Db.
(:wat::core::define
  (:trading::telemetry::Sqlite/loop-entry<G>
    (path :String)
    (rxs :Vec<wat::std::telemetry::Service::ReqRx<trading::log::LogEntry>>)
    (cadence :wat::std::telemetry::Service::MetricsCadence<G>)
    -> :())
  (:wat::core::let*
    (((db :trading::rundb::RunDb) (:trading::rundb::open path))
     ;; Install every schema. Idempotent CREATE TABLE IF NOT EXISTS.
     ((_install :())
      (:wat::core::foldl (:trading::log::all-schemas) ()
        (:wat::core::lambda ((acc :()) (ddl :String) -> :())
          (:trading::rundb::execute-ddl db ddl))))
     ;; Maker — closure over wall-clock; built per-worker so timestamps
     ;; come from this thread's `now`. Dummy unit arg per the substrate's
     ;; nullary-fn-type quirk (:fn(()) -> Instant).
     ((maker :trading::telemetry::EntryMaker)
      (:trading::telemetry::maker/make
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))))
     ;; Dispatcher closure — captures the worker-local Db; routes
     ;; each LogEntry through the lab's per-variant dispatcher fn.
     ((dispatcher :fn(trading::log::LogEntry)->())
      (:wat::core::lambda ((entry :trading::log::LogEntry) -> :())
        (:trading::telemetry::dispatch db entry)))
     ;; Stats-translator closure — captures the worker-local maker;
     ;; encodes substrate Stats as three rundb-self Telemetry rows.
     ((stats-translator :fn(wat::std::telemetry::Service::Stats)->Vec<trading::log::LogEntry>)
      (:wat::core::lambda
        ((stats :wat::std::telemetry::Service::Stats)
         -> :Vec<trading::log::LogEntry>)
        (:trading::telemetry::translate-stats maker stats))))
    (:wat::std::telemetry::Service/loop
      rxs
      (:wat::std::telemetry::Service::Stats/zero)
      cadence dispatcher stats-translator)))


;; ─── Sqlite/spawn — caller-side wiring ──────────────────────────

;; Build N request channel pairs, wrap senders in a HandlePool,
;; spawn the worker thread, return (pool, driver). Every call site
;; uses this — :user::main constructs once at startup, distributes
;; the popped req-tx handles to each producer, joins the driver
;; after the producers' senders all drop.
(:wat::core::define
  (:trading::telemetry::Sqlite/spawn<G>
    (path :String)
    (count :i64)
    (cadence :wat::std::telemetry::Service::MetricsCadence<G>)
    -> :wat::std::telemetry::Service::Spawn<trading::log::LogEntry>)
  (:wat::core::let*
    (((pairs :Vec<wat::std::telemetry::Service::ReqChannel<trading::log::LogEntry>>)
      (:wat::core::map
        (:wat::core::range 0 count)
        (:wat::core::lambda
          ((_i :i64)
           -> :wat::std::telemetry::Service::ReqChannel<trading::log::LogEntry>)
          (:wat::kernel::make-bounded-queue
            :wat::std::telemetry::Service::Request<trading::log::LogEntry> 1))))
     ((req-txs :Vec<wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :wat::std::telemetry::Service::ReqChannel<trading::log::LogEntry>)
           -> :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
          (:wat::core::first p))))
     ((req-rxs :Vec<wat::std::telemetry::Service::ReqRx<trading::log::LogEntry>>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :wat::std::telemetry::Service::ReqChannel<trading::log::LogEntry>)
           -> :wat::std::telemetry::Service::ReqRx<trading::log::LogEntry>)
          (:wat::core::second p))))
     ((pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::kernel::HandlePool::new "trading::telemetry::Sqlite" req-txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :trading::telemetry::Sqlite/loop-entry
        path req-rxs cadence)))
    (:wat::core::tuple pool driver)))
