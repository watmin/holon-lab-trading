//! Streaming indicator fold — state struct + pure step function.
//!
//! Each indicator is a state machine advanced by one candle.
//! (state, raw_candle) → (state, computed_candle)
//!
//! Replaces the batch build_candles.rs pipeline. Same math, streaming.
//! The Candle struct stays the same shape — consumers don't know
//! indicators were computed on the fly vs pre-loaded from SQLite.

use std::collections::VecDeque;
use crate::candle::Candle;

// ─── Raw input ─────────────────────────────────────────────────────────────

/// Minimal candle from parquet: just OHLCV + timestamp.
/// The enterprise's true input — everything else is derived.
#[derive(Clone)]
pub struct RawCandle {
    pub ts: String,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
}

// ─── Primitive state machines ──────────────────────────────────────────────

/// SMA: sliding window average. O(1) per step via running sum.
struct SmaState {
    buffer: VecDeque<f64>,
    period: usize,
    sum: f64,
}

impl SmaState {
    fn new(period: usize) -> Self {
        Self { buffer: VecDeque::with_capacity(period + 1), period, sum: 0.0 }
    }

    fn step(&mut self, value: f64) -> f64 {
        self.sum += value;
        self.buffer.push_back(value);
        if self.buffer.len() > self.period {
            self.sum -= self.buffer.pop_front().unwrap();
        }
        if self.buffer.len() < self.period { return 0.0; }
        self.sum / self.period as f64
    }
}

/// EMA: exponential moving average with SMA seed (ta-lib canonical).
/// First `period` values averaged as SMA seed, then EMA recursive.
struct EmaState {
    alpha: f64,
    prev: f64,
    period: usize,
    count: usize,
    accum: f64,
}

impl EmaState {
    fn new(period: usize) -> Self {
        Self { alpha: 2.0 / (period as f64 + 1.0), prev: 0.0, period, count: 0, accum: 0.0 }
    }

    fn step(&mut self, value: f64) -> f64 {
        self.count += 1;
        if self.count <= self.period {
            self.accum += value;
            if self.count == self.period {
                self.prev = self.accum / self.period as f64;
                return self.prev;
            }
            return 0.0; // no signal during warmup
        } else {
            self.prev = value * self.alpha + self.prev * (1.0 - self.alpha);
        }
        self.prev
    }
}

/// Wilder smoothing. O(1) after warmup.
struct WilderState {
    count: usize,
    accum: f64,
    prev: f64,
    period: usize,
}

impl WilderState {
    fn new(period: usize) -> Self {
        Self { count: 0, accum: 0.0, prev: 0.0, period }
    }

    /// During warmup (count < period): accumulate, return 0.0.
    /// At count == period: initial average.
    /// After: Wilder smooth. Matches Python ta-lib.
    fn step(&mut self, value: f64) -> f64 {
        self.count += 1;
        let period_f = self.period as f64;
        if self.count <= self.period {
            self.accum += value;
            if self.count == self.period {
                self.prev = self.accum / period_f;
                return self.prev;
            }
            0.0  // no signal during warmup
        } else {
            self.prev = (self.prev * (period_f - 1.0) + value) / period_f;
            self.prev
        }
    }
}

/// Rolling standard deviation — O(1) per step via running sum + sum of squares.
/// Numerically equivalent to exact population stddev over the window.
struct RollingStddev {
    buffer: VecDeque<f64>,
    period: usize,
    sum: f64,
    sum_sq: f64,
}

impl RollingStddev {
    fn new(period: usize) -> Self {
        Self { buffer: VecDeque::with_capacity(period + 1), period, sum: 0.0, sum_sq: 0.0 }
    }

    fn step(&mut self, value: f64) -> f64 {
        self.sum += value;
        self.sum_sq += value * value;
        self.buffer.push_back(value);
        if self.buffer.len() > self.period {
            let old = self.buffer.pop_front().unwrap();
            self.sum -= old;
            self.sum_sq -= old * old;
        }
        if self.buffer.len() < self.period { return 0.0; }
        let n = self.period as f64;
        let mean = self.sum / n;
        let var = (self.sum_sq / n) - mean * mean;
        // Guard against floating-point rounding producing tiny negatives
        var.max(0.0).sqrt()
    }
}

