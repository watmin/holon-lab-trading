;; wat-tests/io/telemetry/maker.wat — tests for the entry-maker
;; factory. Pure data — frozen clock, construct entries, assert
;; field round-trip.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/io/telemetry/maker.wat")
   ;; Helper — frozen clock at a fixed millis-since-epoch.
   (:wat::core::define
     (:trading::test::io::telemetry::frozen-clock
       (millis :i64)
       -> :fn(())->wat::time::Instant)
     (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
       (:wat::time::at-millis millis)))))


;; ─── Test 1: now-millis returns the frozen instant ───────────────

(:deftest :trading::test::io::telemetry::maker::test-frozen-clock
  (:wat::core::let*
    (((maker :trading::telemetry::EntryMaker)
      (:trading::telemetry::maker/make
        (:trading::test::io::telemetry::frozen-clock 1730000000000)))
     ((ts :i64) (:trading::telemetry::EntryMaker/now-millis maker)))
    (:wat::test::assert-eq ts 1730000000000)))


;; ─── Test 2: metric helper stamps the timestamp from the clock ────

(:deftest :trading::test::io::telemetry::maker::test-metric-stamps-timestamp
  (:wat::core::let*
    (((maker :trading::telemetry::EntryMaker)
      (:trading::telemetry::maker/make
        (:trading::test::io::telemetry::frozen-clock 42000)))
     ((entry :trading::log::LogEntry)
      (:trading::telemetry::EntryMaker/metric maker
        "cache" "test" "{}"
        "lookups" 7.0 "Count"))
     ((ts-from-entry :i64)
      (:wat::core::match entry -> :i64
        ((:trading::log::LogEntry::Telemetry
            _ns _id _dim ts _name _value _unit) ts)
        ((:trading::log::LogEntry::PaperResolved
            _ _ _ _ _ _ _ _ _ _) -1))))
    (:wat::test::assert-eq ts-from-entry 42000)))


;; ─── Test 3: paper-resolved is unchanged from raw constructor ────

(:deftest :trading::test::io::telemetry::maker::test-paper-resolved-roundtrip
  (:wat::core::let*
    (((maker :trading::telemetry::EntryMaker)
      (:trading::telemetry::maker/make
        (:trading::test::io::telemetry::frozen-clock 0)))
     ((via-helper :trading::log::LogEntry)
      (:trading::telemetry::EntryMaker/paper-resolved maker
        "run-1" "always-up" "cosine"
        7 "Up" 100 388 "Grace" 0.04 0.0))
     ((via-raw :trading::log::LogEntry)
      (:trading::log::LogEntry::PaperResolved
        "run-1" "always-up" "cosine"
        7 "Up" 100 388 "Grace" 0.04 0.0)))
    (:wat::test::assert-eq via-helper via-raw)))
