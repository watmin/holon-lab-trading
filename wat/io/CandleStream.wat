;; :lab::candles::Stream — wat surface over the parquet OHLCV reader.
;;
;; Backed by `:rust::lab::CandleStream` from `src/shims.rs`. The Rust
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
;;   (let* (((s :lab::candles::Stream)
;;           (:lab::candles::open "data/btc_5m_raw.parquet")))
;;     (:wat::core::match (:lab::candles::next! s)
;;                        -> :Option<(i64,f64,f64,f64,f64,f64)>
;;       ((Some row) ...)
;;       (:None ...)))

(:wat::core::use! :rust::lab::CandleStream)

(:wat::core::typealias :lab::candles::Stream :rust::lab::CandleStream)

;; Open a parquet file and return a fresh stream positioned at row 0.
;; Unbounded: emits until the parquet's natural end-of-stream.
(:wat::core::define
  (:lab::candles::open
    (path :String)
    -> :lab::candles::Stream)
  (:rust::lab::CandleStream::open path))

;; Open a parquet file capped at `n` row emissions. After `n`
;; successful `next!` pulls the stream returns `:None` regardless of
;; the parquet's remaining content. Used for cheap bounded test runs
;; (500 / 1000 / 10000 candles) without pulling the full 6-year
;; stream. The reader is still streaming — one record batch at a
;; time from disk; the cap only changes when the producer signals
;; end-of-stream, not how it loads.
(:wat::core::define
  (:lab::candles::open-bounded
    (path :String)
    (n :i64)
    -> :lab::candles::Stream)
  (:rust::lab::CandleStream::open_bounded path n))

;; Pull the next OHLCV row. Returns `(ts_us, open, high, low, close,
;; volume)` wrapped in Option; None at end of stream.
(:wat::core::define
  (:lab::candles::next!
    (s :lab::candles::Stream)
    -> :Option<(i64,f64,f64,f64,f64,f64)>)
  (:rust::lab::CandleStream::next s))

;; Total row count from the parquet metadata. Constant across the
;; stream's lifetime — captured at open.
(:wat::core::define
  (:lab::candles::len
    (s :lab::candles::Stream)
    -> :i64)
  (:rust::lab::CandleStream::len s))
