;; wat-tests/encoding/rhythm.wat — Phase 3.4 tests.
;;
;; Tests :trading::encoding::rhythm::indicator-rhythm against
;; wat/encoding/rhythm.wat.
;;
;; Arc 003 retrofit: uses arc 031's make-deftest + inherited-config
;; shape. Outer preamble commits dims + capacity-mode once; sandbox
;; inherits.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/rhythm.wat")))

;; ─── Deterministic — same input, same output ─────────────────────
;;
;; Algebra-native equivalence via coincident? (arc 023): two
;; identical rhythms encode to coincident holons.

(:deftest :trading::test::encoding::rhythm::test-deterministic
  (:wat::core::let*
    (((values :Vec<f64>)
      (:wat::core::vec :wat::core::f64 0.45 0.48 0.55 0.62 0.68 0.66 0.63))
     ((r1 :wat::holon::BundleResult)
      (:trading::encoding::rhythm::indicator-rhythm
        "rsi" values 0.0 100.0 10.0))
     ((r2 :wat::holon::BundleResult)
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
      true)))

;; ─── Different atoms → near-orthogonal ───────────────────────────
;;
;; rsi rhythm and macd rhythm over SAME values should NOT coincide
;; — the atom name distinguishes them at the bind-chain root.

(:deftest :trading::test::encoding::rhythm::test-different-atoms-not-coincident
  (:wat::core::let*
    (((values :Vec<f64>)
      (:wat::core::vec :wat::core::f64 0.45 0.48 0.55 0.62 0.68 0.66 0.63))
     ((r-rsi :wat::holon::BundleResult)
      (:trading::encoding::rhythm::indicator-rhythm
        "rsi" values 0.0 100.0 10.0))
     ((r-macd :wat::holon::BundleResult)
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
      false)))

;; ─── Too-few values returns an atom'd empty Bundle ───────────────
;;
;; Archive's <4 values fallback. The fact should still be Bind-
;; shaped at the atom root; the inner is an empty Bundle.

(:deftest :trading::test::encoding::rhythm::test-few-values-still-succeeds
  (:wat::core::let*
    (((values :Vec<f64>) (:wat::core::vec :wat::core::f64 0.5 0.6))
     ((r :wat::holon::BundleResult)
      (:trading::encoding::rhythm::indicator-rhythm
        "rsi" values 0.0 100.0 10.0)))
    (:wat::test::assert-eq
      (:wat::core::match r -> :wat::core::bool
        ((Ok _)  true)
        ((Err _) false))
      true)))

;; ─── Different values under same atom → not coincident ──────────
;;
;; Atom name alone doesn't determine the rhythm — values are part
;; of the signature. Same "rsi" atom over two disjoint movement
;; patterns (rising vs falling) must produce distinguishable holons.

(:deftest :trading::test::encoding::rhythm::test-different-values-not-coincident
  ;; Thermometer contrast matters — at vmin=0/vmax=1, values 0.1
  ;; and 0.9 occupy opposite ends of the range, producing
  ;; distinguishable bit patterns. Narrow windows inside a wide
  ;; range (e.g., 0..100 with values near 0.5) don't guarantee
  ;; this distinction at d=1024 within the coincident threshold.
  (:wat::core::let*
    (((rising :Vec<f64>)
      (:wat::core::vec :wat::core::f64 0.1 0.2 0.3 0.4 0.5 0.6 0.7))
     ((falling :Vec<f64>)
      (:wat::core::vec :wat::core::f64 0.9 0.8 0.7 0.6 0.5 0.4 0.3))
     ((r-up :wat::holon::BundleResult)
      (:trading::encoding::rhythm::indicator-rhythm
        "rsi" rising 0.0 1.0 0.5))
     ((r-dn :wat::holon::BundleResult)
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
      false)))

;; ─── Budget truncation — prefix values beyond max-holons are dropped
;;
;; Post-arc-067 the default dim is 10000; budget = sqrt(10000) = 100;
;; max-holons = 103. The test demonstrates that a long sequence and
;; its last-N suffix (both larger than max-holons) produce coincident
;; rhythms — the prefix beyond max-holons gets trimmed identically by
;; step 1 of the algorithm, leaving identical max-holons-suffixes
;; that bundle to the same point.
;;
;; The data is generated programmatically via `range` + `map` instead
;; of hand-listed: long = 200 values (0.005, 0.010, ..., 1.000), tail
;; = last 150 of long (positions 50..200 → values 0.255 onward). Both
;; > max-holons; both share their final max-holons values position-
;; for-position. The test stays honest at any default dim with
;; max-holons ∈ [1, 149].

(:deftest :trading::test::encoding::rhythm::test-prefix-beyond-budget-is-dropped
  (:wat::core::let*
    ;; values-from-step n start step → n-long Vec<f64> with values
    ;; start, start+step, start+2*step, ...
    ;; (Inline lambda; deftest helpers must live in prelude. The
    ;; deftest's body produces the data via two map calls below.)
    (((long :Vec<f64>)
      (:wat::core::map (:wat::core::range 1 201)
        (:wat::core::lambda ((i :wat::core::i64) -> :wat::core::f64)
          (:wat::core::* 0.005 (:wat::core::i64::to-f64 i)))))
     ((tail :Vec<f64>)
      (:wat::core::map (:wat::core::range 51 201)
        (:wat::core::lambda ((i :wat::core::i64) -> :wat::core::f64)
          (:wat::core::* 0.005 (:wat::core::i64::to-f64 i)))))
     ((r-long :wat::holon::BundleResult)
      (:trading::encoding::rhythm::indicator-rhythm
        "rsi" long 0.0 1.0 0.1))
     ((r-tail :wat::holon::BundleResult)
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
      true)))

;; ─── Short-window shape is Bind(Atom(name), empty-Bundle) ───────
;;
;; Archive asserts ast.kind = Bundle(empty) directly; the wat port
;; wraps that empty Bundle in a Bind to atom(name) so the rhythm
;; still has an identity at the atom root. Algebra-native check:
;; the short-window result coincides with a hand-built reference
;; holon of exactly that shape.

(:deftest :trading::test::encoding::rhythm::test-short-window-shape
  ;; Per arc 057, the <4 fallback uses a named keyword sentinel
  ;; (`:short-window-sentinel`) instead of `(quote ())` — empty
  ;; lists lower to zero-vector empty Bundles, which die under
  ;; Bind. Hand-build the matching shape with the same sentinel
  ;; and confirm geometric coincidence.
  (:wat::core::let*
    (((values :Vec<f64>) (:wat::core::vec :wat::core::f64 0.5 0.6))
     ((r :wat::holon::BundleResult)
      (:trading::encoding::rhythm::indicator-rhythm
        "rsi" values 0.0 100.0 10.0))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match r -> :wat::holon::HolonAST
        ((Ok h)  h)
        ((Err _) (:wat::holon::Atom "unreachable"))))
     ((r-sentinel :wat::holon::BundleResult)
      (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Atom (:wat::core::quote :short-window-sentinel)))))
     ((sentinel :wat::holon::HolonAST)
      (:wat::core::match r-sentinel -> :wat::holon::HolonAST
        ((Ok h)  h)
        ((Err _) (:wat::holon::Atom "unreachable"))))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "rsi") sentinel)))
    (:wat::test::assert-coincident actual expected)))
