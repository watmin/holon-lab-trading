;; wat-tests-integ/proof/003-thinker-significance.wat — paired with
;; docs/proofs/2026/04/003-thinker-significance/PROOF.md.
;;
;; ONE deftest measuring (papers, grace, violence, total-residue,
;; total-loss, net-pnl) for BOTH v1 thinkers across 10 strided
;; 10k-candle windows (stride = 65,261 = ⌊652,608 / 10⌋), logging
;; one row per Outcome to ONE SQLite db at
;; `runs/proof-003-<epoch>.db`. The schema's `thinker` column
;; distinguishes runs; the `run_name` column distinguishes windows
;; (`<thinker>-w<i>-<iso>`). 20 sub-runs (2 thinkers × 10 windows)
;; under one connection.
;;
;; Run via:
;;   cargo test --release --features proof-003 --test proof_003 -- --nocapture
;;
;; Then query (per feedback_query_db_not_tail):
;;   ls -t runs/proof-003-*.db | head -1 | xargs -I{} sqlite3 {} <<EOF
;;     SELECT thinker,
;;            COUNT(*) AS papers,
;;            SUM(state='Grace') AS grace,
;;            SUM(state='Violence') AS violence,
;;            ROUND(SUM(residue), 4) AS total_residue,
;;            ROUND(SUM(loss), 4) AS total_loss,
;;            ROUND(SUM(residue) - SUM(loss), 4) AS net_pnl
;;     FROM paper_resolutions
;;     GROUP BY thinker
;;     ORDER BY thinker;
;;   EOF
;;
;; ── Architecture (per arc 029) ──
;;   - Q8: one DB per run, many tables/columns inside. ✓ one file.
;;   - Q9: communication unit is :trading::log::LogEntry::PaperResolved.
;;   - Q10: confirmed batch + ack via :trading::rundb::Service/batch-log.
;;
;; ── Lifetime discipline (Console multi-writer pattern) ──
;; The driver loop converges to empty only when every ReqRx has
;; disconnected — which requires every parent-side ReqTx to drop.
;; This deftest wraps client-side bindings (popped handle, ack
;; channel, the simulator runs that consume the handle) inside an
;; INNER let* whose scope exits BEFORE the outer let*'s
;; `(:wat::kernel::join driver)`. When the inner scope drops, the
;; ReqTx clone disappears, the driver loop converges, exits, and
;; the outer join returns. Same shape as
;; `wat-tests/io/RunDbService.wat` test-multi-client-fan-in.
;;
;; ── Window scheme ──
;; `:trading::candles::open-bounded path n` caps total emissions from
;; row 0. To reach window w_i: open with n = start_i + 10_000,
;; then `next!` × start_i to discard, then run-loop the next 10k.
;; Skip cost is parquet streaming-reads — negligible vs simulator
;; work. `skip-n` recurses with TCO (per wat-rs arc 003 stage 1
;; named-define self-call TCO) so 587k-deep skips don't blow the
;; stack on the late windows.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")
   (:wat::load-file! "wat/io/telemetry/Sqlite.wat")

   ;; Direction → "Up" | "Down".
   (:wat::core::define
     (:trading::test::proofs::003::dir-str
       (d :trading::sim::Direction)
       -> :String)
     (:wat::core::match d -> :String
       (:trading::sim::Direction::Up   "Up")
       (:trading::sim::Direction::Down "Down")))

   ;; Recursively pull and discard `n` candles. TCO via named-define
   ;; self-recursion keeps stack constant for n ≈ 600k (the largest
   ;; skip — w9 with start=587,348).
   (:wat::core::define
     (:trading::test::proofs::003::skip-n
       (s :trading::candles::Stream)
       (n :i64)
       -> :())
     (:wat::core::if (:wat::core::<= n 0) -> :()
       ()
       (:wat::core::let*
         (((_ :Option<(i64,f64,f64,f64,f64,f64)>)
           (:trading::candles::next! s)))
         (:trading::test::proofs::003::skip-n s (:wat::core::- n 1)))))

   ;; Map a Vec<Outcome> → Vec<LogEntry> using the schema's
   ;; aggregate-grace / aggregate-violence convention: Grace adds
   ;; positive residue (loss=0); Violence adds abs to total-loss
   ;; (residue=0). PositionState::Active is sentinel (unreachable
   ;; at outcome time) — its arm leaves the accumulator untouched.
   ;;
   ;; foldl-with-conj rather than map+filter-map: keeps the type
   ;; explicit and avoids an Option-Vec intermediate.
   (:wat::core::define
     (:trading::test::proofs::003::outcomes-to-entries
       (outcomes :trading::sim::Outcomes)
       (run-name :String)
       (thinker-name :String)
       (predictor-name :String)
       -> :Vec<trading::log::LogEntry>)
     (:wat::core::foldl outcomes
       (:wat::core::vec :trading::log::LogEntry)
       (:wat::core::lambda
         ((acc :Vec<trading::log::LogEntry>)
          (out :trading::sim::Outcome)
          -> :Vec<trading::log::LogEntry>)
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
           (:wat::core::match state -> :Vec<trading::log::LogEntry>
             ((:trading::sim::PositionState::Grace _r)
               (:wat::core::conj acc
                 (:trading::log::LogEntry::PaperResolved
                   run-name thinker-name predictor-name
                   paper-id dir-str entry-candle closed-at
                   "Grace" final-residue 0.0)))
             (:trading::sim::PositionState::Violence
               (:wat::core::conj acc
                 (:trading::log::LogEntry::PaperResolved
                   run-name thinker-name predictor-name
                   paper-id dir-str entry-candle closed-at
                   "Violence" 0.0 (:wat::core::f64::abs final-residue))))
             (:trading::sim::PositionState::Active acc))))))

   ;; Run one window: open bounded stream sized for `start + n`,
   ;; skip the first `start` candles, run-loop the next `n`, walk
   ;; outcomes for batch-log. One ack per window (~30-40 entries
   ;; per batch).
   (:wat::core::define
     (:trading::test::proofs::003::run-window
       (req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
       (ack-tx :wat::std::telemetry::Service::AckTx)
       (ack-rx :wat::std::telemetry::Service::AckRx)
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
       (((stream :trading::candles::Stream)
         (:trading::candles::open-bounded path (:wat::core::+ start n)))
        ((_skip :())
         (:trading::test::proofs::003::skip-n stream start))
        ((final-state :trading::sim::SimState)
         (:trading::sim::run-loop
           (:trading::sim::SimState::fresh)
           stream cfg thinker predictor))
        ((outcomes :trading::sim::Outcomes)
         (:trading::sim::SimState/outcomes final-state))
        ((entries :Vec<trading::log::LogEntry>)
         (:trading::test::proofs::003::outcomes-to-entries
           outcomes run-name thinker-name predictor-name)))
       (:wat::std::telemetry::Service/batch-log req-tx ack-tx ack-rx entries)))

   ;; Walk 0..10 (window indices). For each i: start = i * stride,
   ;; run-window with run-name "<thinker>-w<i>-<iso>".
   (:wat::core::define
     (:trading::test::proofs::003::run-thinker-windows
       (req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
       (ack-tx :wat::std::telemetry::Service::AckTx)
       (ack-rx :wat::std::telemetry::Service::AckRx)
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
         ((acc :()) (i :i64) -> :())
         (:wat::core::let*
           (((start :i64) (:wat::core::* i 65261))
            ((run-name :String)
             (:wat::core::string::concat
               thinker-name "-w" (:wat::core::i64::to-string i) "-" iso-str)))
           (:trading::test::proofs::003::run-window
             req-tx ack-tx ack-rx path start 10000 cfg
             thinker predictor
             run-name thinker-name predictor-name)))))))


