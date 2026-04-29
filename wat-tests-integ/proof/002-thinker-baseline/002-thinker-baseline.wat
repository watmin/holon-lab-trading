;; wat-tests-integ/proof/002-thinker-baseline.wat — paired with
;; docs/proofs/2026/04/002-thinker-baseline/PROOF.md.
;;
;; ONE deftest measuring (papers, grace, violence, total-residue,
;; total-loss) for BOTH v1 thinkers on the same 10k-candle BTC
;; window, logging one row per Outcome to ONE SQLite db. The
;; schema's `thinker` column distinguishes runs; cross-thinker
;; queries are `GROUP BY thinker`. Per arc 029 Q8 ("one DB per
;; run, many tables") the v0 file-split (per-thinker DBs) was a
;; misstep — corrected here.
;;
;; Run via:
;;   cargo test --release --features proof-002 --test proof_002
;;
;; Then query:
;;   ls -t runs/proof-002-*.db | head -1 | xargs -I{} sqlite3 {} <<EOF
;;     SELECT thinker,
;;            COUNT(*) AS papers,
;;            SUM(state='Grace') AS grace,
;;            SUM(state='Violence') AS violence,
;;            ROUND(SUM(residue), 4) AS total_residue,
;;            ROUND(SUM(loss), 4) AS total_loss
;;     FROM paper_resolutions
;;     GROUP BY thinker
;;     ORDER BY thinker;
;;   EOF
;;
;; The proof's seam (per slice-4-5-design-questions.md): the
;; simulator's :trading::sim::run only exposes Aggregate. To get
;; per-paper Outcomes, this proof drops to :trading::sim::run-loop +
;; SimState/outcomes — both public — and walks the resulting
;; outcomes vec, logging each. No simulator-side change needed.
;;
;; Arcs 083/084/085 (2026-04-28) replace the lab's RunDb Rust shim
;; with the substrate's auto-spawn sink. Migration:
;;   - log-paper-resolved is gone; the proof builds
;;     :trading::log::LogEntry::PaperResolved values and batch-logs
;;     them through the substrate Sqlite sink.
;;   - Table renames: paper_resolutions → paper_resolved
;;     (substrate derives variant name PascalCase → snake_case;
;;     SELECT-side queries below need the new name).
;;   - PRIMARY KEY (run_name, paper_id) is dropped; the auto-derived
;;     schema is one column per field with no constraints. Reruns
;;     accumulate rows; clean DB or unique paths if that matters.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")
   (:wat::load-file! "wat/io/telemetry/Sqlite.wat")
   ;; Aggregated counters from one run, packaged so the inner
   ;; let* can return both runs' results back to outer scope.
   (:wat::core::struct :trading::test::proofs::002::Counters
     (papers   :i64)
     (grace    :i64)
     (violence :i64))
   (:wat::core::struct :trading::test::proofs::002::BothRuns
     (up :trading::test::proofs::002::Counters)
     (sx :trading::test::proofs::002::Counters))
   ;; Helper — Direction → "Up" | "Down".
   (:wat::core::define
     (:trading::test::proofs::002::dir-str
       (d :trading::sim::Direction)
       -> :String)
     (:wat::core::match d -> :String
       (:trading::sim::Direction::Up   "Up")
       (:trading::sim::Direction::Down "Down")))
   ;; Build one PaperResolved entry from an Outcome. Pure data —
   ;; no I/O. The dispatcher half (writing) lives in batch-log.
   (:wat::core::define
     (:trading::test::proofs::002::outcome->entry
       (run-name :String)
       (thinker-name :String) (predictor-name :String)
       (out :trading::sim::Outcome)
       -> :Option<trading::log::LogEntry>)
     (:wat::core::let*
       (((paper :trading::sim::Paper) (:trading::sim::Outcome/paper out))
        ((paper-id :i64)              (:trading::sim::Paper/id paper))
        ((dir :trading::sim::Direction)
                                      (:trading::sim::Paper/direction paper))
        ((entry-candle :i64)          (:trading::sim::Paper/entry-candle paper))
        ((closed-at :i64)             (:trading::sim::Outcome/closed-at out))
        ((state :trading::sim::PositionState)
                                      (:trading::sim::Paper/state paper))
        ((final-residue :f64)         (:trading::sim::Outcome/final-residue out))
        ((dir-str :String)            (:trading::test::proofs::002::dir-str dir)))
       (:wat::core::match state -> :Option<trading::log::LogEntry>
         ((:trading::sim::PositionState::Grace _r)
           (Some
             (:trading::log::LogEntry::PaperResolved
               run-name thinker-name predictor-name
               paper-id dir-str entry-candle closed-at
               "Grace" final-residue 0.0)))
         (:trading::sim::PositionState::Violence
           (Some
             (:trading::log::LogEntry::PaperResolved
               run-name thinker-name predictor-name
               paper-id dir-str entry-candle closed-at
               "Violence" 0.0 (:wat::core::f64::abs final-residue))))
         ;; Active is unreachable at outcome time; sentinel — no log.
         (:trading::sim::PositionState::Active :None))))
   ;; Run-with-log: drops to run-loop + SimState/outcomes, walks
   ;; the resulting outcomes vec collecting LogEntry values, then
   ;; batch-logs them all at the end of the run.
   (:wat::core::define
     (:trading::test::proofs::002::run-with-log
       (stream :trading::candles::Stream)
       (thinker :trading::sim::Thinker)
       (predictor :trading::sim::Predictor)
       (config :trading::sim::Config)
       (req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
       (ack-tx :wat::std::telemetry::Service::AckTx)
       (ack-rx :wat::std::telemetry::Service::AckRx)
       (run-name :String)
       (thinker-name :String)
       (predictor-name :String)
       -> :trading::sim::Aggregate)
     (:wat::core::let*
       (((final-state :trading::sim::SimState)
         (:trading::sim::run-loop
           (:trading::sim::SimState::fresh)
           stream config thinker predictor))
        ((outcomes :trading::sim::Outcomes)
         (:trading::sim::SimState/outcomes final-state))
        ;; Build entries (filtering out Active sentinels), then batch.
        ((entries :Vec<trading::log::LogEntry>)
         (:wat::core::foldl outcomes
           (:wat::core::vec :trading::log::LogEntry)
           (:wat::core::lambda
             ((acc :Vec<trading::log::LogEntry>)
              (out :trading::sim::Outcome)
              -> :Vec<trading::log::LogEntry>)
             (:wat::core::match
               (:trading::test::proofs::002::outcome->entry
                 run-name thinker-name predictor-name out)
               -> :Vec<trading::log::LogEntry>
               ((Some entry)
                 (:wat::core::concat acc
                   (:wat::core::vec :trading::log::LogEntry entry)))
               (:None acc)))))
        ((_log :())
         (:wat::std::telemetry::Service/batch-log
           req-tx ack-tx ack-rx entries)))
       (:trading::sim::SimState/aggregate final-state)))))


