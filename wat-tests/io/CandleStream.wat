;; wat-tests/io/CandleStream.wat — smoke test for the parquet shim.
;;
;; End-to-end exercise of the `:rust::trading::CandleStream` dispatch:
;; open the 6-year BTC parquet, check the metadata length, pull the
;; first three rows, assert the timestamps and price are in the
;; expected range. Confirms the shim composes with wat correctly.
;;
;; If this test passes, the harness work can begin — the source of
;; OHLCV is wired.
;;
;; Pattern: direct `:wat::test::deftest` with empty prelude. The
;; shim's `wat_sources()` auto-registers `wat/io/CandleStream.wat` via
;; `deps: [shims]` in `tests/test.rs`, so the `:trading::candles::*` forms
;; are already in scope at startup. Arc 054's idempotent redeclaration
;; handles disk-and-baked dual-source cleanly. Arc 055's recursive
;; patterns let `(Some (ts o h l c v))` destructure Option<Tuple> in
;; one form.

;; ─── deftest: open + len ──────────────────────────────────────────
(:wat::test::deftest :trading::test::io::candle-stream::test-len-meets-floor
  ()
  (:wat::core::let*
    (((s :trading::candles::Stream)
      (:trading::candles::open "data/btc_5m_raw.parquet"))
     ((n :i64) (:trading::candles::len s)))
    ;; The 6-year 5-min BTC raw parquet was 652_608 rows the day this
    ;; shim landed. Append-only data file → length only grows. Assert
    ;; the floor we saw, not the exact value.
    (:wat::test::assert-eq (:wat::core::i64::>= n 652608) true)))

;; ─── deftest: first row's timestamp + close ───────────────────────
(:wat::test::deftest :trading::test::io::candle-stream::test-first-row
  ()
  (:wat::core::let*
    (((s :trading::candles::Stream)
      (:trading::candles::open "data/btc_5m_raw.parquet"))
     ((row :Option<(i64,f64,f64,f64,f64,f64)>) (:trading::candles::next! s)))
    (:wat::core::match row -> :()
      ((Some (ts open high low close volume))
        (:wat::core::let*
          ;; First row of btc_5m_raw.parquet: 2019-01-01 00:00:00 UTC
          ;; → microseconds since epoch: 1546300800000000.
          (((_ :()) (:wat::test::assert-eq ts 1546300800000000)))
          ;; BTC opened 2019 around $3700. Bracket loosely.
          (:wat::test::assert-eq
            (:wat::core::and
              (:wat::core::f64::> close 3000.0)
              (:wat::core::f64::< close 4500.0))
            true)))
      (:None
        (:wat::kernel::assertion-failed!
          "stream returned None on first row" :None :None)))))

;; ─── deftest: pull three rows, check monotone timestamps ──────────
(:wat::test::deftest :trading::test::io::candle-stream::test-monotone-ts
  ()
  (:wat::core::let*
    (((s :trading::candles::Stream)
      (:trading::candles::open "data/btc_5m_raw.parquet"))
     ((r0 :Option<(i64,f64,f64,f64,f64,f64)>) (:trading::candles::next! s))
     ((r1 :Option<(i64,f64,f64,f64,f64,f64)>) (:trading::candles::next! s))
     ((r2 :Option<(i64,f64,f64,f64,f64,f64)>) (:trading::candles::next! s)))
    (:wat::core::match r0 -> :()
      ((Some (ta _ _ _ _ _))
        (:wat::core::match r1 -> :()
          ((Some (tb _ _ _ _ _))
            (:wat::core::match r2 -> :()
              ((Some (tc _ _ _ _ _))
                (:wat::core::let*
                  (((_ :()) (:wat::test::assert-eq (:wat::core::i64::< ta tb) true)))
                  (:wat::test::assert-eq (:wat::core::i64::< tb tc) true)))
              (:None (:wat::kernel::assertion-failed! "third row was None" :None :None))))
          (:None (:wat::kernel::assertion-failed! "second row was None" :None :None))))
      (:None (:wat::kernel::assertion-failed! "first row was None" :None :None)))))
