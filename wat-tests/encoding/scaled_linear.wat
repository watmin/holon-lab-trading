;; wat-tests/encoding/scaled_linear.wat — Phase 3.3 tests.
;;
;; Tests :trading::encoding::scaled-linear against wat/encoding/
;; scaled_linear.wat. Each test runs in its own hermetic sandbox
;; with scope = "wat/encoding" so the inner sandbox can (load!)
;; the module via its sibling path (matches wat-tests/encoding/
;; scale_tracker.wat's established pattern).

(:wat::config::set-dims! 1024)
(:wat::config::set-capacity-mode! :error)

;; ─── First call on empty scales creates a tracker ───────────────────

(:wat::core::define
  (:trading::test::encoding::scaled-linear::test-first-call-creates-tracker
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load! :wat::load::file-path "round.wat")
      (:wat::core::load! :wat::load::file-path "scale_tracker.wat")
      (:wat::core::load! :wat::load::file-path "scaled_linear.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((empty :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))
           ((result :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 empty))
           ((updated :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::second result))
           ((tracker :trading::encoding::ScaleTracker)
            (:wat::core::match (:wat::core::get updated "rsi")
                               -> :trading::encoding::ScaleTracker
              ((Some t) t)
              (:None (:trading::encoding::ScaleTracker::fresh)))))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker/count tracker)
            1))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Second call on same key updates existing tracker ──────────────

(:wat::core::define
  (:trading::test::encoding::scaled-linear::test-second-call-updates-existing-tracker
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load! :wat::load::file-path "round.wat")
      (:wat::core::load! :wat::load::file-path "scale_tracker.wat")
      (:wat::core::load! :wat::load::file-path "scaled_linear.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((empty :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))
           ((r1 :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 empty))
           ((s1 :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::second r1))
           ((r2 :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 s1))
           ((s2 :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::second r2))
           ((tracker :trading::encoding::ScaleTracker)
            (:wat::core::match (:wat::core::get s2 "rsi")
                               -> :trading::encoding::ScaleTracker
              ((Some t) t)
              (:None (:trading::encoding::ScaleTracker::fresh)))))
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker/count tracker)
            2))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Distinct keys track independently ─────────────────────────────

(:wat::core::define
  (:trading::test::encoding::scaled-linear::test-distinct-keys-independent
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load! :wat::load::file-path "round.wat")
      (:wat::core::load! :wat::load::file-path "scale_tracker.wat")
      (:wat::core::load! :wat::load::file-path "scaled_linear.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((s0 :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))
           ;; Update rsi twice, stoch-k once.
           ((r1 :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 s0))
           ((s1 :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::second r1))
           ((r2 :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 s1))
           ((s2 :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::second r2))
           ((r3 :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "stoch-k" 0.5 s2))
           ((s3 :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::second r3))
           ;; rsi should have count=2, stoch-k count=1.
           ((rsi :trading::encoding::ScaleTracker)
            (:wat::core::match (:wat::core::get s3 "rsi")
                               -> :trading::encoding::ScaleTracker
              ((Some t) t)
              (:None (:trading::encoding::ScaleTracker::fresh))))
           ((stoch :trading::encoding::ScaleTracker)
            (:wat::core::match (:wat::core::get s3 "stoch-k")
                               -> :trading::encoding::ScaleTracker
              ((Some t) t)
              (:None (:trading::encoding::ScaleTracker::fresh)))))
          (:wat::test::assert-eq
            (:wat::core::i64::+
              (:trading::encoding::ScaleTracker/count rsi)
              (:trading::encoding::ScaleTracker/count stoch))
            3))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Input map unchanged (values-up proof) ─────────────────────────

(:wat::core::define
  (:trading::test::encoding::scaled-linear::test-input-map-unchanged
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load! :wat::load::file-path "round.wat")
      (:wat::core::load! :wat::load::file-path "scale_tracker.wat")
      (:wat::core::load! :wat::load::file-path "scaled_linear.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((empty :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))
           ((_ :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 empty)))
          ;; original `empty` must still be empty — :None lookup.
          (:wat::test::assert-eq
            (:wat::core::match (:wat::core::get empty "rsi")
                               -> :bool
              ((Some _) false)
              (:None    true))
            true))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))
