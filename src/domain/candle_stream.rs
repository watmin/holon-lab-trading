/// Candle stream. Opens a parquet file. Yields raw candles one at a time.
/// The input to the vm. Not a service. Not a program. The source.
use std::path::Path;

use arrow::array::{Array, Float64Array, StringArray, TimestampMicrosecondArray};
use parquet::arrow::arrow_reader::{ParquetRecordBatchReader, ParquetRecordBatchReaderBuilder};
use parquet::file::reader::{FileReader, SerializedFileReader};

use crate::types::ohlcv::{Asset, Ohlcv};

#[cfg(feature = "parquet")]
pub struct CandleStream {
    buffer: Vec<Ohlcv>,
    buf_idx: usize,
    reader: ParquetRecordBatchReader,
    source_asset: String,
    target_asset: String,
}

#[cfg(feature = "parquet")]
impl CandleStream {
    pub fn open(path: &Path, source_asset: &str, target_asset: &str) -> Self {
        let file = std::fs::File::open(path).expect("failed to open parquet");
        let builder =
            ParquetRecordBatchReaderBuilder::try_new(file).expect("failed to read parquet");
        let reader = builder.build().expect("failed to build reader");
        Self {
            buffer: Vec::new(),
            buf_idx: 0,
            reader,
            source_asset: source_asset.to_string(),
            target_asset: target_asset.to_string(),
        }
    }

    pub fn total_candles(path: &Path) -> usize {
        let file = std::fs::File::open(path).expect("failed to open parquet for metadata");
        let reader =
            SerializedFileReader::new(file).expect("failed to read parquet metadata");
        reader.metadata().file_metadata().num_rows() as usize
    }

    fn fill_buffer(&mut self) -> bool {
        loop {
            match self.reader.next() {
                Some(Ok(batch)) => {
                    if batch.num_rows() == 0 {
                        continue;
                    }
                    let ts_col = batch.column_by_name("ts").expect("missing ts");
                    let open_col = batch.column_by_name("open").expect("missing open");
                    let high_col = batch.column_by_name("high").expect("missing high");
                    let low_col = batch.column_by_name("low").expect("missing low");
                    let close_col = batch.column_by_name("close").expect("missing close");
                    let vol_col = batch.column_by_name("volume").expect("missing volume");

                    let ts_strings: Vec<String> =
                        if let Some(arr) = ts_col.as_any().downcast_ref::<StringArray>() {
                            (0..arr.len()).map(|i| arr.value(i).to_string()).collect()
                        } else if let Some(arr) = ts_col
                            .as_any()
                            .downcast_ref::<TimestampMicrosecondArray>()
                        {
                            (0..arr.len())
                                .map(|i| {
                                    let micros = arr.value(i);
                                    let secs = micros / 1_000_000;
                                    let nsecs = ((micros % 1_000_000) * 1000) as u32;
                                    chrono::DateTime::from_timestamp(secs, nsecs)
                                        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                                        .unwrap_or_default()
                                })
                                .collect()
                        } else {
                            panic!("unsupported timestamp column type");
                        };

                    let opens = open_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("open not f64");
                    let highs = high_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("high not f64");
                    let lows = low_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("low not f64");
                    let closes = close_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("close not f64");
                    let volumes = vol_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("volume not f64");

                    self.buffer.clear();
                    self.buf_idx = 0;
                    for i in 0..batch.num_rows() {
                        self.buffer.push(Ohlcv::new(
                            Asset::new(&self.source_asset),
                            Asset::new(&self.target_asset),
                            ts_strings[i].clone(),
                            opens.value(i),
                            highs.value(i),
                            lows.value(i),
                            closes.value(i),
                            volumes.value(i),
                        ));
                    }
                    return true;
                }
                Some(Err(e)) => panic!("parquet read error: {}", e),
                None => return false,
            }
        }
    }
}

#[cfg(feature = "parquet")]
impl Iterator for CandleStream {
    type Item = Ohlcv;

    fn next(&mut self) -> Option<Ohlcv> {
        if self.buf_idx >= self.buffer.len() {
            if !self.fill_buffer() {
                return None;
            }
        }
        let raw = self.buffer[self.buf_idx].clone();
        self.buf_idx += 1;
        Some(raw)
    }
}
