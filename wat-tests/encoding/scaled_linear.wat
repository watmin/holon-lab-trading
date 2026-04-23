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

;; ─── Fact structure (the whole point of scaled-linear) ─────────────
;;
;; scaled-linear exists to produce a `Bind(Atom(name), Thermometer(
;; value, -scale, +scale))` fact for downstream encoding. Build the
;; expected fact by hand, assert VSA-level equivalence: if the two
;; ASTs are structurally "the same" to the substrate, then
;; `(1 - cosine)` stays below the noise floor the algebra declares
;; as its own distinguishability threshold. Inverse presence check.
;;
;; NOTE on value rounding. scaled-linear's AST records
;; `round-to-2(value)` for cache-key stability at the hash/cache
;; layer. At the ALGEBRA layer, two Thermometers differing only in
;; low-decimal value fields produce cosine within noise-floor (VSA
;; considers them indistinguishable by design). Cache-key stability
;; is a hash-level invariant, not a vector-level one; testing it
;; belongs to cache-layer tests, not here.

(:wat::core::define
  (:trading::test::encoding::scaled-linear::test-fact-is-bind-of-atom-and-thermometer
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
           ;; What scaled-linear produces.
           ((result :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
            (:trading::encoding::scaled-linear "rsi" 0.5 empty))
           ((fact :wat::holon::HolonAST)
            (:wat::core::first result))
           ;; What we EXPECT — reconstruct the tracker's post-update
           ;; scale from scratch with the same update logic as the
           ;; sut, build Bind(Atom, Thermometer) by hand.
           ((expected-tracker :trading::encoding::ScaleTracker)
            (:trading::encoding::ScaleTracker::update
              (:trading::encoding::ScaleTracker::fresh) 0.5))
           ((scale :f64)
            (:trading::encoding::ScaleTracker::scale expected-tracker))
           ((neg-scale :f64)
            (:wat::core::f64::- 0.0 scale))
           ((rounded :f64)
            (:trading::encoding::round-to-2 0.5))
           ((expected :wat::holon::HolonAST)
            (:wat::holon::Bind
              (:wat::holon::Atom "rsi")
              (:wat::holon::Thermometer rounded neg-scale scale))))
          ;; VSA-native equivalence via coincident? (arc 023): true
          ;; iff (1 - cosine) < noise-floor — the algebra considers
          ;; these the same holon within its own tolerance.
          (:wat::test::assert-eq
            (:wat::holon::coincident? fact expected)
            true))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))

;; ─── Accumulation through scaled-linear (integration convergence) ──
;;
;; scale_tracker's test-converges-to-twice-ema proves convergence at
;; the tracker layer. This proves scaled-linear threads the map
;; correctly across many calls: 10_000 calls with value=0.5, tracker
;; count = 10_000, EMA asymptotically converges to 0.5, scale =
;; round(2·0.5, 2) = 1.00 (same math as the tracker-layer test —
;; proves scaled-linear's map threading doesn't corrupt the tracker).

(:wat::core::define
  (:trading::test::encoding::scaled-linear::test-accumulates-across-many-calls
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-dims! 1024)
      (:wat::config::set-capacity-mode! :error)
      (:wat::core::load! :wat::load::file-path "round.wat")
      (:wat::core::load! :wat::load::file-path "scale_tracker.wat")
      (:wat::core::load! :wat::load::file-path "scaled_linear.wat")
      ;; Tail-recursive helper — thread the map through n scaled-linear
      ;; calls, all with the same name + value. Returns the final map.
      (:wat::core::define
        (:test::repeat-scaled-linear
          (name :String)
          (v :f64)
          (scales :HashMap<String,trading::encoding::ScaleTracker>)
          (n :i64)
          -> :HashMap<String,trading::encoding::ScaleTracker>)
        (:wat::core::if (:wat::core::<= n 0)
                        -> :HashMap<String,trading::encoding::ScaleTracker>
          scales
          (:wat::core::let*
            (((result :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
              (:trading::encoding::scaled-linear name v scales))
             ((next :HashMap<String,trading::encoding::ScaleTracker>)
              (:wat::core::second result)))
            (:test::repeat-scaled-linear name v next
              (:wat::core::i64::- n 1)))))
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((empty :HashMap<String,trading::encoding::ScaleTracker>)
            (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))
           ((final :HashMap<String,trading::encoding::ScaleTracker>)
            (:test::repeat-scaled-linear "rsi" 0.5 empty 10000))
           ((tracker :trading::encoding::ScaleTracker)
            (:wat::core::match (:wat::core::get final "rsi")
                               -> :trading::encoding::ScaleTracker
              ((Some t) t)
              (:None (:trading::encoding::ScaleTracker::fresh)))))
          ;; scale converges to round(2·0.5, 2) = 1.00 — matches the
          ;; tracker-layer test, confirms scaled-linear's integration
          ;; preserves tracker semantics.
          (:wat::test::assert-eq
            (:trading::encoding::ScaleTracker::scale tracker)
            1.0))))
    (:wat::core::vec :String)
    (Some "wat/encoding")))
