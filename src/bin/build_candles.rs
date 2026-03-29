/// build-candles — read raw OHLCV from parquet, compute indicators, write SQLite.
///
/// The enterprise builds its own senses. No Python. No pre-baked DB.
/// Every indicator is computed in a single forward pass. Causality guaranteed:
/// every field at candle t uses only candles [0, t].
///
/// Usage:
///   cargo run --release --bin build-candles --features parquet -- \
///     --input data/btc_5m_raw.parquet --output data/candles.db

use std::path::PathBuf;
use std::time::Instant;

use arrow::array::{Float64Array, StringArray, Array};
use clap::Parser;
use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
use rusqlite::{params, Connection};

#[derive(Parser)]
#[command(name = "build-candles", about = "Build candle DB from raw OHLCV parquet")]
struct Args {
    /// Input parquet file with columns: ts, open, high, low, close, volume
    #[arg(long)]
    input: PathBuf,

    /// Output SQLite database
    #[arg(long)]
    output: PathBuf,
}

// ─── Raw candle from parquet ────────────────────────────────────────────────

struct RawCandle {
    ts: String,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,
}

// ─── Computed candle (all indicators) ───────────────────────────────────────

struct ComputedCandle {
    // Raw
    ts: String,
    year: i32,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,

    // Moving averages
    sma20: f64,
    sma50: f64,
    sma200: f64,

    // Bollinger Bands
    bb_upper: f64,
    bb_lower: f64,
    bb_width: f64,

    // RSI (14-period Wilder)
    rsi: f64,

    // MACD (12, 26, 9)
    macd_line: f64,
    macd_signal: f64,
    macd_hist: f64,

    // DMI / ADX (14-period)
    dmi_plus: f64,
    dmi_minus: f64,
    adx: f64,

    // ATR
    atr: f64,
    atr_r: f64,

    // Stochastic (14-period)
    stoch_k: f64,
    stoch_d: f64,

    // Williams %R (14-period)
    williams_r: f64,

    // CCI (20-period)
    cci: f64,

    // MFI (14-period)
    mfi: f64,

    // Rate of change
    roc_1: f64,
    roc_3: f64,
    roc_6: f64,
    roc_12: f64,

    // OBV slope
    obv_slope_12: f64,

    // Volume SMA
    volume_sma_20: f64,

    // Multi-timeframe
    tf_1h_close: f64,
    tf_1h_high: f64,
    tf_1h_low: f64,
    tf_1h_ret: f64,
    tf_1h_body: f64,
    tf_4h_close: f64,
    tf_4h_high: f64,
    tf_4h_low: f64,
    tf_4h_ret: f64,
    tf_4h_body: f64,

    // Derived
    bb_pos: f64,
    kelt_upper: f64,
    kelt_lower: f64,
    kelt_pos: f64,
    squeeze: bool,
    range_pos_12: f64,
    range_pos_24: f64,
    range_pos_48: f64,
    trend_consistency_6: f64,
    trend_consistency_12: f64,
    trend_consistency_24: f64,
    atr_roc_6: f64,
    atr_roc_12: f64,
    vol_accel: f64,

    // Time
    hour: f64,
    day_of_week: f64,

    // Label (oracle — prophetic, not causal)
    label_oracle_10: String,
}

// ─── Indicator computation helpers ──────────────────────────────────────────

fn sma(values: &[f64], period: usize, idx: usize) -> f64 {
    if idx + 1 < period { return 0.0; }
    let start = idx + 1 - period;
    values[start..=idx].iter().sum::<f64>() / period as f64
}

fn stddev(values: &[f64], period: usize, idx: usize) -> f64 {
    if idx + 1 < period { return 0.0; }
    let mean = sma(values, period, idx);
    let start = idx + 1 - period;
    let var = values[start..=idx].iter()
        .map(|v| (v - mean).powi(2))
        .sum::<f64>() / period as f64;
    var.sqrt()
}