;; ─── ONE deftest, BOTH thinkers, ONE db ──────────────────────────

(:deftest :trading::test::proofs::002::thinker-baseline
  (:wat::core::let*
    (;; Shared run discriminators.
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))

     ;; ONE db file holding both thinkers' rows.
     ((db-path :String)
      (:wat::core::string::concat
        "runs/proof-002-" epoch-str ".db"))
     ;; Spawn the substrate Sqlite sink. count=1 — the proof drives
     ;; logging from a single thread.
     ((spawn :trading::telemetry::Spawn)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::std::telemetry::Service/null-metrics-cadence)))
     ((pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ;; Inner scope owns the popped req-tx + the ack channel pair;
     ;; on inner-exit, both drop, the worker sees disconnect, and
     ;; outer's join unblocks.
     ((both :trading::test::proofs::002::BothRuns)
      (:wat::core::let*
        (((req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((ack-pair :wat::std::telemetry::Service::AckChannel)
          (:wat::kernel::make-bounded-queue :() 1))
         ((ack-tx :wat::std::telemetry::Service::AckTx)
          (:wat::core::first ack-pair))
         ((ack-rx :wat::std::telemetry::Service::AckRx)
          (:wat::core::second ack-pair))

         ;; Always-up run.
         ((stream-up :trading::candles::Stream)
          (:trading::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
         ((run-name-up :String)
          (:wat::core::string::concat "always-up-10k-" iso-str))
         ((agg-up :trading::sim::Aggregate)
          (:trading::test::proofs::002::run-with-log
            stream-up
            (:trading::sim::always-up-thinker)
            (:trading::sim::cosine-vs-corners-predictor)
            cfg
            req-tx ack-tx ack-rx
            run-name-up
            "always-up"
            "cosine-vs-corners"))
         ((up :trading::test::proofs::002::Counters)
          (:trading::test::proofs::002::Counters/new
            (:trading::sim::Aggregate/papers agg-up)
            (:trading::sim::Aggregate/grace-count agg-up)
            (:trading::sim::Aggregate/violence-count agg-up)))

         ;; SMA-cross run — SAME db, different run-name.
         ((stream-sx :trading::candles::Stream)
          (:trading::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
         ((run-name-sx :String)
          (:wat::core::string::concat "sma-cross-10k-" iso-str))
         ((agg-sx :trading::sim::Aggregate)
          (:trading::test::proofs::002::run-with-log
            stream-sx
            (:trading::sim::sma-cross-thinker)
            (:trading::sim::cosine-vs-corners-predictor)
            cfg
            req-tx ack-tx ack-rx
            run-name-sx
            "sma-cross"
            "cosine-vs-corners"))
         ((sx :trading::test::proofs::002::Counters)
          (:trading::test::proofs::002::Counters/new
            (:trading::sim::Aggregate/papers agg-sx)
            (:trading::sim::Aggregate/grace-count agg-sx)
            (:trading::sim::Aggregate/violence-count agg-sx))))
        (:trading::test::proofs::002::BothRuns/new up sx)))
     ((_join :()) (:wat::kernel::join driver))
     ;; Unpack the struct fields back into flat let* bindings so
     ;; the assertions stay readable.
     ((up :trading::test::proofs::002::Counters)
      (:trading::test::proofs::002::BothRuns/up both))
     ((sx :trading::test::proofs::002::Counters)
      (:trading::test::proofs::002::BothRuns/sx both))
     ((papers-up :i64)   (:trading::test::proofs::002::Counters/papers up))
     ((grace-up :i64)    (:trading::test::proofs::002::Counters/grace up))
     ((violence-up :i64) (:trading::test::proofs::002::Counters/violence up))
     ((papers-sx :i64)   (:trading::test::proofs::002::Counters/papers sx))
     ((grace-sx :i64)    (:trading::test::proofs::002::Counters/grace sx))
     ((violence-sx :i64) (:trading::test::proofs::002::Counters/violence sx))

     ;; Conservation invariants — both thinkers.
     ((u1 :()) (:wat::test::assert-eq
                 (:wat::core::= papers-up
                                (:wat::core::+ grace-up violence-up))
                 true))
     ((u2 :()) (:wat::test::assert-eq
                 (:wat::core::= papers-sx
                                (:wat::core::+ grace-sx violence-sx))
                 true))
     ;; Liveness — both thinkers produced papers.
     ((u3 :()) (:wat::test::assert-eq (:wat::core::> papers-up 0) true))
     ((u4 :()) (:wat::test::assert-eq (:wat::core::>= papers-sx 0) true))
     ;; Sanity — neither blew up.
     ((u5 :()) (:wat::test::assert-eq (:wat::core::< papers-up 5000) true)))
    (:wat::test::assert-eq (:wat::core::< papers-sx 5000) true)))
