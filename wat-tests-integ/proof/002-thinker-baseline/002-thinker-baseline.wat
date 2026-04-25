;; wat-tests-integ/proof/002-thinker-baseline.wat — paired with
;; docs/proofs/2026/04/002-thinker-baseline/PROOF.md.
;;
;; Two deftests measuring (papers, grace, violence, total-residue,
;; total-loss) per v1 thinker on the same 10k-candle BTC window,
;; logging one row per Outcome to a SQLite db so the proof's
;; claims are query-friendly (per feedback_query_db_not_tail —
;; "no grepping; SQL on the run DB").
;;
;; Run via:
;;   rm -f runs/proof-002-*.db    # cleanup; PK violation otherwise
;;   cargo test --release --features proof-002 --test proof_002
;;
;; Then query:
;;   sqlite3 runs/proof-002-always-up.db <<EOF
;;     SELECT COUNT(*) papers,
;;            SUM(state='Grace') grace,
;;            SUM(state='Violence') violence,
;;            ROUND(SUM(residue), 4) total_residue,
;;            ROUND(SUM(loss), 4) total_loss
;;     FROM paper_resolutions;
;;   EOF
;;
;; The proof's seam (per slice-4-5-design-questions.md Q's notes):
;; the simulator's :trading::sim::run only exposes Aggregate. To get
;; per-paper Outcomes, this proof drops to :trading::sim::run-loop +
;; SimState/outcomes — both public — and walks the resulting outcomes
;; vec, logging each. No simulator-side change needed.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")
   ;; Helper — Direction → "Up" | "Down".
   (:wat::core::define
     (:trading::test::proofs::002::dir-str
       (d :trading::sim::Direction)
       -> :String)
     (:wat::core::match d -> :String
       (:trading::sim::Direction::Up   "Up")
       (:trading::sim::Direction::Down "Down")))
   ;; Helper — log one Outcome row to RunDb. Splits the signed
   ;; final-residue into the schema's separate residue/loss columns
   ;; per the simulator's aggregate-grace / aggregate-violence
   ;; conventions: Grace adds positive residue (loss=0); Violence
   ;; adds abs to total-loss (residue=0).
   (:wat::core::define
     (:trading::test::proofs::002::log-outcome
       (db :lab::rundb::RunDb)
       (thinker-name :String) (predictor-name :String)
       (out :trading::sim::Outcome)
       -> :())
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
       (:wat::core::match state -> :()
         ((:trading::sim::PositionState::Grace _r)
           (:lab::rundb::log-paper db
             thinker-name predictor-name
             paper-id dir-str entry-candle closed-at
             "Grace" final-residue 0.0))
         (:trading::sim::PositionState::Violence
           (:lab::rundb::log-paper db
             thinker-name predictor-name
             paper-id dir-str entry-candle closed-at
             "Violence" 0.0 (:wat::core::f64::abs final-residue)))
         ;; Active is unreachable at outcome time; sentinel — no log.
         (:trading::sim::PositionState::Active ()))))
   ;; Run-with-log: drops to run-loop + SimState/outcomes to expose
   ;; per-paper Outcomes (run() only returns Aggregate).
   (:wat::core::define
     (:trading::test::proofs::002::run-with-log
       (stream :lab::candles::Stream)
       (thinker :trading::sim::Thinker)
       (predictor :trading::sim::Predictor)
       (config :trading::sim::Config)
       (db :lab::rundb::RunDb)
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
        ;; Walk outcomes for the side effect (logging). Foldl
        ;; accumulator is unit; we throw it away.
        ((_ :())
         (:wat::core::foldl outcomes ()
           (:wat::core::lambda
             ((acc :()) (out :trading::sim::Outcome) -> :())
             (:trading::test::proofs::002::log-outcome
               db thinker-name predictor-name out)))))
       (:trading::sim::SimState/aggregate final-state)))))


;; ─── Always-up thinker on 10k candles ─────────────────────────────

(:deftest :trading::test::proofs::002::always-up-10k
  (:wat::core::let*
    (((stream :lab::candles::Stream)
      (:lab::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ;; Per arc 056 — :wat::time::Instant gives unique-per-execution
     ;; discriminators. epoch-seconds in the FILENAME (numeric, sortable,
     ;; no chars that confuse downstream tools); ISO 8601 ms-precision
     ;; in the run_name (human-readable in SQL queries).
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))
     ((path :String)
      (:wat::core::string::concat
        "runs/proof-002-always-up-" epoch-str ".db"))
     ((run-name :String)
      (:wat::core::string::concat
        "always-up-10k-" iso-str))
     ((db :lab::rundb::RunDb) (:lab::rundb::open path run-name))
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((agg :trading::sim::Aggregate)
      (:trading::test::proofs::002::run-with-log
        stream
        (:trading::sim::always-up-thinker)
        (:trading::sim::cosine-vs-corners-predictor)
        cfg
        db
        "always-up"
        "cosine-vs-corners"))
     ((papers :i64)   (:trading::sim::Aggregate/papers agg))
     ((grace :i64)    (:trading::sim::Aggregate/grace-count agg))
     ((violence :i64) (:trading::sim::Aggregate/violence-count agg))
     ;; Conservation: same as proof 001.
     ((u1 :()) (:wat::test::assert-eq
                 (:wat::core::= papers (:wat::core::+ grace violence))
                 true))
     ((u2 :()) (:wat::test::assert-eq (:wat::core::> papers 0) true)))
    (:wat::test::assert-eq (:wat::core::< papers 5000) true)))


;; ─── SMA-cross thinker on 10k candles ─────────────────────────────

(:deftest :trading::test::proofs::002::sma-cross-10k
  (:wat::core::let*
    (((stream :lab::candles::Stream)
      (:lab::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))
     ((path :String)
      (:wat::core::string::concat
        "runs/proof-002-sma-cross-" epoch-str ".db"))
     ((run-name :String)
      (:wat::core::string::concat
        "sma-cross-10k-" iso-str))
     ((db :lab::rundb::RunDb) (:lab::rundb::open path run-name))
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((agg :trading::sim::Aggregate)
      (:trading::test::proofs::002::run-with-log
        stream
        (:trading::sim::sma-cross-thinker)
        (:trading::sim::cosine-vs-corners-predictor)
        cfg
        db
        "sma-cross"
        "cosine-vs-corners"))
     ((papers :i64)   (:trading::sim::Aggregate/papers agg))
     ((grace :i64)    (:trading::sim::Aggregate/grace-count agg))
     ((violence :i64) (:trading::sim::Aggregate/violence-count agg))
     ((u1 :()) (:wat::test::assert-eq
                 (:wat::core::= papers (:wat::core::+ grace violence))
                 true))
     ((u2 :()) (:wat::test::assert-eq (:wat::core::>= papers 0) true)))
    (:wat::test::assert-eq (:wat::core::< papers 5000) true)))
