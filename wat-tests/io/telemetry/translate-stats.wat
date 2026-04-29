;; wat-tests/io/telemetry/translate-stats.wat — pure-data test for
;; the stats-translator. Build a known Stats, run through the
;; translator with a frozen-clock maker, assert the resulting vec
;; has the expected metric rows.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/io/telemetry/maker.wat")
   (:wat::load-file! "wat/io/telemetry/translate-stats.wat")
   ;; Frozen clock helper — same as maker.wat's tests.
   (:wat::core::define
     (:trading::test::io::telemetry::frozen-clock
       (millis :i64)
       -> :fn(())->wat::time::Instant)
     (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
       (:wat::time::at-millis millis)))))


;; ─── translate-stats produces three Telemetry entries ────────────

(:deftest :trading::test::io::telemetry::translate-stats::test-three-entries
  (:wat::core::let*
    (((maker :trading::telemetry::EntryMaker)
      (:trading::telemetry::maker/make
        (:trading::test::io::telemetry::frozen-clock 1000)))
     ((stats :wat::std::telemetry::Service::Stats)
      (:wat::std::telemetry::Service::Stats/new 7 42 13))
     ((rows :Vec<trading::log::LogEntry>)
      (:trading::telemetry::translate-stats maker stats))
     ((n :i64) (:wat::core::length rows)))
    (:wat::test::assert-eq n 3)))


;; ─── translator carries the input counter values ────────────────

(:deftest :trading::test::io::telemetry::translate-stats::test-batches-value
  (:wat::core::let*
    (((maker :trading::telemetry::EntryMaker)
      (:trading::telemetry::maker/make
        (:trading::test::io::telemetry::frozen-clock 1000)))
     ((stats :wat::std::telemetry::Service::Stats)
      (:wat::std::telemetry::Service::Stats/new 7 42 13))
     ((rows :Vec<trading::log::LogEntry>)
      (:trading::telemetry::translate-stats maker stats))
     ;; First row is "batches" — extract its metric-value.
     ((first-opt :Option<trading::log::LogEntry>)
      (:wat::core::first rows))
     ((value :f64)
      (:wat::core::match first-opt -> :f64
        ((Some entry)
          (:wat::core::match entry -> :f64
            ((:trading::log::LogEntry::Telemetry
                _ns _id _dim _ts _name v _unit) v)
            ((:trading::log::LogEntry::PaperResolved
                _ _ _ _ _ _ _ _ _ _) -1.0)))
        (:None -1.0))))
    (:wat::test::assert-eq value 7.0)))
