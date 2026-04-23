;; wat-tests/vocab/shared/time.wat — Lab arc 001 Slice 2.
;;
;; Outstanding tests for :trading::vocab::shared::time — six claims
;; anchored in the module's responsibility:
;;
;; 1. leaves count — encode-time-facts returns 5 facts.
;; 2. composition count — time-facts returns 8 facts (5 leaves + 3 pairs).
;; 3. leaf shape — fact[1] structurally coincides with a hand-built
;;    Bind(Atom("hour"), Circular(rounded-hour, 24.0)).
;; 4. composition shape — fact[5] (minute × hour) structurally
;;    coincides with hand-built Bind(minute-bind, hour-bind).
;; 5. rounding quantizes cache keys — candles with hour=14.7 and
;;    hour=15.1 produce coincident hour-facts (both round to 15).
;; 6. opposite clock points differ — candles with hour=6 and hour=18
;;    produce NON-coincident hour-facts (Circular's angular encoding
;;    distinguishes opposite points on the 24-period sphere).
;;
;; Uses :wat::test::make-deftest to configure :deftest once —
;; :error mode, dims 1024, plus the single load that pulls the entire
;; dep chain via the types' self-loads. Every test below is just
;; name + body. (Arcs 029 + 030 shipped the nested-quasiquote and
;; macroexpand substrate that made this shape work.)

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

;; Configure :deftest for this file. The load chain:
;;   wat/vocab/shared/time.wat → wat/types/candle.wat
;;     → wat/types/ohlcv.wat + wat/types/pivot.wat
;; resolves to one parse per file via canonical-path dedup
;; (arc 027 slice 1).
(:wat::test::make-deftest :deftest :error 1024
  ((:wat::load-file! "wat/vocab/shared/time.wat")))

;; ─── 1. encode-time-facts returns 5 ───────────────────────────────

(:deftest :trading::test::vocab::shared::time::test-encode-time-facts-count
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((facts :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::encode-time-facts t)))
    (:wat::test::assert-eq
      (:wat::core::length facts)
      5)))

;; ─── 2. time-facts returns 8 ──────────────────────────────────────

(:deftest :trading::test::vocab::shared::time::test-time-facts-count
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((facts :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::time-facts t)))
    (:wat::test::assert-eq
      (:wat::core::length facts)
      8)))

;; ─── 3. hour fact coincides with hand-built shape ─────────────────

(:deftest :trading::test::vocab::shared::time::test-hour-fact-shape
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((facts :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::encode-time-facts t))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get facts 1) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "hour")
        (:wat::holon::Circular 14.0 24.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. minute × hour composition shape ───────────────────────────

(:deftest :trading::test::vocab::shared::time::test-minute-x-hour-composition
  (:wat::core::let*
    (((t :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
     ((facts :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::time-facts t))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get facts 5) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((minute-bind :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "minute")
        (:wat::holon::Circular 30.0 60.0)))
     ((hour-bind :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "hour")
        (:wat::holon::Circular 14.0 24.0)))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind minute-bind hour-bind)))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. rounding quantizes cache keys ─────────────────────────────

(:deftest :trading::test::vocab::shared::time::test-close-hours-share-cache-key
  (:wat::core::let*
    (((t-a :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 14.7 3.0 15.0 6.0))
     ((t-b :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 15.1 3.0 15.0 6.0))
     ((facts-a :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::encode-time-facts t-a))
     ((facts-b :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::encode-time-facts t-b))
     ((hour-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get facts-a 1) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((hour-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get facts-b 1) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? hour-a hour-b)
      true)))

;; ─── 6. opposite clock points differ ──────────────────────────────

(:deftest :trading::test::vocab::shared::time::test-opposite-hours-differ
  (:wat::core::let*
    (((t-morning :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 6.0 3.0 15.0 6.0))
     ((t-evening :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 30.0 18.0 3.0 15.0 6.0))
     ((facts-morning :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::encode-time-facts t-morning))
     ((facts-evening :Vec<wat::holon::HolonAST>)
      (:trading::vocab::shared::time::encode-time-facts t-evening))
     ((hour-morning :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get facts-morning 1) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((hour-evening :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get facts-evening 1) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? hour-morning hour-evening)
      false)))