fn ema_series(values: &[f64], period: usize) -> Vec<f64> {
    let mut result = vec![0.0; values.len()];
    if values.is_empty() { return result; }
    let k = 2.0 / (period as f64 + 1.0);
    result[0] = values[0];
    for i in 1..values.len() {
        result[i] = values[i] * k + result[i - 1] * (1.0 - k);
    }
    result
}

fn roc(closes: &[f64], period: usize, idx: usize) -> f64 {
    if idx < period { return 0.0; }
    if closes[idx - period].abs() < 1e-10 { return 0.0; }
    (closes[idx] - closes[idx - period]) / closes[idx - period]
}

fn range_position(highs: &[f64], lows: &[f64], close: f64, period: usize, idx: usize) -> f64 {
    if idx + 1 < period { return 0.5; }
    let start = idx + 1 - period;
    let hi = highs[start..=idx].iter().fold(f64::NEG_INFINITY, |a, &b| a.max(b));
    let lo = lows[start..=idx].iter().fold(f64::INFINITY, |a, &b| a.min(b));
    let range = hi - lo;
    if range < 1e-10 { 0.5 } else { (close - lo) / range }
}

fn trend_consistency(closes: &[f64], period: usize, idx: usize) -> f64 {
    if idx < period { return 0.5; }
    let ups = (idx + 1 - period..=idx)
        .filter(|&i| i > 0 && closes[i] > closes[i - 1])
        .count();
    ups as f64 / period as f64
}

fn parse_hour(ts: &str) -> f64 {
    ts.get(11..13).and_then(|s| s.parse().ok()).unwrap_or(12.0)
}

fn parse_day_of_week(ts: &str) -> f64 {
    let y: i32 = ts.get(..4).and_then(|s| s.parse().ok()).unwrap_or(2019);
    let m: i32 = ts.get(5..7).and_then(|s| s.parse().ok()).unwrap_or(1);
    let d: i32 = ts.get(8..10).and_then(|s| s.parse().ok()).unwrap_or(1);
    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    let y2 = if m < 3 { y - 1 } else { y };
    ((y2 + y2 / 4 - y2 / 100 + y2 / 400 + t[(m - 1) as usize] + d) % 7) as f64
}

fn parse_year(ts: &str) -> i32 {
    ts.get(..4).and_then(|s| s.parse().ok()).unwrap_or(2019)
}

// ─── Wilder smoothing (RSI, ATR, DMI/ADX) ──────────────────────────────────

struct WilderState {
    avg_gain: f64,
    avg_loss: f64,
    atr: f64,
    dm_plus: f64,
    dm_minus: f64,
    adx_sum: f64,
    adx: f64,
    period: usize,
    count: usize,
}

impl WilderState {
    fn new(period: usize) -> Self {
        Self {
            avg_gain: 0.0, avg_loss: 0.0,
            atr: 0.0,
            dm_plus: 0.0, dm_minus: 0.0,
            adx_sum: 0.0, adx: 0.0,
            period, count: 0,
        }
    }