/// Ring buffer for ROC, range position, trend consistency.
struct RingBuffer {
    buffer: VecDeque<f64>,
    capacity: usize,
}

impl RingBuffer {
    fn new(capacity: usize) -> Self {
        Self { buffer: VecDeque::with_capacity(capacity + 1), capacity }
    }

    fn push(&mut self, value: f64) {
        self.buffer.push_back(value);
        if self.buffer.len() > self.capacity { self.buffer.pop_front(); }
    }

    fn oldest(&self) -> f64 {
        self.buffer.front().copied().unwrap_or(0.0)
    }

    fn len(&self) -> usize { self.buffer.len() }

    fn full(&self) -> bool { self.buffer.len() == self.capacity }

    fn iter(&self) -> std::collections::vec_deque::Iter<'_, f64> { self.buffer.iter() }

    fn max(&self) -> f64 { self.buffer.iter().fold(f64::NEG_INFINITY, |a, &b| a.max(b)) }

    fn min(&self) -> f64 { self.buffer.iter().fold(f64::INFINITY, |a, &b| a.min(b)) }
}

// ─── Composed indicator states ─────────────────────────────────────────────

struct RsiState {
    gain: WilderState,
    loss: WilderState,
    prev_close: f64,
    started: bool,
}

impl RsiState {
    fn new(period: usize) -> Self {
        Self { gain: WilderState::new(period), loss: WilderState::new(period), prev_close: 0.0, started: false }
    }

    fn step(&mut self, close: f64) -> f64 {
        if !self.started {
            self.started = true;
            self.prev_close = close;
            return 50.0;
        }
        let change = close - self.prev_close;
        let avg_gain = self.gain.step(change.max(0.0));
        let avg_loss = self.loss.step((-change).max(0.0));
        self.prev_close = close;
        // During Wilder warmup, both return 0.0 — RSI is undefined
        if avg_gain == 0.0 && avg_loss == 0.0 { return 50.0; }
        100.0 - 100.0 / (1.0 + avg_gain / avg_loss.max(1e-10))
    }
}

struct AtrState {
    wilder: WilderState,
    prev_close: f64,
    started: bool,
}

impl AtrState {
    fn new(period: usize) -> Self {
        Self { wilder: WilderState::new(period), prev_close: 0.0, started: false }
    }

    fn step(&mut self, high: f64, low: f64, close: f64) -> f64 {
        let tr = if !self.started {
            self.started = true;
            self.prev_close = close;
            high - low
        } else {
            let tr = (high - low)
                .max((high - self.prev_close).abs())
                .max((low - self.prev_close).abs());
            self.prev_close = close;
            tr
        };
        self.wilder.step(tr)
    }
}

struct MacdState {
    ema12: EmaState,
    ema26: EmaState,
    signal: EmaState,
}

impl MacdState {
    fn new() -> Self {
        Self { ema12: EmaState::new(12), ema26: EmaState::new(26), signal: EmaState::new(9) }
    }

    fn step(&mut self, close: f64) -> (f64, f64, f64) {
        let e12 = self.ema12.step(close);
        let e26 = self.ema26.step(close);
        let line = e12 - e26;
        let sig = self.signal.step(line);
        (line, sig, line - sig)
    }
}

/// DMI/ADX with two-phase ADX accumulation matching build_candles.
/// ADX Wilder only receives DX values after DM/ATR Wilders complete warmup.
struct DmiState {
    plus: WilderState,
    minus: WilderState,
    atr: WilderState,
    adx: WilderState,
    prev_high: f64,
    prev_low: f64,
    prev_close: f64,
    started: bool,
    count: usize,
    period: usize,
}

impl DmiState {
    fn new(period: usize) -> Self {
        Self {
            plus: WilderState::new(period), minus: WilderState::new(period),
            atr: WilderState::new(period), adx: WilderState::new(period),
            prev_high: 0.0, prev_low: 0.0, prev_close: 0.0,
            started: false, count: 0, period,
        }
    }

