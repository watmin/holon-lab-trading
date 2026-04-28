;; wat-tests/cache/L1.wat — tests for :trading::cache::L1.
;;
;; L1 is the per-thinker dual coordinate cache. Two HologramLRU
;; instances threaded through the thinker's loop. Tests verify:
;; construction, put/get round-trip on each cache, fuzzy hits, cell
;; isolation, len.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/cache/L1.wat")))

;; ─── make: empty L1 has zero entries across both caches ─────────

(:deftest :trading::test::cache::L1::test-make-empty
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((n :i64) (:trading::cache::L1/len l1)))
    (:wat::test::assert-eq n 0)))

;; ─── put-next + get-next: round-trip on the next-cache ──────────

(:deftest :trading::test::cache::L1::test-put-get-next
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((next :wat::holon::HolonAST) (:wat::holon::leaf :next))
     ((_ :()) (:trading::cache::L1/put-next l1 5.0 form next))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::L1/get-next l1 5.0 form))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found next)))

;; ─── put-terminal + get-terminal: round-trip on the terminal-cache

(:deftest :trading::test::cache::L1::test-put-get-terminal
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((terminal :wat::holon::HolonAST) (:wat::holon::leaf :terminal))
     ((_ :()) (:trading::cache::L1/put-terminal l1 5.0 form terminal))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::L1/get-terminal l1 5.0 form))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found terminal)))

;; ─── two caches are independent ─────────────────────────────────
;;
;; A put on next-cache must NOT make the same key visible in
;; terminal-cache, and vice versa. The two HologramLRUs are
;; structurally separate.

(:deftest :trading::test::cache::L1::test-caches-are-independent
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((next :wat::holon::HolonAST) (:wat::holon::leaf :next))
     ;; Put only on next-cache.
     ((_ :()) (:trading::cache::L1/put-next l1 5.0 form next))
     ;; Lookup on terminal-cache must miss.
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::L1/get-terminal l1 5.0 form))
     ((is-none :bool)
      (:wat::core::match got -> :bool
        ((Some _) false)
        (:None    true))))
    (:wat::test::assert-eq is-none true)))

;; ─── len counts both caches ─────────────────────────────────────

(:deftest :trading::test::cache::L1::test-len-counts-both
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((k1 :wat::holon::HolonAST) (:wat::holon::leaf :alpha))
     ((v1 :wat::holon::HolonAST) (:wat::holon::leaf :av))
     ((k2 :wat::holon::HolonAST) (:wat::holon::leaf :beta))
     ((v2 :wat::holon::HolonAST) (:wat::holon::leaf :bv))
     ((_ :()) (:trading::cache::L1/put-next l1 5.0 k1 v1))
     ((_ :()) (:trading::cache::L1/put-terminal l1 5.0 k2 v2))
     ((n :i64) (:trading::cache::L1/len l1)))
    (:wat::test::assert-eq n 2)))

;; ─── lookup: terminal hit on direct form ────────────────────────

(:deftest :trading::test::cache::L1::test-lookup-terminal-direct
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((terminal :wat::holon::HolonAST) (:wat::holon::leaf :answer))
     ((_ :()) (:trading::cache::L1/put-terminal l1 5.0 form terminal))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::L1/lookup l1 5.0 form))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found terminal)))

;; ─── lookup: chain through next-cache to terminal-cache ─────────
;;
;; pre-seed: form → next, next → terminal. lookup(form) follows
;; next, then hits terminal. Tests the recursive chain-walking
;; without involving :wat::eval::walk.

(:deftest :trading::test::cache::L1::test-lookup-chain-via-next
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((next :wat::holon::HolonAST) (:wat::holon::leaf :next))
     ((terminal :wat::holon::HolonAST) (:wat::holon::leaf :terminal))
     ((_ :()) (:trading::cache::L1/put-next l1 5.0 form next))
     ((_ :()) (:trading::cache::L1/put-terminal l1 5.0 next terminal))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::L1/lookup l1 5.0 form))
     ((found :wat::holon::HolonAST)
      (:wat::core::match got -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::leaf :unreachable)))))
    (:wat::test::assert-eq found terminal)))

;; ─── lookup: empty caches return None ───────────────────────────

(:deftest :trading::test::cache::L1::test-lookup-empty-returns-none
  (:wat::core::let*
    (((l1 :trading::cache::L1) (:trading::cache::L1/make 10000 16))
     ((form :wat::holon::HolonAST) (:wat::holon::leaf :form))
     ((got :Option<wat::holon::HolonAST>)
      (:trading::cache::L1/lookup l1 5.0 form))
     ((is-none :bool)
      (:wat::core::match got -> :bool
        ((Some _) false)
        (:None    true))))
    (:wat::test::assert-eq is-none true)))