    fn update(&mut self, prev: &RawCandle, curr: &RawCandle) {
        self.count += 1;
        let p = self.period as f64;

        // RSI components
        let change = curr.close - prev.close;
        let gain = if change > 0.0 { change } else { 0.0 };
        let loss = if change < 0.0 { -change } else { 0.0 };

        // True range
        let tr = (curr.high - curr.low)
            .max((curr.high - prev.close).abs())
            .max((curr.low - prev.close).abs());

        // Directional movement
        let up_move = curr.high - prev.high;
        let down_move = prev.low - curr.low;
        let raw_dm_plus = if up_move > down_move && up_move > 0.0 { up_move } else { 0.0 };
        let raw_dm_minus = if down_move > up_move && down_move > 0.0 { down_move } else { 0.0 };

        if self.count <= self.period {
            // Accumulation phase
            self.avg_gain += gain;
            self.avg_loss += loss;
            self.atr += tr;
            self.dm_plus += raw_dm_plus;
            self.dm_minus += raw_dm_minus;

            if self.count == self.period {
                self.avg_gain /= p;
                self.avg_loss /= p;
                self.atr /= p;
                self.dm_plus /= p;
                self.dm_minus /= p;
            }
        } else {
            // Wilder smoothing
            self.avg_gain = (self.avg_gain * (p - 1.0) + gain) / p;
            self.avg_loss = (self.avg_loss * (p - 1.0) + loss) / p;
            self.atr = (self.atr * (p - 1.0) + tr) / p;
            self.dm_plus = (self.dm_plus * (p - 1.0) + raw_dm_plus) / p;
            self.dm_minus = (self.dm_minus * (p - 1.0) + raw_dm_minus) / p;
        }

        // ADX accumulation (needs DI values)
        if self.count >= self.period && self.atr > 1e-10 {
            let di_plus = 100.0 * self.dm_plus / self.atr;
            let di_minus = 100.0 * self.dm_minus / self.atr;
            let di_sum = di_plus + di_minus;
            let dx = if di_sum > 1e-10 { 100.0 * (di_plus - di_minus).abs() / di_sum } else { 0.0 };

            if self.count <= self.period * 2 {
                self.adx_sum += dx;
                if self.count == self.period * 2 {
                    self.adx = self.adx_sum / p;
                }
            } else {
                self.adx = (self.adx * (p - 1.0) + dx) / p;
            }
        }
    }

    fn rsi(&self) -> f64 {
        if self.count < self.period { return 50.0; }
        if self.avg_loss < 1e-10 { return 100.0; }
        let rs = self.avg_gain / self.avg_loss;
        100.0 - 100.0 / (1.0 + rs)
    }

    fn dmi_plus(&self) -> f64 {
        if self.count < self.period || self.atr < 1e-10 { return 0.0; }
        100.0 * self.dm_plus / self.atr
    }

