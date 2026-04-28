;; wat-tests/cache/walker.wat — :trading::cache::resolve tests.
;;
;; Slice 1 minimal walker: cache-first, walk on miss, no recording
;; (visitor returns Continue). Tests verify the structural shape:
;;
;;   - terminal-cache hit returns directly (no walk)
;;   - chain via next-cache works through L1/lookup
;;   - cache miss: walk-on-already-terminal returns Some
;;
;; Recording into L1 (the "walk fills cache" property) ships in a
;; separate slice once the visit-fn handles each StepResult variant.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/cache/L1.wat")
   (:wat::load-file! "wat/cache/walker.wat")))

;; ─── Terminal hit returns the cached terminal (no walk) ─────────

(:deftest :trading::test::cache::walker::test-terminal-hit
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((terminal :wat::holon::HolonAST) (:wat::holon::leaf :answer))
     ((_ :()) (:trading::cache::L1/put-terminal l1 5.0 form terminal))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::resolve form 5.0 l1))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found terminal)))

;; ─── Chain via next-cache to terminal-cache ─────────────────────

(:deftest :trading::test::cache::walker::test-chain-via-next
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((next :wat::holon::HolonAST) (:wat::holon::leaf :next))
     ((terminal :wat::holon::HolonAST) (:wat::holon::leaf :terminal))
     ((_ :()) (:trading::cache::L1/put-next l1 5.0 form next))
     ((_ :()) (:trading::cache::L1/put-terminal l1 5.0 next terminal))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::resolve form 5.0 l1))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found terminal)))

;; ─── Walk on miss: already-terminal form returns Some ────────────
;;
;; Empty L1; resolve a leaf keyword. The walker hits AlreadyTerminal
;; on the first step; Ok((leaf, l1)) returns from walk; resolve
;; unwraps to Some(leaf).

(:deftest :trading::test::cache::walker::test-walk-on-already-terminal
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :alpha))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::resolve form 5.0 l1))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found form)))