    fn step(&mut self, high: f64, low: f64, close: f64) -> (f64, f64, f64) {
        if !self.started {
            self.started = true;
            self.prev_high = high;
            self.prev_low = low;
            self.prev_close = close;
            self.count = 1;
            return (0.0, 0.0, 0.0);
        }
        self.count += 1;
        let up_move = high - self.prev_high;
        let down_move = self.prev_low - low;
        let plus_dm = if up_move > down_move && up_move > 0.0 { up_move } else { 0.0 };
        let minus_dm = if down_move > up_move && down_move > 0.0 { down_move } else { 0.0 };
        let tr = (high - low).max((high - self.prev_close).abs()).max((low - self.prev_close).abs());

        let sm_plus = self.plus.step(plus_dm);
        let sm_minus = self.minus.step(minus_dm);
        let sm_atr = self.atr.step(tr);
        let atr_val = sm_atr.max(1e-10);
        let dmi_plus = sm_plus * 100.0 / atr_val;
        let dmi_minus = sm_minus * 100.0 / atr_val;
        let dx = (dmi_plus - dmi_minus).abs() * 100.0 / (dmi_plus + dmi_minus).max(1e-10);

        // Two-phase ADX: only feed DX after DM/ATR warmup (matches build_candles)
        let adx = if self.count >= self.period {
            self.adx.step(dx)
        } else {
            0.0
        };

        self.prev_high = high;
        self.prev_low = low;
        self.prev_close = close;
        (dmi_plus, dmi_minus, adx)
    }
}

struct StochState {
    high_buf: RingBuffer,
    low_buf: RingBuffer,
    d_sma: SmaState,
}

impl StochState {
    fn new(period: usize) -> Self {
        Self { high_buf: RingBuffer::new(period), low_buf: RingBuffer::new(period), d_sma: SmaState::new(3) }
    }

    fn step(&mut self, high: f64, low: f64, close: f64) -> (f64, f64, f64) {
        self.high_buf.push(high);
        self.low_buf.push(low);
        let hi = self.high_buf.max();
        let lo = self.low_buf.min();
        let range = (hi - lo).max(1e-10);
        let k = (close - lo) / range * 100.0;
        let d = self.d_sma.step(k);
        let williams_r = -100.0 * (hi - close) / range;
        (k, d, williams_r)
    }
}

struct CciState {
    tp_sma: SmaState,
    tp_buf: RingBuffer,
}

impl CciState {
    fn new(period: usize) -> Self {
        Self { tp_sma: SmaState::new(period), tp_buf: RingBuffer::new(period) }
    }

    fn step(&mut self, high: f64, low: f64, close: f64) -> f64 {
        let tp = (high + low + close) / 3.0;
        let mean = self.tp_sma.step(tp);
        self.tp_buf.push(tp);
        let mad = self.tp_buf.iter().map(|&v| (v - mean).abs()).sum::<f64>() / self.tp_buf.len() as f64;
        if mad < 1e-10 { 0.0 } else { (tp - mean) / (0.015 * mad) }
    }
}

/// MFI — windowed sum of positive/negative money flow (matches build_candles exactly).
struct MfiState {
    pos_buf: RingBuffer,
    neg_buf: RingBuffer,
    prev_tp: f64,
    started: bool,
}

impl MfiState {
    fn new(period: usize) -> Self {
        Self { pos_buf: RingBuffer::new(period), neg_buf: RingBuffer::new(period), prev_tp: 0.0, started: false }
    }

    fn step(&mut self, high: f64, low: f64, close: f64, volume: f64) -> f64 {
        let tp = (high + low + close) / 3.0;
        if !self.started {
            self.started = true;
            self.prev_tp = tp;
            return 50.0;
        }
        let money_flow = tp * volume;
        let pos = if tp > self.prev_tp { money_flow } else { 0.0 };
        let neg = if tp <= self.prev_tp { money_flow } else { 0.0 };
        self.pos_buf.push(pos);
        self.neg_buf.push(neg);
        self.prev_tp = tp;
        if !self.pos_buf.full() { return 50.0; }
        let pos_sum: f64 = self.pos_buf.iter().sum();
        let neg_sum: f64 = self.neg_buf.iter().sum();
        if neg_sum > 1e-10 { 100.0 - 100.0 / (1.0 + pos_sum / neg_sum) } else { 100.0 }
    }
}

struct ObvState {
    obv: f64,
    prev_close: f64,
    history: RingBuffer,
    started: bool,
}

impl ObvState {
    fn new(period: usize) -> Self {
        Self { obv: 0.0, prev_close: 0.0, history: RingBuffer::new(period), started: false }
    }

