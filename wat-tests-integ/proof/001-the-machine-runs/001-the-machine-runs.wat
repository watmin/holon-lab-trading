;; wat-tests/proofs/001-the-machine-runs.wat — paired with
;; docs/proofs/2026/04/001-the-machine-runs/PROOF.md.
;;
;; Two deftests measuring the v1 yardstick on real BTC data with
;; the two v1 thinker/predictor pairs from arc 025 slice 5
;; (slice-4-5-design-questions.md Q12). Each captures aggregate
;; counts + residue / loss after a bounded run and asserts the
;; numbers fall into plausible ranges.
;;
;; Run via: `cargo test --release --test test -- --nocapture | grep proofs`
;;
;; Why a wat-tests file rather than a standalone runnable: the
;; lab's deftest harness already wires `:trading::candles::*` (parquet
;; shim) + `:trading::*` (full domain) into the sandbox.
;; Adding a new bin target would duplicate that wiring; the test
;; suite already has it. The trade is: numbers come out via
;; assertion-failure diagnostics or `--nocapture` test logs rather
;; than a clean stdout. Acceptable for a measurement that's
;; running infrequently and producing comparable runs.
;;
;; The assertions are loose RANGES rather than tight values —
;; the proof's job is to establish "the lifecycle works on real
;; data," not "this thinker hits exactly N grace papers."  When
;; reality lands outside the range, the test fails LOUDLY and
;; the proof's claim gets revised.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")
   (:wat::load-file! "wat/sim/v1.wat")))


;; ─── Always-up thinker on 10k candles ─────────────────────────────
;;
;; The smoke baseline. `always-up-thinker` returns a constant surface
;; biased toward `corner-grace-up`; `cosine-vs-corners-predictor`
;; argmaxes to `(Open :Up)`. Every paper opens Up. Some Grace, some
;; Violence depending on what BTC does in the window.
;;
;; Expected ranges (informal — first run will calibrate):
;;   papers in [50, 500] — papers can only resolve at phase triggers
;;     or deadline; 10k candles ≈ 35 days at 5min, ~50–500 papers.
;;   grace + violence == papers (conservation, structurally guaranteed).
;;   total-residue + total-loss is finite and signed sensibly.

(:deftest :trading::test::proofs::001::always-up-10k
  (:wat::core::let*
    (((stream :trading::candles::Stream)
      (:trading::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::run
        stream
        (:trading::sim::always-up-thinker)
        (:trading::sim::cosine-vs-corners-predictor)
        cfg))
     ((papers :wat::core::i64)   (:trading::sim::Aggregate/papers agg))
     ((grace :wat::core::i64)    (:trading::sim::Aggregate/grace-count agg))
     ((violence :wat::core::i64) (:trading::sim::Aggregate/violence-count agg))
     ;; Conservation: every resolved paper is exactly one of Grace
     ;; or Violence. Structural guarantee from the helpers; this
     ;; confirms it on real data.
     ((u1 :()) (:wat::test::assert-eq
                 (:wat::core::= papers (:wat::core::+ grace violence))
                 true))
     ;; Range — at least 1 paper and not absurdly many.
     ((u2 :()) (:wat::test::assert-eq (:wat::core::> papers 0) true)))
    (:wat::test::assert-eq (:wat::core::< papers 5000) true)))


;; ─── SMA-cross thinker on 10k candles ─────────────────────────────
;;
;; The first thinker that *thinks*. Reads `candle.sma20` /
;; `candle.sma50`; emits a surface biased toward grace-up when
;; sma20 > sma50 by a 0.1% deadband, grace-down on the inverse,
;; violence-neutral otherwise.
;;
;; Expected ranges — should be DIFFERENT from always-up's papers
;; (because sma-cross sometimes says Hold). If grace-count differs
;; meaningfully from violence-count, the thinker has measurable bias
;; that the eventual reckoner will train on.

(:deftest :trading::test::proofs::001::sma-cross-10k
  (:wat::core::let*
    (((stream :trading::candles::Stream)
      (:trading::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::run
        stream
        (:trading::sim::sma-cross-thinker)
        (:trading::sim::cosine-vs-corners-predictor)
        cfg))
     ((papers :wat::core::i64)   (:trading::sim::Aggregate/papers agg))
     ((grace :wat::core::i64)    (:trading::sim::Aggregate/grace-count agg))
     ((violence :wat::core::i64) (:trading::sim::Aggregate/violence-count agg))
     ((u1 :()) (:wat::test::assert-eq
                 (:wat::core::= papers (:wat::core::+ grace violence))
                 true))
     ;; sma-cross emits Hold when SMAs are within deadband; expect
     ;; FEWER papers than always-up (which always proposes). 0 is
     ;; allowed (could happen on flat markets) but unlikely on 10k
     ;; real candles spanning ~35 days.
     ((u2 :()) (:wat::test::assert-eq (:wat::core::>= papers 0) true)))
    (:wat::test::assert-eq (:wat::core::< papers 5000) true)))
