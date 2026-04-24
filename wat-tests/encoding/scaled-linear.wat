;; wat-tests/encoding/scaled-linear.wat — Phase 3.3 tests.
;;
;; Tests :trading::encoding::scaled-linear against
;; wat/encoding/scaled-linear.wat. scaled-linear threads a
;; HashMap<String, ScaleTracker> values-up through encoding calls.
;;
;; Arc 003 retrofit: uses arc 031's make-deftest + inherited-config
;; shape. Outer preamble commits dims + capacity-mode once; sandbox
;; inherits. Default-prelude loads scaled-linear + its deps and a
;; tail-recursive helper used by the accumulation test.

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/round.wat")
   (:wat::load-file! "wat/encoding/scale-tracker.wat")
   (:wat::load-file! "wat/encoding/scaled-linear.wat")
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
           (:wat::core::i64::- n 1)))))))

;; ─── First call on empty scales creates a tracker ────────────────

(:deftest :trading::test::encoding::scaled-linear::test-first-call-creates-tracker
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
      1)))

;; ─── Second call on same key updates existing tracker ────────────

(:deftest :trading::test::encoding::scaled-linear::test-second-call-updates-existing-tracker
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
      2)))

;; ─── Distinct keys track independently ───────────────────────────

(:deftest :trading::test::encoding::scaled-linear::test-distinct-keys-independent
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
      3)))

;; ─── Input map unchanged (values-up proof) ───────────────────────

(:deftest :trading::test::encoding::scaled-linear::test-input-map-unchanged
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
      true)))

;; ─── Fact structure (the whole point of scaled-linear) ───────────
;;
;; scaled-linear exists to produce a `Bind(Atom(name), Thermometer(
;; value, -scale, +scale))` fact for downstream encoding. Build the
;; expected fact by hand, assert VSA-level equivalence via
;; coincident? (arc 023).
;;
;; NOTE on value rounding. scaled-linear's AST records
;; `round-to-2(value)` for cache-key stability at the hash/cache
;; layer. At the ALGEBRA layer, two Thermometers differing only in
;; low-decimal value fields produce cosine within noise-floor (VSA
;; considers them indistinguishable by design).

(:deftest :trading::test::encoding::scaled-linear::test-fact-is-bind-of-atom-and-thermometer
  (:wat::core::let*
    (((empty :HashMap<String,trading::encoding::ScaleTracker>)
      (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))
     ;; What scaled-linear produces.
     ((result :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
      (:trading::encoding::scaled-linear "rsi" 0.5 empty))
     ((fact :wat::holon::HolonAST)
      (:wat::core::first result))
     ;; What we EXPECT — reconstruct the tracker's post-update scale
     ;; from scratch, build Bind(Atom, Thermometer) by hand.
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
    (:wat::test::assert-eq
      (:wat::holon::coincident? fact expected)
      true)))

;; ─── Accumulation through scaled-linear (integration convergence) ─
;;
;; scale_tracker's test-converges-to-twice-ema proves convergence at
;; the tracker layer. This proves scaled-linear threads the map
;; correctly across many calls: 10_000 calls with value=0.5, tracker
;; count = 10_000, EMA asymptotically converges to 0.5, scale =
;; round(2·0.5, 2) = 1.00 (same math as the tracker-layer test —
;; proves scaled-linear's map threading doesn't corrupt the tracker).
;;
;; The :test::repeat-scaled-linear helper lives in the deftest
;; factory's default-prelude.
(:deftest :trading::test::encoding::scaled-linear::test-accumulates-across-many-calls
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
      1.0)))