    fn step(&mut self, close: f64, volume: f64) -> f64 {
        if !self.started {
            self.started = true;
            self.prev_close = close;
            self.history.push(0.0);
            return 0.0;
        }
        if close > self.prev_close { self.obv += volume; }
        else if close < self.prev_close { self.obv -= volume; }
        self.prev_close = close;
        self.history.push(self.obv);
        // Linear regression slope over history
        if self.history.len() < 2 { return 0.0; }
        let n = self.history.len() as f64;
        let (mut sx, mut sy, mut sxx, mut sxy) = (0.0, 0.0, 0.0, 0.0);
        for (i, &v) in self.history.iter().enumerate() {
            let x = i as f64;
            sx += x; sy += v; sxx += x * x; sxy += x * v;
        }
        let denom = n * sxx - sx * sx;
        if denom.abs() < 1e-10 { 0.0 } else { (n * sxy - sx * sy) / denom }
    }
}

// ─── The indicator bank ────────────────────────────────────────────────────

/// All indicator state in one struct. Stepped by one candle at a time.
pub struct IndicatorBank {
    sma20: SmaState,
    sma50: SmaState,
    sma200: SmaState,
    bb_stddev: RollingStddev, // exact population stddev over 20-period window
    ema20: EmaState,
    rsi: RsiState,
    macd: MacdState,
    dmi: DmiState,
    atr: AtrState,
    stoch: StochState,
    cci: CciState,
    mfi: MfiState,
    obv: ObvState,
    volume_sma20: SmaState,

    // ROC ring buffers
    roc_buf: RingBuffer,    // 12-period close buffer — ROC 1/3/6/12 index into this

    // Range position
    range_high_12: RingBuffer,
    range_low_12: RingBuffer,
    range_high_24: RingBuffer,
    range_low_24: RingBuffer,
    range_high_48: RingBuffer,
    range_low_48: RingBuffer,

    // Trend consistency
    trend_buf_24: RingBuffer, // close-over-close as 1.0/0.0

    // ATR history for ATR ROC
    atr_history: RingBuffer,

    // Multi-timeframe aggregation
    tf_1h_buf: RingBuffer,  // 12 candles of closes
    tf_1h_high: RingBuffer,
    tf_1h_low: RingBuffer,
    tf_4h_buf: RingBuffer,  // 48 candles of closes
    tf_4h_high: RingBuffer,
    tf_4h_low: RingBuffer,

    // Previous values for derived computations
    prev_close: f64,

    // Candle counter
    count: usize,
}

impl IndicatorBank {
    pub fn new() -> Self {
        Self {
            sma20: SmaState::new(20),
            sma50: SmaState::new(50),
            sma200: SmaState::new(200),
            bb_stddev: RollingStddev::new(20),
            ema20: EmaState::new(20),
            rsi: RsiState::new(14),
            macd: MacdState::new(),
            dmi: DmiState::new(14),
            atr: AtrState::new(14),
            stoch: StochState::new(14),
            cci: CciState::new(20),
            mfi: MfiState::new(14),
            obv: ObvState::new(12),
            volume_sma20: SmaState::new(20),
            roc_buf: RingBuffer::new(12),
            range_high_12: RingBuffer::new(12),
            range_low_12: RingBuffer::new(12),
            range_high_24: RingBuffer::new(24),
            range_low_24: RingBuffer::new(24),
            range_high_48: RingBuffer::new(48),
            range_low_48: RingBuffer::new(48),
            trend_buf_24: RingBuffer::new(24),
            atr_history: RingBuffer::new(12),
            tf_1h_buf: RingBuffer::new(12),
            tf_1h_high: RingBuffer::new(12),
            tf_1h_low: RingBuffer::new(12),
            tf_4h_buf: RingBuffer::new(48),
            tf_4h_high: RingBuffer::new(48),
            tf_4h_low: RingBuffer::new(48),
            prev_close: 0.0,
            count: 0,
        }
    }

