;; wat-tests-integ/proof/003-thinker-significance.wat — paired with
;; docs/proofs/2026/04/003-thinker-significance/PROOF.md.
;;
;; Walks the same 10k-candle window 10 times across the corpus
;; (offsets 0, ~65k, ~130k, ...) for BOTH v1 thinkers — 20 sub-
;; runs — into ONE SQLite db. Per-paper resolution rows go to the
;; substrate's `log` table (Event::Log carrying :trading::PaperResolved
;; as Tagged data).
;;
;; Slice 6 (arc 091): replaces the lab's :trading::log::LogEntry
;; pipe with substrate :wat::telemetry::Event throughout. Each
;; window opens its own WorkUnit/make-scope; emissions ride through
;; WorkUnitLog/info. The wu's uuid stamps every row, giving SQL a
;; key to group rows per window in addition to the tags.
;;
;; Run via:
;;   cargo test --release --features proof-003 --test proof_003

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")
   (:wat::load-file! "wat/telemetry/Sqlite.wat")
   (:wat::load-file! "wat/types/paper-resolved.wat")

   ;; Helper — Direction → "Up" | "Down".
   (:wat::core::define
     (:trading::test::proofs::003::dir-str
       (d :trading::sim::Direction)
       -> :String)
     (:wat::core::match d -> :String
       (:trading::sim::Direction::Up   "Up")
       (:trading::sim::Direction::Down "Down")))

   ;; Skip n candles from the stream — burn the prefix.
   (:wat::core::define
     (:trading::test::proofs::003::skip-n
       (stream :trading::candles::Stream)
       (n :i64)
       -> :())
     (:wat::core::if (:wat::core::<= n 0) -> :()
       ()
       (:wat::core::let*
         (((_ :Option<trading::candles::Ohlcv>)
           (:trading::candles::next! stream)))
         (:trading::test::proofs::003::skip-n stream (:wat::core::- n 1)))))

   ;; Slice 6 (arc 091) + slice 8: helper builds the per-Outcome
   ;; PaperResolved struct; emit-site lifts via :wat::core::struct->form.
   (:wat::core::define
     (:trading::test::proofs::003::outcome->resolved
       (run-name :String)
       (thinker-name :String) (predictor-name :String)
       (out :trading::sim::Outcome)
       -> :Option<trading::PaperResolved>)
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
        ((dir-str :String)            (:trading::test::proofs::003::dir-str dir)))
       (:wat::core::match state -> :Option<trading::PaperResolved>
         ((:trading::sim::PositionState::Grace _r)
           (Some
             (:trading::PaperResolved/new
               run-name thinker-name predictor-name
               paper-id dir-str entry-candle closed-at
               "Grace" final-residue 0.0)))
         (:trading::sim::PositionState::Violence
           (Some
             (:trading::PaperResolved/new
               run-name thinker-name predictor-name
               paper-id dir-str entry-candle closed-at
               "Violence" 0.0 (:wat::core::f64::abs final-residue))))
         (:trading::sim::PositionState::Active :None))))

   ;; Run one window: open bounded stream sized for `start + n`,
   ;; skip the first `start` candles, run-loop the next `n`, walk
   ;; outcomes emitting one Event::Log per resolution. One make-scope
   ;; per window — its uuid groups the window's rows.
   (:wat::core::define
     (:trading::test::proofs::003::run-window
       (sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
       (path :String)
       (start :i64)
       (n :i64)
       (cfg :trading::sim::Config)
       (thinker :trading::sim::Thinker)
       (predictor :trading::sim::Predictor)
       (run-name :String)
       (thinker-name :String)
       (predictor-name :String)
       -> :())
     (:wat::core::let*
       (((wlog :wat::telemetry::WorkUnitLog)
         (:wat::telemetry::WorkUnitLog/new
           sqlite-handle :proof-003
           (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
             (:wat::time::now))))
        ((ns :wat::holon::HolonAST) (:wat::holon::Atom :trading.proofs.003))
        ((scope :wat::telemetry::WorkUnit::Scope<()>)
         (:wat::telemetry::WorkUnit/make-scope sqlite-handle ns))
        ((tags :wat::telemetry::Tags)
         (:wat::core::assoc
           (:wat::core::assoc
             (:wat::core::HashMap :wat::telemetry::Tag)
             (:wat::holon::Atom :thinker)   (:wat::holon::Atom thinker-name))
           (:wat::holon::Atom :predictor) (:wat::holon::Atom predictor-name))))
       (scope tags
         (:wat::core::lambda
           ((wu :wat::telemetry::WorkUnit) -> :())
           (:wat::core::let*
             (((stream :trading::candles::Stream)
               (:trading::candles::open-bounded path (:wat::core::+ start n)))
              ((_skip :())
               (:trading::test::proofs::003::skip-n stream start))
              ((final-state :trading::sim::SimState)
               (:trading::sim::run-loop
                 (:trading::sim::SimState::fresh)
                 stream cfg thinker predictor))
              ((outcomes :trading::sim::Outcomes)
               (:trading::sim::SimState/outcomes final-state)))
             (:wat::core::foldl outcomes ()
               (:wat::core::lambda
                 ((_acc :())
                  (out :trading::sim::Outcome)
                  -> :())
                 (:wat::core::match
                   (:trading::test::proofs::003::outcome->resolved
                     run-name thinker-name predictor-name out)
                   -> :()
                   ((Some pr)
                     (:wat::telemetry::WorkUnitLog/info wlog wu
                       (:wat::core::struct->form pr)))
                   (:None ())))))))))

   ;; Walk 0..10 windows for one thinker.
   (:wat::core::define
     (:trading::test::proofs::003::run-thinker-windows
       (sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
       (path :String)
       (cfg :trading::sim::Config)
       (thinker :trading::sim::Thinker)
       (predictor :trading::sim::Predictor)
       (thinker-name :String)
       (predictor-name :String)
       (iso-str :String)
       -> :())
     (:wat::core::foldl (:wat::core::range 0 10) ()
       (:wat::core::lambda
         ((_acc :()) (i :i64) -> :())
         (:wat::core::let*
           (((start :i64) (:wat::core::* i 65261))
            ((run-name :String)
             (:wat::core::string::concat
               thinker-name "-w" (:wat::core::i64::to-string i) "-" iso-str)))
           (:trading::test::proofs::003::run-window
             sqlite-handle path start 10000 cfg
             thinker predictor
             run-name thinker-name predictor-name)))))))


;; ─── ONE deftest, BOTH thinkers, ONE db, 20 sub-runs ──────────────

(:deftest :trading::test::proofs::003::thinker-significance
  (:wat::core::let*
    (((path :String) "data/btc_5m_raw.parquet")
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))

     ((db-path :String)
      (:wat::core::string::concat "runs/proof-003-" epoch-str ".db"))

     ((spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((_run-up :())
          (:trading::test::proofs::003::run-thinker-windows
            sqlite-handle path cfg
            (:trading::sim::always-up-thinker)
            (:trading::sim::cosine-vs-corners-predictor)
            "always-up" "cosine-vs-corners" iso-str))

         ((_run-sx :())
          (:trading::test::proofs::003::run-thinker-windows
            sqlite-handle path cfg
            (:trading::sim::sma-cross-thinker)
            (:trading::sim::cosine-vs-corners-predictor)
            "sma-cross" "cosine-vs-corners" iso-str)))
        ()))

     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
