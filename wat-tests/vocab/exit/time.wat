;; wat-tests/vocab/exit/time.wat — Lab arc 002.
;;
;; Four outstanding tests for :trading::vocab::exit::time — each
;; anchored in the module's specific claim:
;;
;; 1. encode-exit-time-holons returns 2 holons (hour + day-of-week).
;; 2. fact[0] structurally coincides with hand-built
;;    Bind(Atom("hour"), Circular(14, 24.0)).
;; 3. fact[1] structurally coincides with hand-built
;;    Bind(Atom("day-of-week"), Circular(3, 7.0)).
;; 4. Rounding quantizes cache keys — candles with hour=14.7 and
;;    hour=15.1 produce coincident hour-holons (both round to 15).
;;
;; Uses :wat::test::make-deftest per arc 031's inherited-config
;; shape — the outer preamble commits dims + capacity-mode once;
;; every deftest below inherits through the sandbox-config-inherit
;; path. One-load default-prelude pulls the full dep chain via the
;; types' self-loads.

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/exit/time.wat")))

;; ─── 1. encode-exit-time-holons returns 2 ──────────────────────────

(:deftest :trading::test::vocab::exit::time::test-encode-exit-time-holons-count
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((holons :wat::holon::Holons)
      (:trading::vocab::exit::time::encode-exit-time-holons t)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      2)))

;; ─── 2. hour fact coincides with hand-built shape ─────────────────

(:deftest :trading::test::vocab::exit::time::test-hour-fact-shape
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((holons :wat::holon::Holons)
      (:trading::vocab::exit::time::encode-exit-time-holons t))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "hour")
        (:wat::holon::Circular 14.0 24.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. day-of-week fact coincides with hand-built shape ──────────

(:deftest :trading::test::vocab::exit::time::test-dow-fact-shape
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((holons :wat::holon::Holons)
      (:trading::vocab::exit::time::encode-exit-time-holons t))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "day-of-week")
        (:wat::holon::Circular 3.0 7.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. rounding quantizes cache keys ─────────────────────────────

(:deftest :trading::test::vocab::exit::time::test-close-hours-share-cache-key
  (:wat::core::let*
    (((t-a :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.7 3.0 15.0 6.0))
     ((t-b :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 15.1 3.0 15.0 6.0))
     ((holons-a :wat::holon::Holons)
      (:trading::vocab::exit::time::encode-exit-time-holons t-a))
     ((holons-b :wat::holon::Holons)
      (:trading::vocab::exit::time::encode-exit-time-holons t-b))
     ((hour-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-a 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((hour-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-b 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? hour-a hour-b)
      true)))