;; ─── ONE deftest, BOTH thinkers, ONE db, 20 sub-runs ──────────────

(:deftest :trading::test::proofs::003::thinker-significance
  (:wat::core::let*
    (;; Shared run discriminators.
     ((path :String) "data/btc_5m_raw.parquet")
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))

     ;; ONE db file holding all 20 sub-runs.
     ((db-path :String)
      (:wat::core::string::concat "runs/proof-003-" epoch-str ".db"))

     ;; Spawn the service with N=1 client (single-thread deftest;
     ;; future multi-thread version would pop N>1 handles).
     ((spawn :trading::telemetry::Spawn)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::std::telemetry::Service/null-metrics-cadence)))
     ((pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))

     ;; Inner let*: every client-side ReqTx + ack channel lives only
     ;; here. When this scope exits, ReqTx drops → driver's last rx
     ;; disconnects → loop exits → outer (join driver) unblocks.
     ((_inner :())
      (:wat::core::let*
        (((req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((ack-channel :wat::std::telemetry::Service::AckChannel)
          (:wat::kernel::make-bounded-queue :() 1))
         ((ack-tx :wat::std::telemetry::Service::AckTx) (:wat::core::first ack-channel))
         ((ack-rx :wat::std::telemetry::Service::AckRx) (:wat::core::second ack-channel))

         ;; Always-up across 10 windows.
         ((_run-up :())
          (:trading::test::proofs::003::run-thinker-windows
            req-tx ack-tx ack-rx path cfg
            (:trading::sim::always-up-thinker)
            (:trading::sim::cosine-vs-corners-predictor)
            "always-up" "cosine-vs-corners" iso-str))

         ;; SMA-cross across 10 windows — same db, same handle.
         ((_run-sx :())
          (:trading::test::proofs::003::run-thinker-windows
            req-tx ack-tx ack-rx path cfg
            (:trading::sim::sma-cross-thinker)
            (:trading::sim::cosine-vs-corners-predictor)
            "sma-cross" "cosine-vs-corners" iso-str)))
        ()))

     ;; Driver's last ReqRx disconnected when inner let* exited.
     ;; Loop has unwound; this join returns.
     ((_join :()) (:wat::kernel::join driver)))
    ;; Sentinel — the real verification is the SQL above. The
    ;; deftest passes if the run completes without panic.
    (:wat::test::assert-eq true true)))