    fn dmi_minus(&self) -> f64 {
        if self.count < self.period || self.atr < 1e-10 { return 0.0; }
        100.0 * self.dm_minus / self.atr
    }
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() {
    let args = Args::parse();
    let t0 = Instant::now();

    // ── Read parquet ────────────────────────────────────────────────
    eprintln!("Reading {:?}...", args.input);
    let file = std::fs::File::open(&args.input).expect("failed to open parquet");
    let builder = ParquetRecordBatchReaderBuilder::try_new(file).expect("failed to read parquet");
    let reader = builder.build().expect("failed to build reader");

    let mut raw: Vec<RawCandle> = Vec::new();
    for batch in reader {
        let batch = batch.expect("failed to read batch");
        let ts_col = batch.column_by_name("ts").expect("missing ts column");
        let open_col = batch.column_by_name("open").expect("missing open column");
        let high_col = batch.column_by_name("high").expect("missing high column");
        let low_col = batch.column_by_name("low").expect("missing low column");
        let close_col = batch.column_by_name("close").expect("missing close column");
        let vol_col = batch.column_by_name("volume").expect("missing volume column");

        // Handle timestamp as either string or timestamp type
        let ts_strings: Vec<String> = if let Some(arr) = ts_col.as_any().downcast_ref::<StringArray>() {
            (0..arr.len()).map(|i| arr.value(i).to_string()).collect()
        } else {
            // Timestamp type — format as string
            (0..ts_col.len()).map(|i| {
                use arrow::array::TimestampMicrosecondArray;
                if let Some(arr) = ts_col.as_any().downcast_ref::<TimestampMicrosecondArray>() {
                    let micros = arr.value(i);
                    let secs = micros / 1_000_000;
                    let nsecs = ((micros % 1_000_000) * 1000) as u32;
                    let dt = chrono::DateTime::from_timestamp(secs, nsecs)
                        .unwrap_or_default();
                    dt.format("%Y-%m-%d %H:%M:%S").to_string()
                } else {
                    use arrow::array::TimestampNanosecondArray;
                    let arr = ts_col.as_any().downcast_ref::<TimestampNanosecondArray>()
                        .expect("ts column must be string or timestamp");
                    let nanos = arr.value(i);
                    let secs = nanos / 1_000_000_000;
                    let nsecs = (nanos % 1_000_000_000) as u32;
                    let dt = chrono::DateTime::from_timestamp(secs, nsecs)
                        .unwrap_or_default();
                    dt.format("%Y-%m-%d %H:%M:%S").to_string()
                }
            }).collect()
        };

        let opens = open_col.as_any().downcast_ref::<Float64Array>().expect("open must be f64");
        let highs = high_col.as_any().downcast_ref::<Float64Array>().expect("high must be f64");
        let lows = low_col.as_any().downcast_ref::<Float64Array>().expect("low must be f64");
        let closes = close_col.as_any().downcast_ref::<Float64Array>().expect("close must be f64");
        let volumes = vol_col.as_any().downcast_ref::<Float64Array>().expect("volume must be f64");

        for i in 0..batch.num_rows() {
            raw.push(RawCandle {
                ts: ts_strings[i].clone(),
                open: opens.value(i),
                high: highs.value(i),
                low: lows.value(i),
                close: closes.value(i),
                volume: volumes.value(i),
            });
        }
    }
    eprintln!("  {} candles loaded in {:.1}s", raw.len(), t0.elapsed().as_secs_f64());

    // ── Compute indicators (single forward pass) ────────────────────
    eprintln!("Computing indicators...");
    let t1 = Instant::now();
    let n = raw.len();

    let closes: Vec<f64> = raw.iter().map(|c| c.close).collect();
    let highs: Vec<f64> = raw.iter().map(|c| c.high).collect();
    let lows: Vec<f64> = raw.iter().map(|c| c.low).collect();
    let volumes: Vec<f64> = raw.iter().map(|c| c.volume).collect();

    // EMA series (forward pass, causal)
    let ema12 = ema_series(&closes, 12);
    let ema26 = ema_series(&closes, 26);
    let macd_line: Vec<f64> = (0..n).map(|i| ema12[i] - ema26[i]).collect();
    let macd_signal = ema_series(&macd_line, 9);
    let ema20 = ema_series(&closes, 20);

    // Wilder state (RSI, ATR, DMI, ADX)
    let mut wilder = WilderState::new(14);
    let mut rsi_series = vec![50.0; n];
    let mut atr_series = vec![0.0; n];
    let mut atr_r_series = vec![0.0; n];
    let mut dmi_plus_series = vec![0.0; n];
    let mut dmi_minus_series = vec![0.0; n];
    let mut adx_series = vec![0.0; n];

    for i in 1..n {
        wilder.update(&raw[i - 1], &raw[i]);
        rsi_series[i] = wilder.rsi();
        atr_series[i] = wilder.atr;
        atr_r_series[i] = if raw[i].close > 1e-10 { wilder.atr / raw[i].close } else { 0.0 };
        dmi_plus_series[i] = wilder.dmi_plus();
        dmi_minus_series[i] = wilder.dmi_minus();
        adx_series[i] = wilder.adx;
    }

    // OBV (cumulative, forward pass)
    let mut obv = vec![0.0; n];
    for i in 1..n {
        obv[i] = obv[i - 1] + if closes[i] > closes[i - 1] { volumes[i] }
            else if closes[i] < closes[i - 1] { -volumes[i] }
            else { 0.0 };
    }

    // Stochastic %K (14-period)
    let stoch_period = 14;
    let mut stoch_k_series = vec![50.0; n];
    for i in stoch_period - 1..n {
        let window = &raw[i + 1 - stoch_period..=i];
        let hi = window.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let lo = window.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        let range = hi - lo;
        stoch_k_series[i] = if range > 1e-10 { (raw[i].close - lo) / range * 100.0 } else { 50.0 };
    }
    // %D = SMA(3) of %K — computed inline below

    // Williams %R (14-period)
    let mut williams_series = vec![-50.0; n];
    for i in stoch_period - 1..n {
        let window = &raw[i + 1 - stoch_period..=i];
        let hi = window.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let lo = window.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        let range = hi - lo;
        williams_series[i] = if range > 1e-10 { -100.0 * (hi - raw[i].close) / range } else { -50.0 };
    }

    // CCI (20-period)
    let cci_period = 20;
    let mut cci_series = vec![0.0; n];
    for i in cci_period - 1..n {
        let start = i + 1 - cci_period;
        let tp: Vec<f64> = (start..=i).map(|j| (raw[j].high + raw[j].low + raw[j].close) / 3.0).collect();
        let tp_mean = tp.iter().sum::<f64>() / cci_period as f64;
        let md = tp.iter().map(|v| (v - tp_mean).abs()).sum::<f64>() / cci_period as f64;
        let curr_tp = (raw[i].high + raw[i].low + raw[i].close) / 3.0;
        cci_series[i] = if md > 1e-10 { (curr_tp - tp_mean) / (0.015 * md) } else { 0.0 };
    }

    // MFI (14-period)
    let mfi_period = 14;
    let mut mfi_series = vec![50.0; n];
    for i in mfi_period..n {
        let mut pos_flow = 0.0;
        let mut neg_flow = 0.0;
        for j in i + 1 - mfi_period..=i {
            let tp = (raw[j].high + raw[j].low + raw[j].close) / 3.0;
            let prev_tp = (raw[j - 1].high + raw[j - 1].low + raw[j - 1].close) / 3.0;
            let mf = tp * raw[j].volume;
            if tp > prev_tp { pos_flow += mf; }
            else { neg_flow += mf; }
        }
        mfi_series[i] = if neg_flow > 1e-10 { 100.0 - 100.0 / (1.0 + pos_flow / neg_flow) } else { 100.0 };
    }

    // ── Build computed candles ──────────────────────────────────────
    let mut computed: Vec<ComputedCandle> = Vec::with_capacity(n);

    for i in 0..n {
        let c = &raw[i];
        let sma20_val = sma(&closes, 20, i);
        let sma50_val = sma(&closes, 50, i);
        let sma200_val = sma(&closes, 200, i);
        let std20 = stddev(&closes, 20, i);
        let bb_upper = sma20_val + 2.0 * std20;
        let bb_lower = sma20_val - 2.0 * std20;
        let bb_width = if sma20_val > 1e-10 { (bb_upper - bb_lower) / sma20_val } else { 0.0 };
        let bb_range = bb_upper - bb_lower;
        let bb_pos = if bb_range > 1e-10 { (c.close - bb_lower) / bb_range } else { 0.5 };

        let macd_h = macd_line[i] - macd_signal[i];

        // Keltner
        let kelt_upper = ema20[i] + 1.5 * atr_series[i];
        let kelt_lower = ema20[i] - 1.5 * atr_series[i];
        let kelt_range = kelt_upper - kelt_lower;
        let kelt_pos = if kelt_range > 1e-10 { (c.close - kelt_lower) / kelt_range } else { 0.5 };
        let kelt_width = if ema20[i] > 1e-10 { atr_series[i] * 1.5 / ema20[i] } else { 0.0 };
        let squeeze = bb_width < kelt_width; // BB inside Keltner = squeeze

        // Stochastic %D = SMA(3) of %K
        let stoch_d = sma(&stoch_k_series, 3, i);

        // OBV slope (12-period linear regression)
        let obv_slope = if i >= 11 {
            let window = &obv[i - 11..=i];
            let n_w = window.len() as f64;
            let sx: f64 = (0..window.len()).map(|j| j as f64).sum();
            let sy: f64 = window.iter().sum();
            let sxx: f64 = (0..window.len()).map(|j| (j * j) as f64).sum();
            let sxy: f64 = window.iter().enumerate().map(|(j, &v)| j as f64 * v).sum();
            let denom = n_w * sxx - sx * sx;
            if denom.abs() > 1e-10 { (n_w * sxy - sx * sy) / denom } else { 0.0 }
        } else { 0.0 };

        let vol_sma_20 = sma(&volumes, 20, i);
        let vol_accel = if vol_sma_20 > 1e-10 { c.volume / vol_sma_20 } else { 1.0 };

        // Multi-timeframe (backward-looking aggregation)
        let (tf_1h_close, tf_1h_high, tf_1h_low) = if i >= 11 {
            (c.close,
             highs[i - 11..=i].iter().fold(f64::NEG_INFINITY, |a, &b| a.max(b)),
             lows[i - 11..=i].iter().fold(f64::INFINITY, |a, &b| a.min(b)))
        } else { (c.close, c.high, c.low) };
        let tf_1h_ret = roc(&closes, 12, i);
        let tf_1h_body = if i >= 11 {
            let r = tf_1h_high - tf_1h_low;
            if r > 1e-10 { (c.close - raw[i - 11].open).abs() / r } else { 0.0 }
        } else { 0.0 };

        let (tf_4h_close, tf_4h_high, tf_4h_low) = if i >= 47 {
            (c.close,
             highs[i - 47..=i].iter().fold(f64::NEG_INFINITY, |a, &b| a.max(b)),
             lows[i - 47..=i].iter().fold(f64::INFINITY, |a, &b| a.min(b)))
        } else { (c.close, c.high, c.low) };
        let tf_4h_ret = roc(&closes, 48, i);
        let tf_4h_body = if i >= 47 {
            let r = tf_4h_high - tf_4h_low;
            if r > 1e-10 { (c.close - raw[i - 47].open).abs() / r } else { 0.0 }
        } else { 0.0 };

        // Oracle label (prophetic — separated from causal indicators)
        let label = if i + 10 < n {
            let future_pct = (closes[i + 10] - c.close) / c.close;
            if future_pct > 0.005 { "Buy".to_string() }
            else if future_pct < -0.005 { "Sell".to_string() }
            else { "Noise".to_string() }
        } else {
            "Noise".to_string()
        };

        computed.push(ComputedCandle {
            ts: c.ts.clone(),
            year: parse_year(&c.ts),
            open: c.open, high: c.high, low: c.low, close: c.close, volume: c.volume,
            sma20: sma20_val, sma50: sma50_val, sma200: sma200_val,
            bb_upper, bb_lower, bb_width,
            rsi: rsi_series[i],
            macd_line: macd_line[i], macd_signal: macd_signal[i], macd_hist: macd_h,
            dmi_plus: dmi_plus_series[i], dmi_minus: dmi_minus_series[i], adx: adx_series[i],
            atr: atr_series[i], atr_r: atr_r_series[i],
            stoch_k: stoch_k_series[i], stoch_d,
            williams_r: williams_series[i],
            cci: cci_series[i],
            mfi: mfi_series[i],
            roc_1: roc(&closes, 1, i), roc_3: roc(&closes, 3, i),
            roc_6: roc(&closes, 6, i), roc_12: roc(&closes, 12, i),
            obv_slope_12: obv_slope,
            volume_sma_20: vol_sma_20,
            tf_1h_close, tf_1h_high, tf_1h_low, tf_1h_ret, tf_1h_body,
            tf_4h_close, tf_4h_high, tf_4h_low, tf_4h_ret, tf_4h_body,
            bb_pos, kelt_upper, kelt_lower, kelt_pos, squeeze,
            range_pos_12: range_position(&highs, &lows, c.close, 12, i),
            range_pos_24: range_position(&highs, &lows, c.close, 24, i),
            range_pos_48: range_position(&highs, &lows, c.close, 48, i),
            trend_consistency_6: trend_consistency(&closes, 6, i),
            trend_consistency_12: trend_consistency(&closes, 12, i),
            trend_consistency_24: trend_consistency(&closes, 24, i),
            atr_roc_6: roc(&atr_series, 6, i),
            atr_roc_12: roc(&atr_series, 12, i),
            vol_accel,
            hour: parse_hour(&c.ts),
            day_of_week: parse_day_of_week(&c.ts),
            label_oracle_10: label,
        });
    }
    eprintln!("  {} candles computed in {:.1}s", computed.len(), t1.elapsed().as_secs_f64());

    // ── Write SQLite ────────────────────────────────────────────────
    eprintln!("Writing {:?}...", args.output);
    let t2 = Instant::now();

    if args.output.exists() {
        std::fs::remove_file(&args.output).expect("failed to remove existing DB");
    }

    let db = Connection::open(&args.output).expect("failed to create DB");
    db.execute_batch("
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=OFF;

        CREATE TABLE candles (
            ts TEXT PRIMARY KEY,
            year INTEGER,
            open REAL, high REAL, low REAL, close REAL, volume REAL,
            sma20 REAL, sma50 REAL, sma200 REAL,
            bb_upper REAL, bb_lower REAL, bb_width REAL,
            rsi REAL,
            macd_line REAL, macd_signal REAL, macd_hist REAL,
            dmi_plus REAL, dmi_minus REAL, adx REAL,
            atr REAL, atr_r REAL,
            stoch_k REAL, stoch_d REAL,
            williams_r REAL,
            cci REAL,
            mfi REAL,
            roc_1 REAL, roc_3 REAL, roc_6 REAL, roc_12 REAL,
            obv_slope_12 REAL,
            volume_sma_20 REAL,
            tf_1h_close REAL, tf_1h_high REAL, tf_1h_low REAL, tf_1h_ret REAL, tf_1h_body REAL,
            tf_4h_close REAL, tf_4h_high REAL, tf_4h_low REAL, tf_4h_ret REAL, tf_4h_body REAL,
            bb_pos REAL, kelt_upper REAL, kelt_lower REAL, kelt_pos REAL, squeeze INTEGER,
            range_pos_12 REAL, range_pos_24 REAL, range_pos_48 REAL,
            trend_consistency_6 REAL, trend_consistency_12 REAL, trend_consistency_24 REAL,
            atr_roc_6 REAL, atr_roc_12 REAL,
            vol_accel REAL,
            hour REAL, day_of_week REAL,
            label_oracle_10 TEXT
        );
    ").expect("failed to create schema");

    db.execute_batch("BEGIN").ok();
    let mut stmt = db.prepare(
        "INSERT INTO candles VALUES (
            ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,
            ?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,
            ?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,
            ?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,
            ?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,
            ?51,?52,?53,?54,?55,?56,?57,?58,?59,?60
        )"
    ).expect("failed to prepare insert");

    for (i, c) in computed.iter().enumerate() {
        stmt.execute(params![
            c.ts, c.year, c.open, c.high, c.low, c.close, c.volume,
            c.sma20, c.sma50, c.sma200,
            c.bb_upper, c.bb_lower, c.bb_width,
            c.rsi,
            c.macd_line, c.macd_signal, c.macd_hist,
            c.dmi_plus, c.dmi_minus, c.adx,
            c.atr, c.atr_r,
            c.stoch_k, c.stoch_d,
            c.williams_r,
            c.cci,
            c.mfi,
            c.roc_1, c.roc_3, c.roc_6, c.roc_12,
            c.obv_slope_12,
            c.volume_sma_20,
            c.tf_1h_close, c.tf_1h_high, c.tf_1h_low, c.tf_1h_ret, c.tf_1h_body,
            c.tf_4h_close, c.tf_4h_high, c.tf_4h_low, c.tf_4h_ret, c.tf_4h_body,
            c.bb_pos, c.kelt_upper, c.kelt_lower, c.kelt_pos, c.squeeze as i32,
            c.range_pos_12, c.range_pos_24, c.range_pos_48,
            c.trend_consistency_6, c.trend_consistency_12, c.trend_consistency_24,
            c.atr_roc_6, c.atr_roc_12,
            c.vol_accel,
            c.hour, c.day_of_week,
            c.label_oracle_10,
        ]).expect(&format!("failed to insert row {}", i));

        if i % 100_000 == 0 && i > 0 {
            db.execute_batch("COMMIT; BEGIN").ok();
            eprintln!("  {}/{} rows written", i, n);
        }
    }
    db.execute_batch("COMMIT").ok();

    eprintln!("  {} rows written in {:.1}s", n, t2.elapsed().as_secs_f64());
    eprintln!("Done. Total: {:.1}s", t0.elapsed().as_secs_f64());
}