    /// Advance all indicators by one raw candle. Produces a fully-computed Candle.
    pub fn tick(&mut self, raw: &RawCandle) -> Candle {
        let close = raw.close;
        let high = raw.high;
        let low = raw.low;
        let volume = raw.volume;

        // Core indicators
        let sma20 = self.sma20.step(close);
        let sma50 = self.sma50.step(close);
        let sma200 = self.sma200.step(close);

        // Bollinger: exact population stddev over 20-period window (matches build_candles)
        let bb_std = self.bb_stddev.step(close);
        let bb_upper = sma20 + 2.0 * bb_std;
        let bb_lower = sma20 - 2.0 * bb_std;
        let bb_width = if sma20.abs() > 1e-10 { (bb_upper - bb_lower) / sma20 } else { 0.0 };
        let bb_pos = if (bb_upper - bb_lower).abs() > 1e-10 { (close - bb_lower) / (bb_upper - bb_lower) } else { 0.5 };

        let ema20 = self.ema20.step(close);
        let rsi = self.rsi.step(close);
        let (macd_line, macd_signal, macd_hist) = self.macd.step(close);
        let (dmi_plus, dmi_minus, adx) = self.dmi.step(high, low, close);
        let atr = self.atr.step(high, low, close);
        let atr_r = if close.abs() > 1e-10 { atr / close } else { 0.0 };
        let (stoch_k, stoch_d, williams_r) = self.stoch.step(high, low, close);
        let cci = self.cci.step(high, low, close);
        let mfi = self.mfi.step(high, low, close, volume);
        let obv_slope_12 = self.obv.step(close, volume);
        let volume_sma_20 = self.volume_sma20.step(volume);

        // Keltner
        let kelt_upper = ema20 + 1.5 * atr;
        let kelt_lower = ema20 - 1.5 * atr;
        let kelt_range = (kelt_upper - kelt_lower).max(1e-10);
        let kelt_pos = (close - kelt_lower) / kelt_range;
        let squeeze = bb_upper < kelt_upper && bb_lower > kelt_lower;

        // ROC
        self.roc_buf.push(close);
        let roc_fn = |buf: &RingBuffer, period: usize| -> f64 {
            if buf.len() <= period { return 0.0; }
            let idx = buf.len() - 1 - period;
            let old = buf.buffer[idx];
            if old.abs() < 1e-10 { 0.0 } else { (close - old) / old }
        };
        let roc_1 = roc_fn(&self.roc_buf, 1);
        let roc_3 = roc_fn(&self.roc_buf, 3);
        let roc_6 = roc_fn(&self.roc_buf, 6);
        let roc_12 = if self.roc_buf.full() {
            let old = self.roc_buf.oldest();
            if old.abs() < 1e-10 { 0.0 } else { (close - old) / old }
        } else { 0.0 };

        // Range position
        self.range_high_12.push(high); self.range_low_12.push(low);
        self.range_high_24.push(high); self.range_low_24.push(low);
        self.range_high_48.push(high); self.range_low_48.push(low);
        let range_pos = |hi_buf: &RingBuffer, lo_buf: &RingBuffer| -> f64 {
            let hi = hi_buf.max();
            let lo = lo_buf.min();
            let range = hi - lo;
            if range < 1e-10 { 0.5 } else { (close - lo) / range }
        };
        let range_pos_12 = range_pos(&self.range_high_12, &self.range_low_12);
        let range_pos_24 = range_pos(&self.range_high_24, &self.range_low_24);
        let range_pos_48 = range_pos(&self.range_high_48, &self.range_low_48);

        // Trend consistency
        let trend_val = if self.count > 0 && close > self.prev_close { 1.0 } else { 0.0 };
        self.trend_buf_24.push(trend_val);
        let trend_sum = |n: usize, buf: &RingBuffer| -> f64 {
            if buf.len() < n { return 0.5; }
            let count = buf.buffer.iter().rev().take(n).filter(|&&v| v > 0.5).count();
            count as f64 / n as f64
        };
        let trend_consistency_6 = trend_sum(6, &self.trend_buf_24);
        let trend_consistency_12 = trend_sum(12, &self.trend_buf_24);
        let trend_consistency_24 = trend_sum(24, &self.trend_buf_24);

        // ATR ROC
        self.atr_history.push(atr);
        let atr_roc = |period: usize, buf: &RingBuffer| -> f64 {
            if buf.len() <= period { return 0.0; }
            let idx = buf.len() - 1 - period;
            let old = buf.buffer[idx];
            if old.abs() < 1e-10 { 0.0 } else { (atr - old) / old }
        };
        let atr_roc_6 = atr_roc(6, &self.atr_history);
        let atr_roc_12 = if self.atr_history.full() {
            let old = self.atr_history.oldest();
            if old.abs() < 1e-10 { 0.0 } else { (atr - old) / old }
        } else { 0.0 };

        // Volume acceleration
        let vol_accel = if volume_sma_20.abs() > 1e-10 { volume / volume_sma_20 } else { 1.0 };

        // Multi-timeframe
        self.tf_1h_buf.push(close); self.tf_1h_high.push(high); self.tf_1h_low.push(low);
        self.tf_4h_buf.push(close); self.tf_4h_high.push(high); self.tf_4h_low.push(low);
        let tf_close = |buf: &RingBuffer| buf.buffer.back().copied().unwrap_or(close);
        let tf_high = |buf: &RingBuffer| buf.max();
        let tf_low = |buf: &RingBuffer| buf.min();
        let tf_ret = |buf: &RingBuffer| -> f64 {
            if buf.len() < 2 { return 0.0; }
            let first = buf.buffer.front().copied().unwrap_or(close);
            if first.abs() < 1e-10 { 0.0 } else { (close - first) / first }
        };
        let tf_body = |buf: &RingBuffer| -> f64 {
            if buf.len() < 2 { return 0.0; }
            let first = buf.buffer.front().copied().unwrap_or(close);
            if first.abs() < 1e-10 { 0.0 } else { (close - first).abs() / first }
        };

        // Time
        let hour = parse_hour(&raw.ts);
        let day_of_week = parse_day_of_week(&raw.ts);

        self.prev_close = close;
        self.count += 1;

        Candle {
            ts: raw.ts.clone(),
            open: raw.open,
            high, low, close, volume,
            sma20, sma50, sma200,
            bb_upper, bb_lower, bb_width,
            rsi,
            macd_line, macd_signal, macd_hist,
            dmi_plus, dmi_minus, adx,
            atr, atr_r,
            stoch_k, stoch_d,
            williams_r,
            cci, mfi,
            roc_1, roc_3, roc_6, roc_12,
            obv_slope_12,
            volume_sma_20,
            tf_1h_close: tf_close(&self.tf_1h_buf),
            tf_1h_high: tf_high(&self.tf_1h_high),
            tf_1h_low: tf_low(&self.tf_1h_low),
            tf_1h_ret: tf_ret(&self.tf_1h_buf),
            tf_1h_body: tf_body(&self.tf_1h_buf),
            tf_4h_close: tf_close(&self.tf_4h_buf),
            tf_4h_high: tf_high(&self.tf_4h_high),
            tf_4h_low: tf_low(&self.tf_4h_low),
            tf_4h_ret: tf_ret(&self.tf_4h_buf),
            tf_4h_body: tf_body(&self.tf_4h_buf),
            bb_pos, kelt_upper, kelt_lower, kelt_pos,
            squeeze,
            range_pos_12, range_pos_24, range_pos_48,
            trend_consistency_6, trend_consistency_12, trend_consistency_24,
            atr_roc_6, atr_roc_12,
            vol_accel,
            hour, day_of_week,
        }
    }
}

