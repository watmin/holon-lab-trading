;; wat-tests-integ/proof/002-thinker-baseline.wat — paired with
;; docs/proofs/2026/04/002-thinker-baseline/PROOF.md.
;;
;; ONE deftest measuring (papers, grace, violence, total-residue,
;; total-loss) for BOTH v1 thinkers on the same 10k-candle BTC
;; window, logging one Event::Log row per Outcome to ONE SQLite db.
;; The data column carries a `:trading::PaperResolved` struct (Tagged
;; EDN); SQL queries against the `log` table parse it back to typed
;; fields. Cross-thinker queries are `WHERE data LIKE '%thinker% ...'`
;; or by parsing the data column as EDN.
;;
;; Slice 6 (arc 091): the lab's `:trading::log::LogEntry::PaperResolved`
;; variant retired in favor of substrate `:wat::telemetry::Event::Log`
;; carrying `:trading::PaperResolved` as Tagged data. Per the metric/log
;; discipline arc 091 surfaced: per-paper resolution observations are
;; Log-shaped, not Metric-shaped.
;;
;; Run via:
;;   cargo test --release --features proof-002 --test proof_002
;;
;; Then query the `log` table (renamed from `paper_resolved` per
;; substrate auto-spawn schema derivation):
;;   ls -t runs/proof-002-*.db | head -1 | xargs -I{} sqlite3 {} <<EOF
;;     SELECT json_extract(data, '$.thinker')  AS thinker,
;;            COUNT(*)                         AS papers,
;;            SUM(json_extract(data, '$.state') = 'Grace')    AS grace,
;;            SUM(json_extract(data, '$.state') = 'Violence') AS violence,
;;            ROUND(SUM(json_extract(data, '$.residue')), 4)  AS total_residue,
;;            ROUND(SUM(json_extract(data, '$.loss')), 4)     AS total_loss
;;     FROM log
;;     WHERE namespace = ':trading.proofs.002'
;;     GROUP BY thinker
;;     ORDER BY thinker;
;;   EOF

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")
   (:wat::load-file! "wat/telemetry/Sqlite.wat")
   (:wat::load-file! "wat/types/paper-resolved.wat")
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
   ;; Build one PaperResolved value from an Outcome. Pure data —
   ;; no I/O. Returns :None for Active outcomes (unreachable at
   ;; resolution time but kept as a sentinel).
   ;; Slice 6 (arc 091): WorkUnitLog/info takes :wat::WatAST as data,
   ;; not :wat::holon::HolonAST. The helper returns the quasiquoted
   ;; constructor FORM (with values spliced in) so the substrate's
   ;; Atom/watast_to_holon arm can structurally lower it to a HolonAST
   ;; for the row's Tagged data column. The form round-trips back to
   ;; a PaperResolved on read.
   (:wat::core::define
     (:trading::test::proofs::002::outcome->form
       (run-name :String)
       (thinker-name :String) (predictor-name :String)
       (out :trading::sim::Outcome)
       -> :Option<wat::WatAST>)
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
       (:wat::core::match state -> :Option<wat::WatAST>
         ((:trading::sim::PositionState::Grace _r)
           (Some
             (:wat::core::quasiquote
               (:trading::PaperResolved/new
                 ,run-name ,thinker-name ,predictor-name
                 ,paper-id ,dir-str ,entry-candle ,closed-at
                 "Grace" ,final-residue 0.0))))
         (:trading::sim::PositionState::Violence
           (:wat::core::let*
             (((loss :f64) (:wat::core::f64::abs final-residue)))
             (Some
               (:wat::core::quasiquote
                 (:trading::PaperResolved/new
                   ,run-name ,thinker-name ,predictor-name
                   ,paper-id ,dir-str ,entry-candle ,closed-at
                   "Violence" 0.0 ,loss)))))
         (:trading::sim::PositionState::Active :None))))
   ;; Run-with-log: drops to run-loop + SimState/outcomes, walks
   ;; the resulting outcomes vec emitting one WorkUnitLog/info per
   ;; resolution. Inside a WorkUnit/make-scope so all rows share
   ;; the same uuid + tags.
   (:wat::core::define
     (:trading::test::proofs::002::run-with-log
       (stream :trading::candles::Stream)
       (thinker :trading::sim::Thinker)
       (predictor :trading::sim::Predictor)
       (config :trading::sim::Config)
       (sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
       (run-name :String)
       (thinker-name :String)
       (predictor-name :String)
       -> :trading::sim::Aggregate)
     (:wat::core::let*
       (((wlog :wat::telemetry::WorkUnitLog)
         (:wat::telemetry::WorkUnitLog/new
           sqlite-handle :proof-002
           (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
             (:wat::time::now))))
        ((ns :wat::holon::HolonAST) (:wat::holon::Atom :trading.proofs.002))
        ((scope :wat::telemetry::WorkUnit::Scope<trading::sim::Aggregate>)
         (:wat::telemetry::WorkUnit/make-scope sqlite-handle ns))
        ((tags :wat::telemetry::Tags)
         (:wat::core::assoc
           (:wat::core::assoc
             (:wat::core::HashMap :wat::telemetry::Tag)
             (:wat::holon::Atom :thinker)   (:wat::holon::Atom thinker-name))
           (:wat::holon::Atom :predictor) (:wat::holon::Atom predictor-name))))
       (scope tags
         (:wat::core::lambda
           ((wu :wat::telemetry::WorkUnit) -> :trading::sim::Aggregate)
           (:wat::core::let*
             (((final-state :trading::sim::SimState)
               (:trading::sim::run-loop
                 (:trading::sim::SimState::fresh)
                 stream config thinker predictor))
              ((outcomes :trading::sim::Outcomes)
               (:trading::sim::SimState/outcomes final-state))
              ((_emit :())
               (:wat::core::foldl outcomes ()
                 (:wat::core::lambda
                   ((_acc :())
                    (out :trading::sim::Outcome)
                    -> :())
                   (:wat::core::match
                     (:trading::test::proofs::002::outcome->form
                       run-name thinker-name predictor-name out)
                     -> :()
                     ((Some form)
                       (:wat::telemetry::WorkUnitLog/info wlog wu form))
                     (:None ()))))))
             (:trading::sim::SimState/aggregate final-state)))))))))


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

     ((db-path :String)
      (:wat::core::string::concat
        "runs/proof-002-" epoch-str ".db"))
     ((spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ((both :trading::test::proofs::002::BothRuns)
      (:wat::core::let*
        (((sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

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
            sqlite-handle
            run-name-up
            "always-up"
            "cosine-vs-corners"))
         ((up :trading::test::proofs::002::Counters)
          (:trading::test::proofs::002::Counters/new
            (:trading::sim::Aggregate/papers agg-up)
            (:trading::sim::Aggregate/grace-count agg-up)
            (:trading::sim::Aggregate/violence-count agg-up)))

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
            sqlite-handle
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

     ((u1 :()) (:wat::test::assert-eq
                 (:wat::core::= papers-up
                                (:wat::core::+ grace-up violence-up))
                 true))
     ((u2 :()) (:wat::test::assert-eq
                 (:wat::core::= papers-sx
                                (:wat::core::+ grace-sx violence-sx))
                 true))
     ((u3 :()) (:wat::test::assert-eq (:wat::core::> papers-up 0) true))
     ((u4 :()) (:wat::test::assert-eq (:wat::core::>= papers-sx 0) true))
     ((u5 :()) (:wat::test::assert-eq (:wat::core::< papers-up 5000) true)))
    (:wat::test::assert-eq (:wat::core::< papers-sx 5000) true)))
