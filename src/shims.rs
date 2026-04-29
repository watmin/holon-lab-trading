//! In-crate Rust→wat dispatch surface. The two-function contract
//! (`wat_sources` + `register`) lets the lab pass `[shims]` into
//! `wat::main!` exactly the same way external crates pass themselves.
//! Pattern: wat-rs's USER-GUIDE §"Add a `src/shim.rs` module".
//!
//! Shipped surfaces:
//!
//! - `:rust::trading::CandleStream` — a thread-owned parquet OHLCV reader.
//!   Expressed at the wat surface as `:trading::candles::Stream` via
//!   `wat/io/CandleStream.wat`. Mirrors the archived
//!   `archived/pre-wat-native/src/domain/candle_stream.rs` reader,
//!   cut down to a 6-field tuple emit (asset metadata is wat-side
//!   configuration, not a parquet payload).
//! Sqlite persistence is provided by the `wat-telemetry-sqlite`
//! substrate crate (arcs 083 / 084 / 085 + arc 091 slice 6) —
//! `:wat::telemetry::Sqlite/auto-spawn` derives schemas + INSERTs
//! from the substrate's `:wat::telemetry::Event` enum (Metric +
//! Log variants). The lab no longer ships its own LogEntry decl
//! or shim.

use std::path::Path;

use arrow::array::{Array, Float64Array, TimestampMicrosecondArray, TimestampMillisecondArray};
use parquet::arrow::arrow_reader::{ParquetRecordBatchReader, ParquetRecordBatchReaderBuilder};
use wat::rust_deps::RustDepsBuilder;
use wat::WatSource;

use wat_macros::wat_dispatch;

/// One row of OHLCV pulled from parquet. Held in the buffer between
/// `next` calls. Emitted to wat as a 6-tuple `(ts_us, o, h, l, c, v)`.
#[derive(Clone, Copy)]
struct Row {
    ts_us: i64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,
}

/// `:rust::trading::CandleStream` — eager-batch parquet OHLCV iterator.
///
/// Holds one record-batch's worth of rows in `buffer`; refills from
/// the underlying reader on exhaust. `pos` is the read cursor inside
/// the current buffer.
///
/// `total` is captured once at open and exposed via `len`. It comes
/// from the parquet file's metadata (no I/O cost beyond the open).
pub struct WatCandleStream {
    reader: ParquetRecordBatchReader,
    buffer: Vec<Row>,
    pos: usize,
    total: i64,
    /// Remaining rows the stream is allowed to emit. Decrements on
    /// each `next`; once it hits 0 the stream returns `None` even
    /// if the parquet has more rows. `open` sets this to `i64::MAX`
    /// (effectively unbounded); `open_bounded(path, n)` sets it to
    /// `n` so callers can run "first N candles" tests cheaply
    /// without consuming the full 6-year stream.
    remaining: i64,
}

#[wat_dispatch(
    path = ":rust::trading::CandleStream",
    scope = "thread_owned"
)]
impl WatCandleStream {
    /// `:rust::trading::CandleStream::open path` — open a parquet file by
    /// path. Schema requirement: columns `ts` (Timestamp µs or ms),
    /// `open`, `high`, `low`, `close`, `volume` (all f64). Panics if
    /// the file is missing or the schema doesn't match — same posture
    /// as wat-lru's `new`: input-validation panics surface to
    /// startup integration tests.
    pub fn open(path: String) -> Self {
        let p = Path::new(&path);
        let total = {
            let f = std::fs::File::open(p).unwrap_or_else(|e| {
                panic!(":rust::trading::CandleStream::open: cannot open {path}: {e}")
            });
            let builder = ParquetRecordBatchReaderBuilder::try_new(f).unwrap_or_else(|e| {
                panic!(":rust::trading::CandleStream::open: not a parquet file ({path}): {e}")
            });
            builder.metadata().file_metadata().num_rows()
        };
        let f = std::fs::File::open(p).unwrap_or_else(|e| {
            panic!(":rust::trading::CandleStream::open: cannot reopen {path}: {e}")
        });
        let reader = ParquetRecordBatchReaderBuilder::try_new(f)
            .unwrap_or_else(|e| {
                panic!(":rust::trading::CandleStream::open: builder failed ({path}): {e}")
            })
            .build()
            .unwrap_or_else(|e| {
                panic!(":rust::trading::CandleStream::open: build failed ({path}): {e}")
            });
        Self {
            reader,
            buffer: Vec::new(),
            pos: 0,
            total,
            remaining: i64::MAX,
        }
    }

