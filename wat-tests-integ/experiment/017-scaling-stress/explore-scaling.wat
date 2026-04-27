;; wat-tests-integ/experiment/017-scaling-stress/explore-scaling.wat
;;
;; Scaling stress — proof 013.
;;
;; The substrate has CLAIMED scaling properties:
;;   - Per-level Kanerva capacity: sqrt(d) items per Bundle (Chapter 39)
;;   - At d=10000: capacity = 100 items per Bundle
;;   - Beyond capacity: capacity-mode dispatches per arc 019 (default :error)
;;   - Distinct forms produce quasi-orthogonal vectors at any scale
;;
;; Tonight's prior proofs used 3-10 entries per test. None exercised
;; the boundary. This proof verifies the substrate's claimed scaling
;; behavior at the boundary.
;;
;; ─── Scaling dimensions ───────────────────────────────────────
;;
;; T1  WIDTH below capacity (10 atoms)         — Ok, all distinguishable
;; T2  WIDTH at capacity (100 atoms)            — Ok, individual signal
;;                                                degrades to ~floor
;; T3  WIDTH beyond capacity (101 atoms)        — Err(CapacityExceeded)
;; T4  CARDINALITY stress (500 distinct receipts) — round-trip property
;;                                                  holds at scale
;; T5  CARDINALITY rejection (500 distinct pairs) — distinct-form
;;                                                   rejection holds
;; T6  DEPTH stress (5-level nested receipts)   — depth composes
;;                                                cleanly
;;
;; ─── What this verifies ───────────────────────────────────────
;;
;; - Capacity boundary is enforced (T1-T3): substrate says √d and
;;   means it; one-over fires the error mode.
;; - Cardinality scales (T4-T5): the substrate's discrimination
;;   doesn't collapse at 500 distinct items. The chapter 41 word-size
;;   analysis predicts this; this proof exercises it.
;; - Depth composes (T6): nested receipts (receipt of receipt of
;;   receipt of ...) are the Merkle DAG's depth axis; depth-5
;;   verifies cleanly.
;;
;; ─── Honest about runtime ─────────────────────────────────────
;;
;; T4 and T5 do 500 substrate-level operations each. At ~0.2ms per
;; op they take ~100ms each. T1-T3 are ~5ms total. T6 is ~1ms.
;; Total proof runtime: ~250ms. Slow by demo standards; fast for
;; what it verifies.

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


   ;; ─── Form generators ─────────────────────────────────────
   ;;
   ;; gen-form: distinct form per index (same as proof 011).
   ;; gen-atoms-vec: produce N distinct atoms (for capacity tests).
   (:wat::core::define
     (:exp::gen-form (n :i64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "scaling-test")
       (:wat::holon::leaf n)))

   (:wat::core::define
     (:exp::gen-atoms-vec (count :i64) -> :wat::holon::Holons)
     (:wat::core::map (:wat::core::range 1 (:wat::core::+ count 1))
       (:wat::core::lambda ((i :i64) -> :wat::holon::HolonAST)
         (:exp::gen-form i))))


   ;; ─── Property iterators (from proof 011) ────────────────
   (:wat::core::define
     (:exp::all-iterations-pass
       (start :i64) (end :i64)
       (prop :fn(i64)->bool)
       -> :bool)
     (:wat::core::foldl (:wat::core::range start end) true
       (:wat::core::lambda ((acc :bool) (n :i64) -> :bool)
         (:wat::core::and acc (prop n)))))


   ;; ─── Property: receipt round-trip (used in T4) ──────────
   (:wat::core::define
     (:exp::prop-roundtrip (n :i64) -> :bool)
     (:wat::core::let*
       (((form :wat::holon::HolonAST) (:exp::gen-form n))
        ((r :exp::Receipt) (:exp::issue form)))
       (:exp::verify r form)))


   ;; ─── Property: distinct-form rejection (used in T5) ─────
   (:wat::core::define
     (:exp::prop-distinct-rejects (n :i64) -> :bool)
     (:wat::core::let*
       (((form-a :wat::holon::HolonAST) (:exp::gen-form n))
        ((form-b :wat::holon::HolonAST) (:exp::gen-form (:wat::core::+ n 1)))
        ((r :exp::Receipt) (:exp::issue form-a)))
       (:wat::core::not (:exp::verify r form-b))))


   ;; ─── Bundle capacity probe ──────────────────────────────
   ;;
   ;; Returns true iff Bundle of N items returns Ok (under
   ;; current capacity-mode, default :error).
   (:wat::core::define
     (:exp::bundle-fits (n :i64) -> :bool)
     (:wat::core::let*
       (((atoms :wat::holon::Holons) (:exp::gen-atoms-vec n)))
       (:wat::core::match (:wat::holon::Bundle atoms) -> :bool
         ((Ok _) true)
         ((Err _) false))))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — WIDTH below capacity: Bundle of 10 atoms succeeds
