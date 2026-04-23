;; wat-tests/encoding/scale_tracker.wat — Phase 3.2 tests.
;;
;; Tests :trading::encoding::ScaleTracker (::fresh, ::update, ::scale)
;; against its source at wat/encoding/scale_tracker.wat. Each test-*
;; define opens its own run-sandboxed-ast with scope = "wat/encoding"
;; so the inner sandbox can `(load!)` the real module; deftest's
;; :None-scope hermetic sandbox (arc 007/017) doesn't see outer
;; file's (load!)'d defines, so we bypass deftest and wire the
;; sandbox manually.
;;
;; Scope `"wat/encoding"` resolves against cargo test's cwd
;; (CARGO_MANIFEST_DIR, per Cargo's integration-test convention).

(:wat::config::set-dims! 1024)
(:wat::config::set-capacity-mode! :error)

;; ─── ::fresh — zero-tracker invariants ────────────────────────────────

(:wat::core::define
  (:trading::test::encoding::scale-tracker::test-fresh-has-zero-count
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load-file! "scale_tracker.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::fresh)))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker/count t)
            0))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

(:wat::core::define
  (:trading::test::encoding::scale-tracker::test-fresh-has-zero-ema
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load-file! "scale_tracker.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::fresh)))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker/ema-abs t)
            0.0))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── ::update — count + EMA progression ──────────────────────────────

(:wat::core::define
  (:trading::test::encoding::scale-tracker::test-update-increments-count
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load-file! "scale_tracker.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t0 :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::fresh))
           ((t1 :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::update t0 0.5))
           ((t2 :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::update t1 0.5)))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker/count t2)
            2))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; Negative values are absolute-value'd before EMA blend; feeding +0.5
;; and -0.5 should produce the same EMA as feeding +0.5 twice.
(:wat::core::define
  (:trading::test::encoding::scale-tracker::test-update-takes-abs-of-value
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load-file! "scale_tracker.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((pos :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::update
              (:trading::encoding::ScaleTracker::fresh) 0.5))
           ((neg :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::update
              (:trading::encoding::ScaleTracker::fresh) -0.5)))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker/ema-abs pos)
            (:trading::encoding::ScaleTracker/ema-abs neg)))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── ::scale — floor + convergence ───────────────────────────────────

;; Fresh tracker has EMA 0 → scale = max(0, 0.001) rounded = 0.0
;; (the 0.001 floor rounds away at 2 decimals).
(:wat::core::define
  (:trading::test::encoding::scale-tracker::test-scale-of-fresh-is-zero
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load-file! "scale_tracker.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::fresh)))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker::scale t)
            0.0))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; Convergence — feeding a constant value many times drives EMA→|v|
;; and scale→2·|v| (floored + rounded). At d=1024, alpha=1/max(count,100)
;; means the first 99 iterations blend at 0.01 reaching EMA≈0.315;
;; subsequent iterations use alpha=1/count, which gives the closed-form
;; EMA_K = 0.315·(99/K) + 0.5·(K-99)/K for K≥100. At K=10_000 with v=0.5
;; that's EMA≈0.4982 → scale 0.9964 → rounded to 2 = 1.00. Proof that
;; the tracker converges to the expected long-run scale.
(:wat::core::define
  (:trading::test::encoding::scale-tracker::test-converges-to-twice-ema
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load-file! "scale_tracker.wat")
      ;; Tail-recursive helper: feed value `v` into tracker `t` exactly
      ;; `n` times. Values-up — no mutation. TCO (arc 003) keeps the
      ;; Rust stack constant regardless of n.
      (:wat::core::define
        (:test::repeat-update
          (t :trading::encoding::ScaleTracker)
          (v :f64)
          (n :i64)
          -> :trading::encoding::ScaleTracker)
        (:wat::core::if (:wat::core::<= n 0)
                        -> :trading::encoding::ScaleTracker
          t
          (:test::repeat-update
            (:trading::encoding::ScaleTracker::update t v)
            v
            (:wat::core::i64::- n 1))))
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((fresh :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::fresh))
           ((trained :trading::encoding::ScaleTracker)
            (:test::repeat-update fresh 0.5 10000)))
          ;; EMA converges to 0.5 → scale = round(2·0.5, 2) = 1.00
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker::scale trained)
            1.0))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))