// ─── Time parsing (same as candle.rs) ──────────────────────────────────────

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

// ─── Parquet loader ────────────────────────────────────────────────────────

#[cfg(feature = "parquet")]
/// Streams raw OHLCV candles from a parquet file.
/// No indicator computation — that's the desk's job.
pub struct ParquetRawStream {
    /// Buffered raw candles from the current parquet batch.
    buffer: Vec<RawCandle>,
    /// Position within current buffer.
    buf_idx: usize,
    /// Parquet batch reader (produces Arrow RecordBatches).
    reader: parquet::arrow::arrow_reader::ParquetRecordBatchReader,
}

#[cfg(feature = "parquet")]
impl ParquetRawStream {
    pub fn open(path: &std::path::Path) -> Self {
        use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
        let file = std::fs::File::open(path).expect("failed to open parquet");
        let builder = ParquetRecordBatchReaderBuilder::try_new(file).expect("failed to read parquet");
        let reader = builder.build().expect("failed to build reader");
        Self {
            buffer: Vec::new(),
            buf_idx: 0,
            reader,
        }
    }

    /// Total raw candles in the parquet file. Reads metadata only (no data scan).
    pub fn total_candles(path: &std::path::Path) -> usize {
        use parquet::file::reader::{FileReader, SerializedFileReader};
        let file = std::fs::File::open(path).expect("failed to open parquet for metadata");
        let reader = SerializedFileReader::new(file).expect("failed to read parquet metadata");
        reader.metadata().file_metadata().num_rows() as usize
    }

