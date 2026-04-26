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
;; Arc 029 (2026-04-25) updates:
;;   - log-paper renamed to log-paper-resolved
;;   - run-name promoted from per-handle bind to per-call param
;;   - both thinkers write to ONE db file (per-thinker file-split
;;     was the v0 misstep — corrected here)

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
   ;;
   ;; Arc 029: gained `run-name` parameter; threads into the
   ;; per-call run-name slot of log-paper-resolved.
   (:wat::core::define
     (:trading::test::proofs::002::log-outcome
       (db :trading::rundb::RunDb)
       (run-name :String)
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
           (:trading::rundb::log-paper-resolved db
             run-name thinker-name predictor-name
             paper-id dir-str entry-candle closed-at
             "Grace" final-residue 0.0))
         (:trading::sim::PositionState::Violence
           (:trading::rundb::log-paper-resolved db
             run-name thinker-name predictor-name
             paper-id dir-str entry-candle closed-at
             "Violence" 0.0 (:wat::core::f64::abs final-residue)))
         ;; Active is unreachable at outcome time; sentinel — no log.
         (:trading::sim::PositionState::Active ()))))
   ;; Run-with-log: drops to run-loop + SimState/outcomes to expose
   ;; per-paper Outcomes (run() only returns Aggregate).
   ;;
   ;; Arc 029: gained `run-name` parameter; propagates to log-outcome.
   (:wat::core::define
     (:trading::test::proofs::002::run-with-log
       (stream :trading::candles::Stream)
       (thinker :trading::sim::Thinker)
       (predictor :trading::sim::Predictor)
       (config :trading::sim::Config)
       (db :trading::rundb::RunDb)
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
        ;; Walk outcomes for the side effect (logging). Foldl
        ;; accumulator is unit; we throw it away.
        ((_ :())
         (:wat::core::foldl outcomes ()
           (:wat::core::lambda
             ((acc :()) (out :trading::sim::Outcome) -> :())
             (:trading::test::proofs::002::log-outcome
               db run-name thinker-name predictor-name out)))))
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
     ((db :trading::rundb::RunDb) (:trading::rundb::open db-path))

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
        db
        run-name-up
        "always-up"
        "cosine-vs-corners"))
     ((papers-up :i64)   (:trading::sim::Aggregate/papers agg-up))
     ((grace-up :i64)    (:trading::sim::Aggregate/grace-count agg-up))
     ((violence-up :i64) (:trading::sim::Aggregate/violence-count agg-up))

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
        db
        run-name-sx
        "sma-cross"
        "cosine-vs-corners"))
     ((papers-sx :i64)   (:trading::sim::Aggregate/papers agg-sx))
     ((grace-sx :i64)    (:trading::sim::Aggregate/grace-count agg-sx))
     ((violence-sx :i64) (:trading::sim::Aggregate/violence-count agg-sx))

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
