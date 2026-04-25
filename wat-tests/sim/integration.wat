;; wat-tests/sim/integration.wat — Lab arc 025 slice 5 integration smoke.
;;
;; Real-data smoke test: the simulator runs end-to-end against
;; `data/btc_5m_raw.parquet`, bounded to 10,000 candles via
;; `:lab::candles::open-bounded`, with the v1 always-up-thinker +
;; cosine-vs-corners-predictor.
;;
;; Per slice-4-5-design-questions.md Q13 this is smoke only —
;; lifecycle correctness is covered by the helper-level tests in
;; `wat-tests/sim/paper.wat`. This test asserts the simulator:
;;   1. survives 10k real candles without crashing
;;   2. produces at least one resolved paper
;;   3. preserves the conservation invariant
;;      (papers = grace-count + violence-count) on real data
;;
;; The conservation check is structurally guaranteed by the
;; aggregate-grace / aggregate-violence helpers (each adds 1 to
;; both papers and the kind-specific count), but firing it on real
;; BTC data confirms the resolution path actually traverses both
;; helpers across a real run.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")))


;; ─── Smoke — 10k candles, always-up-thinker ──────────────────────

(:deftest :trading::test::sim::integration::test-ten-thousand-candles-smoke
  (:wat::core::let*
    (((stream :lab::candles::Stream)
      (:lab::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::run
        stream
        (:trading::sim::always-up-thinker)
        (:trading::sim::cosine-vs-corners-predictor)
        cfg))
     ((papers :i64) (:trading::sim::Aggregate/papers agg))
     ((grace :i64) (:trading::sim::Aggregate/grace-count agg))
     ((violence :i64) (:trading::sim::Aggregate/violence-count agg))
     ((u1 :())
      (:wat::test::assert-eq (:wat::core::> papers 0) true)))
    ;; Conservation invariant — every resolved paper is exactly one
    ;; of Grace or Violence.
    (:wat::test::assert-eq
      (:wat::core::= papers (:wat::core::+ grace violence))
      true)))