    /// Fill the buffer from the next parquet batch. Returns false when exhausted.
    fn fill_buffer(&mut self) -> bool {
        use arrow::array::{Float64Array, StringArray, Array, TimestampMicrosecondArray};

        loop {
            match self.reader.next() {
                Some(Ok(batch)) => {
                    if batch.num_rows() == 0 { continue; }
                    let ts_col = batch.column_by_name("ts").expect("missing ts");
                    let open_col = batch.column_by_name("open").expect("missing open");
                    let high_col = batch.column_by_name("high").expect("missing high");
                    let low_col = batch.column_by_name("low").expect("missing low");
                    let close_col = batch.column_by_name("close").expect("missing close");
                    let vol_col = batch.column_by_name("volume").expect("missing volume");

                    let ts_strings: Vec<String> = if let Some(arr) = ts_col.as_any().downcast_ref::<StringArray>() {
                        (0..arr.len()).map(|i| arr.value(i).to_string()).collect()
                    } else if let Some(arr) = ts_col.as_any().downcast_ref::<TimestampMicrosecondArray>() {
                        (0..arr.len()).map(|i| {
                            let micros = arr.value(i);
                            let secs = micros / 1_000_000;
                            let nsecs = ((micros % 1_000_000) * 1000) as u32;
                            chrono::DateTime::from_timestamp(secs, nsecs)
                                .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                                .unwrap_or_default()
                        }).collect()
                    } else {
                        panic!("unsupported timestamp column type");
                    };

                    let opens = open_col.as_any().downcast_ref::<Float64Array>().expect("open not f64");
                    let highs = high_col.as_any().downcast_ref::<Float64Array>().expect("high not f64");
                    let lows = low_col.as_any().downcast_ref::<Float64Array>().expect("low not f64");
                    let closes = close_col.as_any().downcast_ref::<Float64Array>().expect("close not f64");
                    let volumes = vol_col.as_any().downcast_ref::<Float64Array>().expect("volume not f64");

                    self.buffer.clear();
                    self.buf_idx = 0;
                    for i in 0..batch.num_rows() {
                        self.buffer.push(RawCandle {
                            ts: ts_strings[i].clone(),
                            open: opens.value(i),
                            high: highs.value(i),
                            low: lows.value(i),
                            close: closes.value(i),
                            volume: volumes.value(i),
                        });
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
impl Iterator for ParquetRawStream {
    type Item = RawCandle;

    fn next(&mut self) -> Option<RawCandle> {
        // If buffer exhausted, fill from next parquet batch
        if self.buf_idx >= self.buffer.len() {
            if !self.fill_buffer() { return None; }
        }
        let raw = self.buffer[self.buf_idx].clone();
        self.buf_idx += 1;
        Some(raw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compare_with_candles_db() {
        let path = std::path::Path::new("data/btc_5m_raw.parquet");
        if !path.exists() { eprintln!("skipping — no parquet"); return; }
        let stream = ParquetRawStream::open(path);
        let mut bank = IndicatorBank::new();
        
        for (i, raw) in stream.enumerate() {
            let c = bank.tick(&raw);
            if i == 250 {
                eprintln!("=== Streaming IndicatorBank at index 250 ===");
                eprintln!("ts={} close={:.1}", c.ts, c.close);
                eprintln!("sma20={:.5} sma50={:.5}", c.sma20, c.sma50);
                eprintln!("bb_upper={:.5} bb_lower={:.5}", c.bb_upper, c.bb_lower);
                eprintln!("rsi={:.5}", c.rsi);
                eprintln!("macd_line={:.5} macd_signal={:.5}", c.macd_line, c.macd_signal);
                eprintln!("atr={:.6} atr_r={:.8}", c.atr, c.atr_r);
                eprintln!("dmi+={:.5} dmi-={:.5} adx={:.5}", c.dmi_plus, c.dmi_minus, c.adx);
                eprintln!("stoch_k={:.5} cci={:.5} mfi={:.5}", c.stoch_k, c.cci, c.mfi);
                eprintln!("vol_sma20={:.5}", c.volume_sma_20);
                break;
            }
        }
    }
}
