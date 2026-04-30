;; :trading::candles::Stream — wat surface over the parquet OHLCV reader.
;;
;; Backed by `:rust::trading::CandleStream` from `src/shims.rs`. The Rust
;; shim holds an `arrow::ParquetRecordBatchReader` and a one-batch
;; row buffer; each `next` returns the next row or `None` at end of
;; stream. Thread-owned scope — one stream per program thread, no
;; Mutex.
;;
;; Mirrors wat-lru's surface shape (typealias + thin define wrappers
;; over :rust::*).
;;
;; Schema requirement: parquet has columns `ts` (Timestamp µs or ms),
;; `open` `high` `low` `close` `volume` (all f64). The shim
;; normalizes ms timestamps to µs at emit time.
;;
;; Usage:
;;   (let* (((s :trading::candles::Stream)
;;           (:trading::candles::open "data/btc_5m_raw.parquet")))
;;     (:wat::core::match (:trading::candles::next! s)
;;                        -> :Option<trading::candles::Ohlcv>
;;       ((Some row) ...)
;;       (:None ...)))

(:wat::core::use! :rust::trading::CandleStream)

(:wat::core::typealias :trading::candles::Stream :rust::trading::CandleStream)

;; OHLCV row shape — what `next!` emits per pull. Aliased so every
;; consumer signature stops carrying the bare 6-tuple.
;; (ts-us :wat::core::i64, open :wat::core::f64, high :wat::core::f64, low :wat::core::f64, close :wat::core::f64, volume :wat::core::f64)
;;
;; The name `Candle` is taken — `:trading::types::Candle` is the
;; richer struct used downstream (with computed fields). `Ohlcv` is
;; the bare-tuple shape the parquet reader emits.
(:wat::core::typealias :trading::candles::Ohlcv
  :(i64,f64,f64,f64,f64,f64))

;; Open a parquet file and return a fresh stream positioned at row 0.
;; Unbounded: emits until the parquet's natural end-of-stream.
(:wat::core::define
  (:trading::candles::open
    (path :wat::core::String)
    -> :trading::candles::Stream)
  (:rust::trading::CandleStream::open path))

;; Open a parquet file capped at `n` row emissions. After `n`
;; successful `next!` pulls the stream returns `:None` regardless of
;; the parquet's remaining content. Used for cheap bounded test runs
;; (500 / 1000 / 10000 candles) without pulling the full 6-year
;; stream. The reader is still streaming — one record batch at a
;; time from disk; the cap only changes when the producer signals
;; end-of-stream, not how it loads.
(:wat::core::define
  (:trading::candles::open-bounded
    (path :wat::core::String)
    (n :wat::core::i64)
    -> :trading::candles::Stream)
  (:rust::trading::CandleStream::open_bounded path n))

;; Pull the next OHLCV row. Returns `(ts_us, open, high, low, close,
;; volume)` wrapped in Option; None at end of stream.
(:wat::core::define
  (:trading::candles::next!
    (s :trading::candles::Stream)
    -> :Option<trading::candles::Ohlcv>)
  (:rust::trading::CandleStream::next s))

;; Total row count from the parquet metadata. Constant across the
;; stream's lifetime — captured at open.
(:wat::core::define
  (:trading::candles::len
    (s :trading::candles::Stream)
    -> :wat::core::i64)
  (:rust::trading::CandleStream::len s))