;; ════════════════════════════════════════════════════════════════
;;
;; At d=10000, capacity is sqrt(10000) = 100. A bundle of 10 is
;; well under. Should succeed cleanly under the default :error
;; capacity mode.

(:deftest :exp::t1-bundle-below-capacity
  (:wat::core::let*
    (((fits :bool) (:exp::bundle-fits 10)))
    (:wat::test::assert-eq fits true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — WIDTH at capacity: Bundle of 100 atoms succeeds
;; ════════════════════════════════════════════════════════════════
;;
;; At d=10000, capacity is exactly 100. The substrate's boundary
;; condition: 100 fits, 101 doesn't. T2 verifies the upper edge of
;; the legal region.

(:deftest :exp::t2-bundle-at-capacity
  (:wat::core::let*
    (((fits :bool) (:exp::bundle-fits 100)))
    (:wat::test::assert-eq fits true)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — WIDTH beyond capacity: Bundle of 101 atoms returns Err
;; ════════════════════════════════════════════════════════════════
;;
;; One over the boundary. Under default :error capacity-mode the
;; Bundle returns Err(CapacityExceeded). The substrate enforces
;; its own claimed limit; we verify it.

(:deftest :exp::t3-bundle-over-capacity
  (:wat::core::let*
    (((fits :bool) (:exp::bundle-fits 101)))
    (:wat::test::assert-eq fits false)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — CARDINALITY stress: 500 distinct receipts round-trip
;; ════════════════════════════════════════════════════════════════
;;
;; Property test, but at higher iteration count than proof 011's
;; 100. Verifies the round-trip property holds across 500 distinct
;; forms — 5x the prior proof's coverage. If discrimination
;; degraded with more distinct forms in flight, this would surface.
;;
;; Each iteration is independent (no shared bundle); the 500 are
;; just 500 independent (issue, verify) pairs.

(:deftest :exp::t4-cardinality-roundtrip-500
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 501 :exp::prop-roundtrip)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — CARDINALITY rejection: 500 distinct pairs all reject
;; ════════════════════════════════════════════════════════════════
;;
;; The companion to T4. Across 500 (F_n, F_{n+1}) pairs, verify
;; against the wrong form must always return false. Substrate's
;; discrimination at this cardinality is what's being verified.

(:deftest :exp::t5-cardinality-rejection-500
  (:wat::core::let*
    (((all-pass :bool)
      (:exp::all-iterations-pass 1 501 :exp::prop-distinct-rejects)))
    (:wat::test::assert-eq all-pass true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — DEPTH stress: 5-level nested receipts compose
;; ════════════════════════════════════════════════════════════════
;;
;; Build a nested chain: Receipt 1's form references Receipt 2's
;; bytes; Receipt 2's form references Receipt 3's bytes; ... down
;; 5 levels. Each receipt at each level should round-trip
;; correctly. Tests the depth axis of the substrate's Merkle DAG
;; (Chapter 40).
;;
;; Note: this isn't a chain in the cryptographic sense (each
;; receipt's V depends on the next, not the previous). But it
;; verifies that nested receipt structures encode and verify
;; consistently across depth.

(:deftest :exp::t6-depth-stress-5-levels
  (:wat::core::let*
    (;; Innermost form (level 5).
     ((form-5 :wat::holon::HolonAST) (:exp::gen-form 5))
     ((r-5 :exp::Receipt) (:exp::issue form-5))

     ;; Level 4 references level 5's form structurally.
     ((form-4 :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "level-4") form-5))
     ((r-4 :exp::Receipt) (:exp::issue form-4))

     ;; Level 3 references level 4.
     ((form-3 :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "level-3") form-4))
     ((r-3 :exp::Receipt) (:exp::issue form-3))

     ;; Level 2 references level 3.
     ((form-2 :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "level-2") form-3))
     ((r-2 :exp::Receipt) (:exp::issue form-2))

     ;; Level 1 — outermost, references level 2.
     ((form-1 :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "level-1") form-2))
     ((r-1 :exp::Receipt) (:exp::issue form-1))

     ;; Each receipt at each level verifies against its own form.
     ((v1 :bool) (:exp::verify r-1 form-1))
     ((v2 :bool) (:exp::verify r-2 form-2))
     ((v3 :bool) (:exp::verify r-3 form-3))
     ((v4 :bool) (:exp::verify r-4 form-4))
     ((v5 :bool) (:exp::verify r-5 form-5))

     ((all-verify :bool)
      (:wat::core::and (:wat::core::and (:wat::core::and v1 v2)
                                          (:wat::core::and v3 v4))
                       v5))

     ((_1 :()) (:wat::test::assert-eq v1 true))
     ((_2 :()) (:wat::test::assert-eq v2 true))
     ((_3 :()) (:wat::test::assert-eq v3 true))
     ((_4 :()) (:wat::test::assert-eq v4 true))
     ((_5 :()) (:wat::test::assert-eq v5 true)))
    (:wat::test::assert-eq all-verify true)))
