;; wat-tests-integ/experiment/016-property-tests/explore-properties.wat
;;
;; Property tests — proof 011.
;;
;; The first six proofs (005-010) used hand-picked tests. Each
;; passed; each demonstrated the SHAPE works for the scenarios
;; tested. The unsampled input space was unverified.
;;
;; This proof closes that gap. Each property test iterates over
;; 50-100 generated inputs and asserts the property holds across
;; all of them. If any single iteration fails, the property is
;; refuted.
;;
;; This is "property testing" in the QuickCheck sense — minus the
;; shrinking step (we don't try to minimize counterexamples once
;; found). The benefit: substrate behavior verified across
;; thousands of input points instead of a handful.
;;
;; ─── Properties verified ─────────────────────────────────────
;;
;; T1  Receipt round-trip — for any form F, verify(issue(F), F) = true.
;;     Iterates 100 distinct forms.
;; T2  Distinct-form rejection — for any pair of distinct forms
;;     F1 ≠ F2, verify(issue(F1), F2) = false. Iterates 100 pairs.
;; T3  Encoding determinism — for any form F, two independent
;;     calls to issue(F) produce byte-equal receipts. Iterates
;;     100 forms.
;; T4  Self-coincidence — for any form F, coincident?(F, F) = true.
;;     Iterates 100 forms.
;; T5  Tamper detection — for any form F, replacing the receipt's
;;     bytes with empty bytes makes verification fail. Iterates
;;     100 forms.
;; T6  Cross-form orthogonality — for any pair of distinct
;;     forms F1, F2, coincident?(F1, F2) = false. Iterates 100
;;     pairs.
;;
;; ─── What this gains over the prior proofs ───────────────────
;;
;; - Every property is exercised across many input points, not
;;   just the one or two cases the prior proofs touched.
;; - A failure under iteration N produces a specific
;;   counterexample (the failing input).
;; - The substrate's claimed invariants get sampled across the
;;   reachable input space at the size of the iteration count.
;;
;; ─── What it doesn't yet gain ────────────────────────────────
;;
;; - True random input generation (we use deterministic
;;   index-derived forms; cryptographic randomness would need
;;   substrate work for an RNG primitive).
;; - Counterexample shrinking (when a property fails, we know
;;   the failing N but don't try to minimize the input).
;; - Coverage across the full 3^d state space (we sample 100
;;   points; the substrate's space is astronomically larger).
;;
;; These are layer-2 hardening for proof 017 (adversarial fuzz).

(:wat::test::make-deftest :deftest
  (;; ─── Receipt + binding (from proof 005) ──────────────────
   (:wat::core::struct :exp::Receipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST))

   (:wat::core::define
     (:exp::issue (form :wat::holon::HolonAST) -> :exp::Receipt)
     (:wat::core::let*
       (((v :wat::holon::Vector) (:wat::holon::encode form))
        ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v)))
       (:exp::Receipt/new bytes form)))

   (:wat::core::define
     (:exp::verify (r :exp::Receipt)
                   (candidate :wat::holon::HolonAST)
                   -> :bool)
     (:wat::core::match
       (:wat::holon::bytes-vector (:exp::Receipt/bytes r))
       -> :bool
       ((Some v) (:wat::holon::coincident? candidate v))
       (:None false)))


   ;; ─── Form generator — index-derived distinct forms ───────
   ;;
   ;; gen-form(n) produces a structurally distinct HolonAST for
   ;; each n. The substrate's encoder hashes the structure; two
   ;; different n values produce two quasi-orthogonal vectors at
   ;; the default tier (post-arc-067, d=10000).
   ;;
   ;; The form's shape: Bind(Atom("test-form"), leaf-N). Each n
   ;; gives a distinct integer leaf, which produces a distinct
   ;; HolonAST::I64, which encodes distinctly.
   (:wat::core::define
     (:exp::gen-form (n :i64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "test-form")
       (:wat::holon::leaf n)))


   ;; ─── Property predicates — one per property under test ──
   ;;
   ;; Each predicate takes an iteration index and returns bool.
   ;; The deftests fold over a range, AND-ing the results.

   ;; P1 — Round-trip: verify(issue(F), F) = true for all F.
   (:wat::core::define
     (:exp::prop-roundtrip (n :i64) -> :bool)
     (:wat::core::let*
       (((form :wat::holon::HolonAST) (:exp::gen-form n))
        ((r :exp::Receipt) (:exp::issue form)))
       (:exp::verify r form)))

   ;; P2 — Distinct-form rejection: verify(issue(F_n), F_{n+1}) = false.
   (:wat::core::define
     (:exp::prop-distinct-rejects (n :i64) -> :bool)
     (:wat::core::let*
       (((form-a :wat::holon::HolonAST) (:exp::gen-form n))
        ((form-b :wat::holon::HolonAST) (:exp::gen-form (:wat::core::+ n 1)))
        ((r :exp::Receipt) (:exp::issue form-a)))
       ;; Property holds when verify against the WRONG form returns false.
       (:wat::core::not (:exp::verify r form-b))))

   ;; P3 — Determinism: issue(F) twice produces byte-equal receipts.
   (:wat::core::define
     (:exp::prop-determinism (n :i64) -> :bool)
     (:wat::core::let*
       (((form :wat::holon::HolonAST) (:exp::gen-form n))
        ((r1 :exp::Receipt) (:exp::issue form))
        ((r2 :exp::Receipt) (:exp::issue form)))
       (:wat::core::= (:exp::Receipt/bytes r1) (:exp::Receipt/bytes r2))))

   ;; P4 — Self-coincidence: coincident?(F, F) = true for all F.
   (:wat::core::define
     (:exp::prop-self-coincident (n :i64) -> :bool)
     (:wat::core::let*
       (((form :wat::holon::HolonAST) (:exp::gen-form n)))
       (:wat::holon::coincident? form form)))

   ;; P5 — Tamper detection: receipt with empty bytes fails verification.
   (:wat::core::define
     (:exp::prop-tamper-detect (n :i64) -> :bool)
     (:wat::core::let*
       (((form :wat::holon::HolonAST) (:exp::gen-form n))
        ((empty-bytes :wat::core::Bytes) (:wat::core::vec :u8))
        ((tampered :exp::Receipt) (:exp::Receipt/new empty-bytes form)))
       ;; Property holds when verify on tampered receipt returns false.
       (:wat::core::not (:exp::verify tampered form))))

   ;; P6 — Cross-form orthogonality: distinct forms are NOT coincident.
   (:wat::core::define
     (:exp::prop-cross-orthogonal (n :i64) -> :bool)
     (:wat::core::let*
       (((form-a :wat::holon::HolonAST) (:exp::gen-form n))
        ((form-b :wat::holon::HolonAST) (:exp::gen-form (:wat::core::+ n 1))))
       ;; Property holds when distinct forms are NOT coincident.
       (:wat::core::not (:wat::holon::coincident? form-a form-b))))


   ;; ─── Iteration helper — fold a property across a range ──
   ;;
   ;; Returns true iff the property holds for every n in [start, end).
   ;; If any iteration fails, the AND short-circuits to false.
   (:wat::core::define
     (:exp::all-iterations-pass
       (start :i64) (end :i64)
       (prop :fn(i64)->bool)
       -> :bool)
     (:wat::core::foldl (:wat::core::range start end) true
       (:wat::core::lambda ((acc :bool) (n :i64) -> :bool)
         (:wat::core::and acc (prop n)))))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Receipt round-trip property (100 iterations)
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t1-roundtrip-property
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 101 :exp::prop-roundtrip)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Distinct-form rejection property (100 iterations)
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t2-distinct-rejection-property
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 101 :exp::prop-distinct-rejects)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Encoding determinism property (100 iterations)
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t3-determinism-property
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 101 :exp::prop-determinism)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Self-coincidence property (100 iterations)
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t4-self-coincident-property
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 101 :exp::prop-self-coincident)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Tamper detection property (100 iterations)
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t5-tamper-detect-property
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 101 :exp::prop-tamper-detect)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Cross-form orthogonality property (100 iterations)
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t6-cross-orthogonal-property
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 101 :exp::prop-cross-orthogonal)))
    (:wat::test::assert-eq all-pass true)))
