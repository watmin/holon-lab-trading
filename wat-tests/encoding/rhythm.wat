;; wat-tests/encoding/rhythm.wat — Phase 3.4 tests.
;;
;; Tests :trading::encoding::rhythm::indicator-rhythm. Uses the
;; manual run-sandboxed-ast pattern (scope = "wat/encoding") so
;; the inner sandbox loads the module. Matches scale_tracker +
;; scaled_linear test structure.

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

;; ─── Deterministic — same input, same output ─────────────────────
;;
;; Algebra-native equivalence via coincident? (arc 023): two
;; identical rhythms encode to coincident holons.

(:wat::core::define
  (:trading::test::encoding::rhythm::test-deterministic
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "rhythm.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((values :Vec<f64>)
            (:wat::core::vec :f64 0.45 0.48 0.55 0.62 0.68 0.66 0.63))
           ((r1 :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" values 0.0 100.0 10.0))
           ((r2 :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" values 0.0 100.0 10.0))
           ((h1 :wat::holon::HolonAST)
            (:wat::core::match r1 -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable"))))
           ((h2 :wat::holon::HolonAST)
            (:wat::core::match r2 -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable")))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? h1 h2)
            true))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Different atoms → near-orthogonal ───────────────────────────
;;
;; rsi rhythm and macd rhythm over SAME values should NOT coincide
;; — the atom name distinguishes them at the bind-chain root.

(:wat::core::define
  (:trading::test::encoding::rhythm::test-different-atoms-not-coincident
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "rhythm.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((values :Vec<f64>)
            (:wat::core::vec :f64 0.45 0.48 0.55 0.62 0.68 0.66 0.63))
           ((r-rsi :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" values 0.0 100.0 10.0))
           ((r-macd :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "macd" values 0.0 100.0 10.0))
           ((h-rsi :wat::holon::HolonAST)
            (:wat::core::match r-rsi -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable"))))
           ((h-macd :wat::holon::HolonAST)
            (:wat::core::match r-macd -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable")))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? h-rsi h-macd)
            false))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Too-few values returns an atom'd empty Bundle ───────────────
;;
;; Archive's <4 values fallback. The fact should still be Bind-
;; shaped at the atom root; the inner is an empty Bundle.

(:wat::core::define
  (:trading::test::encoding::rhythm::test-few-values-still-succeeds
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "rhythm.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((values :Vec<f64>) (:wat::core::vec :f64 0.5 0.6))
           ((r :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" values 0.0 100.0 10.0)))
          (:wat::test::assert-eq
            (:wat::core::match r -> :bool
              ((Ok _)  true)
              ((Err _) false))
            true))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Different values under same atom → not coincident ──────────
;;
;; Atom name alone doesn't determine the rhythm — values are part
;; of the signature. Same "rsi" atom over two disjoint movement
;; patterns (rising vs falling) must produce distinguishable holons.

(:wat::core::define
  (:trading::test::encoding::rhythm::test-different-values-not-coincident
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "rhythm.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        ;; Thermometer contrast matters — at vmin=0/vmax=1, values
        ;; 0.1 and 0.9 occupy opposite ends of the range, producing
        ;; distinguishable bit patterns. Narrow windows inside a wide
        ;; range (e.g., 0..100 with values near 0.5) don't guarantee
        ;; this distinction at d=1024 within the coincident threshold.
        (:wat::core::let*
          (((rising :Vec<f64>)
            (:wat::core::vec :f64 0.1 0.2 0.3 0.4 0.5 0.6 0.7))
           ((falling :Vec<f64>)
            (:wat::core::vec :f64 0.9 0.8 0.7 0.6 0.5 0.4 0.3))
           ((r-up :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" rising 0.0 1.0 0.5))
           ((r-dn :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" falling 0.0 1.0 0.5))
           ((h-up :wat::holon::HolonAST)
            (:wat::core::match r-up -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable"))))
           ((h-dn :wat::holon::HolonAST)
            (:wat::core::match r-dn -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable")))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? h-up h-dn)
            false))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Budget truncation — prefix values beyond max-facts are dropped
;;
;; At d=1024, budget = sqrt(1024) = 32, max-facts = 35. A long
;; window and the last-35-element slice of it should produce
;; coincident rhythms — the prefix was trimmed identically by step
;; 1 of the algorithm.

(:wat::core::define
  (:trading::test::encoding::rhythm::test-prefix-beyond-budget-is-dropped
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "rhythm.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          ;; long = 50 arbitrary but deterministic values
          ;; tail = last 35 of long (35 = budget + 3 at d=1024)
          (((long :Vec<f64>)
            (:wat::core::vec :f64
              ;; prefix (15 values) — should be dropped
              0.01 0.02 0.03 0.04 0.05 0.06 0.07 0.08 0.09 0.10
              0.11 0.12 0.13 0.14 0.15
              ;; tail (35 values) — drives the output
              0.20 0.22 0.24 0.26 0.28 0.30 0.32 0.34 0.36 0.38
              0.40 0.42 0.44 0.46 0.48 0.50 0.52 0.54 0.56 0.58
              0.60 0.62 0.64 0.66 0.68 0.70 0.72 0.74 0.76 0.78
              0.80 0.82 0.84 0.86 0.88))
           ((tail :Vec<f64>)
            (:wat::core::vec :f64
              0.20 0.22 0.24 0.26 0.28 0.30 0.32 0.34 0.36 0.38
              0.40 0.42 0.44 0.46 0.48 0.50 0.52 0.54 0.56 0.58
              0.60 0.62 0.64 0.66 0.68 0.70 0.72 0.74 0.76 0.78
              0.80 0.82 0.84 0.86 0.88))
           ((r-long :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" long 0.0 1.0 0.1))
           ((r-tail :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" tail 0.0 1.0 0.1))
           ((h-long :wat::holon::HolonAST)
            (:wat::core::match r-long -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable"))))
           ((h-tail :wat::holon::HolonAST)
            (:wat::core::match r-tail -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable")))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? h-long h-tail)
            true))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Short-window shape is Bind(Atom(name), empty-Bundle) ───────
;;
;; Archive asserts ast.kind = Bundle(empty) directly; the wat port
;; wraps that empty Bundle in a Bind to atom(name) so the rhythm
;; still has an identity at the atom root. Algebra-native check:
;; the short-window result coincides with a hand-built reference
;; holon of exactly that shape.

(:wat::core::define
  (:trading::test::encoding::rhythm::test-short-window-shape
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "rhythm.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        ;; The <4 fallback uses the Little Schemer's '() lifted into an
        ;; Atom and bundled as a single-element sentinel (see
        ;; rhythm.wat). Hand-build the matching shape and confirm
        ;; structural coincidence.
        (:wat::core::let*
          (((values :Vec<f64>) (:wat::core::vec :f64 0.5 0.6))
           ((r :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:trading::encoding::rhythm::indicator-rhythm
              "rsi" values 0.0 100.0 10.0))
           ((actual :wat::holon::HolonAST)
            (:wat::core::match r -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable"))))
           ((r-sentinel :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
            (:wat::holon::Bundle
              (:wat::core::vec :wat::holon::HolonAST
                (:wat::holon::Atom (:wat::core::quote ())))))
           ((sentinel :wat::holon::HolonAST)
            (:wat::core::match r-sentinel -> :wat::holon::HolonAST
              ((Ok h)  h)
              ((Err _) (:wat::holon::Atom "unreachable"))))
           ((expected :wat::holon::HolonAST)
            (:wat::holon::Bind (:wat::holon::Atom "rsi") sentinel)))
          (:wat::test::assert-eq
            (:wat::holon::coincident? actual expected)
            true))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))