    /// `:rust::trading::CandleStream::open-bounded path n` — open a parquet
    /// file capped at `n` row emissions. After `n` successful `next`
    /// pulls, subsequent `next` calls return `None` regardless of the
    /// parquet's remaining content. Used by tests + cheap exploratory
    /// runs (500 / 1000 / 10000 candles) to avoid pulling the full
    /// 6-year stream.
    ///
    /// `n <= 0` produces a stream that emits nothing — also useful
    /// for harness sanity checks.
    pub fn open_bounded(path: String, n: i64) -> Self {
        let mut s = Self::open(path);
        s.remaining = n.max(0);
        s
    }

    /// `:rust::trading::CandleStream::next stream` — pull the next OHLCV row.
    /// Returns `(ts_us, open, high, low, close, volume)` wrapped in
    /// `Option`; `None` when the stream is exhausted OR when the
    /// `open_bounded` row-cap has been reached.
    pub fn next(&mut self) -> Option<(i64, f64, f64, f64, f64, f64)> {
        if self.remaining <= 0 {
            return None;
        }
        if self.pos >= self.buffer.len() && !self.fill_buffer() {
            return None;
        }
        let r = self.buffer[self.pos];
        self.pos += 1;
        self.remaining -= 1;
        Some((r.ts_us, r.open, r.high, r.low, r.close, r.volume))
    }

    /// `:rust::trading::CandleStream::len stream` — total row count from the
    /// parquet metadata. Captured at open; constant across the stream's
    /// lifetime.
    pub fn len(&self) -> i64 {
        self.total
    }
}

impl WatCandleStream {
    /// Pull the next non-empty record batch into `buffer`. Returns
    /// `false` on end-of-stream. Timestamp normalization: emit i64
    /// microseconds regardless of the parquet's stored unit (µs
    /// passes through, ms multiplies by 1_000).
    fn fill_buffer(&mut self) -> bool {
        loop {
            match self.reader.next() {
                Some(Ok(batch)) => {
                    if batch.num_rows() == 0 {
                        continue;
                    }
                    let ts_col = batch
                        .column_by_name("ts")
                        .expect(":rust::trading::CandleStream: parquet missing 'ts' column");
                    let open_col = batch.column_by_name("open").expect("missing 'open'");
                    let high_col = batch.column_by_name("high").expect("missing 'high'");
                    let low_col = batch.column_by_name("low").expect("missing 'low'");
                    let close_col = batch.column_by_name("close").expect("missing 'close'");
                    let vol_col = batch.column_by_name("volume").expect("missing 'volume'");

                    let ts_us: Vec<i64> = if let Some(arr) =
                        ts_col.as_any().downcast_ref::<TimestampMicrosecondArray>()
                    {
                        (0..arr.len()).map(|i| arr.value(i)).collect()
                    } else if let Some(arr) =
                        ts_col.as_any().downcast_ref::<TimestampMillisecondArray>()
                    {
                        (0..arr.len()).map(|i| arr.value(i) * 1_000).collect()
                    } else {
                        panic!(
                            ":rust::trading::CandleStream: 'ts' column must be Timestamp(µs) or Timestamp(ms)"
                        );
                    };

                    let opens = open_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("'open' must be f64");
                    let highs = high_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("'high' must be f64");
                    let lows = low_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("'low' must be f64");
                    let closes = close_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("'close' must be f64");
                    let volumes = vol_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("'volume' must be f64");

                    self.buffer.clear();
                    self.pos = 0;
                    for i in 0..batch.num_rows() {
                        self.buffer.push(Row {
                            ts_us: ts_us[i],
                            open: opens.value(i),
                            high: highs.value(i),
                            low: lows.value(i),
                            close: closes.value(i),
                            volume: volumes.value(i),
                        });
                    }
                    return true;
                }
                Some(Err(e)) => panic!(":rust::trading::CandleStream: parquet read error: {e}"),
                None => return false,
            }
        }
    }
}

/// wat-side wrappers contributed by this shim. The deps mechanism
/// concatenates this slice into the global `WatSource` list before
/// parsing the entry file, so `(:wat::load-file! "io/CandleStream.wat")`
/// in `wat/main.wat` resolves to this baked source.
pub fn wat_sources() -> &'static [WatSource] {
    static FILES: &[WatSource] = &[
        WatSource {
            path: "io/CandleStream.wat",
            source: include_str!("../wat/io/CandleStream.wat"),
        },
    ];
    FILES
}

/// Wire the dispatch into the runtime. `#[wat_dispatch]` generated the
/// type-name-prefixed register fn per impl block; we forward only the
/// in-crate shims (CandleStream). Sqlite + telemetry surfaces come
/// from the `wat-telemetry-sqlite` dep declared in `src/main.rs`.
pub fn register(builder: &mut RustDepsBuilder) {
    __wat_dispatch_WatCandleStream::register(builder);
}
