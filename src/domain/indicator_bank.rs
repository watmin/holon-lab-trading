/// Streaming state machine for technical indicators.
/// Advances all indicators by one raw candle. Stateful.
/// One per post (one per asset pair).
///
/// Compiled from wat/indicator-bank.wat — the tick contract.

use crate::types::candle::Candle;
use crate::types::ohlcv::Ohlcv;
use crate::types::pivot::{PhaseRecord, PhaseState};

// ════════════════════════════════════════════════════════════════════
// STREAMING PRIMITIVES — the building blocks of indicator state
// ════════════════════════════════════════════════════════════════════

// ── RingBuffer ───────────────────────────────────────────────────

/// Fixed-capacity circular buffer. The fundamental storage primitive.
#[derive(Clone, Debug)]
pub struct RingBuffer {
    pub data: Vec<f64>,
    pub capacity: usize,
    pub head: usize,
    pub len: usize,
}

impl RingBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            data: vec![0.0; capacity],
            capacity,
            head: 0,
            len: 0,
        }
    }

    pub fn push(&mut self, value: f64) {
        self.data[self.head] = value;
        self.head = (self.head + 1) % self.capacity;
        if self.len < self.capacity {
            self.len += 1;
        }
    }

    pub fn is_full(&self) -> bool {
        self.len == self.capacity
    }

    /// ago 0 = most recent, ago (len-1) = oldest.
    pub fn get(&self, ago: usize) -> f64 {
        let idx = (self.head + self.capacity - 1 - ago) % self.capacity;
        self.data[idx]
    }

    pub fn newest(&self) -> f64 {
        self.get(0)
    }

    pub fn oldest(&self) -> f64 {
        self.get(self.len - 1)
    }

    pub fn max(&self) -> f64 {
        let mut mx = f64::NEG_INFINITY;
        for i in 0..self.len {
            mx = mx.max(self.get(i));
        }
        mx
    }

    pub fn min(&self) -> f64 {
        let mut mn = f64::INFINITY;
        for i in 0..self.len {
            mn = mn.min(self.get(i));
        }
        mn
    }

    pub fn sum(&self) -> f64 {
        let mut s = 0.0;
        for i in 0..self.len {
            s += self.get(i);
        }
        s
    }

    /// Return values from oldest to newest.
    pub fn to_vec(&self) -> Vec<f64> {
        let mut v = Vec::with_capacity(self.len);
        for i in (0..self.len).rev() {
            v.push(self.get(i));
        }
        v
    }

    /// Fill an existing Vec with values oldest to newest. Reuses allocation.
    pub fn fill_vec(&self, buf: &mut Vec<f64>) {
        buf.clear();
        for i in (0..self.len).rev() {
            buf.push(self.get(i));
        }
    }
}

// ── EmaState ─────────────────────────────────────────────────────

/// Exponential moving average. Uses SMA for the seed period.
#[derive(Clone, Debug)]
pub struct EmaState {
    pub value: f64,
    pub smoothing: f64,
    pub period: usize,
    pub count: usize,
    pub accum: f64,
}

impl EmaState {
    pub fn new(period: usize) -> Self {
        Self {
            value: 0.0,
            smoothing: 2.0 / (period as f64 + 1.0),
            period,
            count: 0,
            accum: 0.0,
        }
    }

    pub fn update(&mut self, value: f64) {
        self.count += 1;
        if self.count <= self.period {
            self.accum += value;
            if self.count == self.period {
                self.value = self.accum / self.period as f64;
            }
        } else {
            self.value = self.smoothing * value + (1.0 - self.smoothing) * self.value;
        }
    }

    pub fn ready(&self) -> bool {
        self.count >= self.period
    }
}

// ── WilderState ──────────────────────────────────────────────────

/// Wilder's smoothing method. Used by RSI, ATR, DMI.
#[derive(Clone, Debug)]
pub struct WilderState {
    pub value: f64,
    pub period: usize,
    pub count: usize,
    pub accum: f64,
}

impl WilderState {
    pub fn new(period: usize) -> Self {
        Self {
            value: 0.0,
            period,
            count: 0,
            accum: 0.0,
        }
    }

    pub fn update(&mut self, value: f64) {
        self.count += 1;
        let p = self.period as f64;
        if self.count <= self.period {
            self.accum += value;
            if self.count == self.period {
                self.value = self.accum / p;
            }
        } else {
            self.value = value / p + self.value * (p - 1.0) / p;
        }
    }

    pub fn ready(&self) -> bool {
        self.count >= self.period
    }
}

// ── SmaState ─────────────────────────────────────────────────────

/// Simple moving average. Period is the buffer's capacity.
#[derive(Clone, Debug)]
pub struct SmaState {
    pub buffer: RingBuffer,
    pub sum: f64,
}

impl SmaState {
    pub fn new(period: usize) -> Self {
        Self {
            buffer: RingBuffer::new(period),
            sum: 0.0,
        }
    }

    pub fn update(&mut self, value: f64) {
        if self.buffer.is_full() {
            self.sum -= self.buffer.oldest();
        }
        self.sum += value;
        self.buffer.push(value);
    }

    pub fn value(&self) -> f64 {
        if self.buffer.len == 0 {
            0.0
        } else {
            self.sum / self.buffer.len as f64
        }
    }

    pub fn ready(&self) -> bool {
        self.buffer.is_full()
    }
}

// ── RollingStddev ────────────────────────────────────────────────

/// Rolling standard deviation. Period is the buffer's capacity.
#[derive(Clone, Debug)]
pub struct RollingStddev {
    pub buffer: RingBuffer,
    pub sum: f64,
    pub sum_sq: f64,
}

impl RollingStddev {
    pub fn new(period: usize) -> Self {
        Self {
            buffer: RingBuffer::new(period),
            sum: 0.0,
            sum_sq: 0.0,
        }
    }

    pub fn update(&mut self, value: f64) {
        if self.buffer.is_full() {
            let old = self.buffer.oldest();
            self.sum -= old;
            self.sum_sq -= old * old;
        }
        self.sum += value;
        self.sum_sq += value * value;
        self.buffer.push(value);
    }

    pub fn value(&self) -> f64 {
        let n = self.buffer.len as f64;
        if n < 2.0 {
            return 0.0;
        }
        let mean = self.sum / n;
        let var = self.sum_sq / n - mean * mean;
        var.max(0.0).sqrt()
    }

    pub fn ready(&self) -> bool {
        self.buffer.is_full()
    }
}

// ── RsiState ─────────────────────────────────────────────────────

/// Wilder-smoothed relative strength index. Period 14.
#[derive(Clone, Debug)]
pub struct RsiState {
    pub gain_smoother: WilderState,
    pub loss_smoother: WilderState,
    pub prev_close: f64,
    pub started: bool,
}

impl RsiState {
    pub fn new(period: usize) -> Self {
        Self {
            gain_smoother: WilderState::new(period),
            loss_smoother: WilderState::new(period),
            prev_close: 0.0,
            started: false,
        }
    }

    pub fn update(&mut self, close: f64) {
        if self.started {
            let change = close - self.prev_close;
            let gain = change.max(0.0);
            let loss = (-change).max(0.0);
            self.gain_smoother.update(gain);
            self.loss_smoother.update(loss);
        }
        self.prev_close = close;
        self.started = true;
    }

    pub fn value(&self) -> f64 {
        let avg_gain = self.gain_smoother.value;
        let avg_loss = self.loss_smoother.value;
        if avg_loss == 0.0 {
            100.0
        } else {
            let rs = avg_gain / avg_loss;
            100.0 - 100.0 / (1.0 + rs)
        }
    }

    pub fn ready(&self) -> bool {
        self.started && self.gain_smoother.ready()
    }
}

// ── AtrState ─────────────────────────────────────────────────────

/// Wilder-smoothed true range. Period 14.
#[derive(Clone, Debug)]
pub struct AtrState {
    pub wilder: WilderState,
    pub prev_close: f64,
    pub started: bool,
}

impl AtrState {
    pub fn new(period: usize) -> Self {
        Self {
            wilder: WilderState::new(period),
            prev_close: 0.0,
            started: false,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        let tr = if self.started {
            (high - low)
                .max((high - self.prev_close).abs())
                .max((low - self.prev_close).abs())
        } else {
            high - low
        };
        self.wilder.update(tr);
        self.prev_close = close;
        self.started = true;
    }

    pub fn value(&self) -> f64 {
        self.wilder.value
    }

    pub fn ready(&self) -> bool {
        self.wilder.ready()
    }
}

// ── ObvState ─────────────────────────────────────────────────────

/// Cumulative on-balance volume with history for slope computation.
#[derive(Clone, Debug)]
pub struct ObvState {
    pub obv: f64,
    pub prev_close: f64,
    pub history: RingBuffer,
    pub started: bool,
}

impl ObvState {
    pub fn new(history_len: usize) -> Self {
        Self {
            obv: 0.0,
            prev_close: 0.0,
            history: RingBuffer::new(history_len),
            started: false,
        }
    }

    pub fn update(&mut self, close: f64, volume: f64) {
        if self.started {
            if close > self.prev_close {
                self.obv += volume;
            } else if close < self.prev_close {
                self.obv -= volume;
            }
        }
        self.history.push(self.obv);
        self.prev_close = close;
        self.started = true;
    }
}

// ── MacdState ────────────────────────────────────────────────────

/// MACD: fast EMA(12) - slow EMA(26). Signal = EMA(9) of MACD.
#[derive(Clone, Debug)]
pub struct MacdState {
    pub fast_ema: EmaState,
    pub slow_ema: EmaState,
    pub signal_ema: EmaState,
}

impl MacdState {
    pub fn new() -> Self {
        Self {
            fast_ema: EmaState::new(12),
            slow_ema: EmaState::new(26),
            signal_ema: EmaState::new(9),
        }
    }

    pub fn update(&mut self, close: f64) {
        self.fast_ema.update(close);
        self.slow_ema.update(close);
        if self.fast_ema.ready() && self.slow_ema.ready() {
            let macd_val = self.fast_ema.value - self.slow_ema.value;
            self.signal_ema.update(macd_val);
        }
    }

    pub fn macd_value(&self) -> f64 {
        self.fast_ema.value - self.slow_ema.value
    }

    pub fn signal_value(&self) -> f64 {
        self.signal_ema.value
    }

    pub fn hist_value(&self) -> f64 {
        self.macd_value() - self.signal_value()
    }

    pub fn ready(&self) -> bool {
        self.slow_ema.ready() && self.signal_ema.ready()
    }
}

// ── DmiState ─────────────────────────────────────────────────────

/// Wilder-smoothed +DI, -DI, ADX. Period 14.
#[derive(Clone, Debug)]
pub struct DmiState {
    pub plus_smoother: WilderState,
    pub minus_smoother: WilderState,
    pub tr_smoother: WilderState,
    pub adx_smoother: WilderState,
    pub prev_high: f64,
    pub prev_low: f64,
    pub prev_close: f64,
    pub started: bool,
    pub count: usize,
}

impl DmiState {
    pub fn new(period: usize) -> Self {
        Self {
            plus_smoother: WilderState::new(period),
            minus_smoother: WilderState::new(period),
            tr_smoother: WilderState::new(period),
            adx_smoother: WilderState::new(period),
            prev_high: 0.0,
            prev_low: 0.0,
            prev_close: 0.0,
            started: false,
            count: 0,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        if self.started {
            let up_move = high - self.prev_high;
            let down_move = self.prev_low - low;
            let plus_dm = if up_move > down_move && up_move > 0.0 {
                up_move
            } else {
                0.0
            };
            let minus_dm = if down_move > up_move && down_move > 0.0 {
                down_move
            } else {
                0.0
            };
            let tr = (high - low)
                .max((high - self.prev_close).abs())
                .max((low - self.prev_close).abs());

            self.plus_smoother.update(plus_dm);
            self.minus_smoother.update(minus_dm);
            self.tr_smoother.update(tr);

            // ADX: smooth the DX after the DI smoothers are ready
            if self.tr_smoother.ready() {
                let smoothed_tr = self.tr_smoother.value;
                if smoothed_tr > 0.0 {
                    let plus_di = 100.0 * self.plus_smoother.value / smoothed_tr;
                    let minus_di = 100.0 * self.minus_smoother.value / smoothed_tr;
                    let di_sum = plus_di + minus_di;
                    if di_sum > 0.0 {
                        let dx = 100.0 * (plus_di - minus_di).abs() / di_sum;
                        self.adx_smoother.update(dx);
                    }
                }
            }
        }
        self.prev_high = high;
        self.prev_low = low;
        self.prev_close = close;
        self.started = true;
        self.count += 1;
    }

    pub fn plus_di(&self) -> f64 {
        let tr = self.tr_smoother.value;
        if tr == 0.0 {
            0.0
        } else {
            100.0 * self.plus_smoother.value / tr
        }
    }

    pub fn minus_di(&self) -> f64 {
        let tr = self.tr_smoother.value;
        if tr == 0.0 {
            0.0
        } else {
            100.0 * self.minus_smoother.value / tr
        }
    }

    pub fn adx(&self) -> f64 {
        self.adx_smoother.value
    }

    pub fn ready(&self) -> bool {
        self.adx_smoother.ready()
    }
}

// ── StochState ───────────────────────────────────────────────────

/// Stochastic oscillator. %K period 14, %D = SMA(3) of %K.
#[derive(Clone, Debug)]
pub struct StochState {
    pub high_buf: RingBuffer,
    pub low_buf: RingBuffer,
    pub k_buf: RingBuffer,
}

impl StochState {
    pub fn new(period: usize, d_period: usize) -> Self {
        Self {
            high_buf: RingBuffer::new(period),
            low_buf: RingBuffer::new(period),
            k_buf: RingBuffer::new(d_period),
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        self.high_buf.push(high);
        self.low_buf.push(low);
        if self.high_buf.is_full() {
            let highest = self.high_buf.max();
            let lowest = self.low_buf.min();
            let range = highest - lowest;
            let k = if range == 0.0 {
                50.0
            } else {
                100.0 * (close - lowest) / range
            };
            self.k_buf.push(k);
        }
    }

    pub fn k(&self) -> f64 {
        if self.k_buf.len == 0 {
            50.0
        } else {
            self.k_buf.newest()
        }
    }

    pub fn d(&self) -> f64 {
        if self.k_buf.len == 0 {
            50.0
        } else {
            self.k_buf.sum() / self.k_buf.len as f64
        }
    }

    pub fn ready(&self) -> bool {
        self.high_buf.is_full() && self.k_buf.is_full()
    }
}

// ── CciState ─────────────────────────────────────────────────────

/// Commodity Channel Index. Period 20.
#[derive(Clone, Debug)]
pub struct CciState {
    pub tp_buf: RingBuffer,
    pub tp_sma: SmaState,
}

impl CciState {
    pub fn new(period: usize) -> Self {
        Self {
            tp_buf: RingBuffer::new(period),
            tp_sma: SmaState::new(period),
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        let tp = (high + low + close) / 3.0;
        self.tp_buf.push(tp);
        self.tp_sma.update(tp);
    }

    pub fn value(&self) -> f64 {
        if !self.tp_sma.ready() {
            return 0.0;
        }
        let tp_mean = self.tp_sma.value();
        let tp_latest = self.tp_buf.newest();
        // Mean deviation
        let n = self.tp_buf.len;
        let mut mean_dev = 0.0;
        for i in 0..n {
            mean_dev += (self.tp_buf.get(i) - tp_mean).abs();
        }
        mean_dev /= n as f64;
        if mean_dev == 0.0 {
            0.0
        } else {
            (tp_latest - tp_mean) / (0.015 * mean_dev)
        }
    }

    pub fn ready(&self) -> bool {
        self.tp_sma.ready()
    }
}

// ── MfiState ─────────────────────────────────────────────────────

/// Money Flow Index. Period 14.
#[derive(Clone, Debug)]
pub struct MfiState {
    pub pos_flow_buf: RingBuffer,
    pub neg_flow_buf: RingBuffer,
    pub prev_tp: f64,
    pub started: bool,
}

impl MfiState {
    pub fn new(period: usize) -> Self {
        Self {
            pos_flow_buf: RingBuffer::new(period),
            neg_flow_buf: RingBuffer::new(period),
            prev_tp: 0.0,
            started: false,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64, volume: f64) {
        let tp = (high + low + close) / 3.0;
        let raw_flow = tp * volume;
        if self.started {
            if tp > self.prev_tp {
                self.pos_flow_buf.push(raw_flow);
                self.neg_flow_buf.push(0.0);
            } else {
                self.pos_flow_buf.push(0.0);
                self.neg_flow_buf.push(raw_flow);
            }
        }
        self.prev_tp = tp;
        self.started = true;
    }

    pub fn value(&self) -> f64 {
        let pos_sum = self.pos_flow_buf.sum();
        let neg_sum = self.neg_flow_buf.sum();
        if neg_sum == 0.0 {
            100.0
        } else {
            let mf_ratio = pos_sum / neg_sum;
            100.0 - 100.0 / (1.0 + mf_ratio)
        }
    }

    pub fn ready(&self) -> bool {
        self.started && self.pos_flow_buf.is_full()
    }
}

// ── IchimokuState ────────────────────────────────────────────────

/// Ichimoku Cloud. Periods: 9 (tenkan), 26 (kijun), 52 (senkou-b).
#[derive(Clone, Debug)]
pub struct IchimokuState {
    pub high_9: RingBuffer,
    pub low_9: RingBuffer,
    pub high_26: RingBuffer,
    pub low_26: RingBuffer,
    pub high_52: RingBuffer,
    pub low_52: RingBuffer,
}

impl IchimokuState {
    pub fn new() -> Self {
        Self {
            high_9: RingBuffer::new(9),
            low_9: RingBuffer::new(9),
            high_26: RingBuffer::new(26),
            low_26: RingBuffer::new(26),
            high_52: RingBuffer::new(52),
            low_52: RingBuffer::new(52),
        }
    }

    pub fn update(&mut self, high: f64, low: f64) {
        self.high_9.push(high);
        self.low_9.push(low);
        self.high_26.push(high);
        self.low_26.push(low);
        self.high_52.push(high);
        self.low_52.push(low);
    }

    pub fn tenkan(&self) -> f64 {
        (self.high_9.max() + self.low_9.min()) / 2.0
    }

    pub fn kijun(&self) -> f64 {
        (self.high_26.max() + self.low_26.min()) / 2.0
    }

    pub fn senkou_a(&self) -> f64 {
        (self.tenkan() + self.kijun()) / 2.0
    }

    pub fn senkou_b(&self) -> f64 {
        (self.high_52.max() + self.low_52.min()) / 2.0
    }

    pub fn ready(&self) -> bool {
        self.high_52.is_full()
    }
}

// ════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ════════════════════════════════════════════════════════════════════

/// Linear regression slope of a slice (indices 0..n as x, values as y).
pub fn linreg_slope(ys: &[f64]) -> f64 {
    let n = ys.len();
    if n < 2 {
        return 0.0;
    }
    let nf = n as f64;
    let x_mean = (nf - 1.0) / 2.0;
    let y_mean: f64 = ys.iter().sum::<f64>() / nf;
    let mut num = 0.0;
    let mut den = 0.0;
    for (i, &y) in ys.iter().enumerate() {
        let dx = i as f64 - x_mean;
        num += dx * (y - y_mean);
        den += dx * dx;
    }
    if den == 0.0 {
        0.0
    } else {
        num / den
    }
}

/// OBV slope over its history buffer.
fn obv_slope_12(vals: &[f64]) -> f64 {
    if vals.len() < 3 {
        return 0.0;
    }
    linreg_slope(vals)
}

/// Hurst exponent via R/S analysis.
fn hurst_exponent(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 8 {
        return 0.5;
    }
    // Compute returns
    let mut returns = Vec::with_capacity(n - 1);
    for i in 0..n - 1 {
        if values[i] == 0.0 {
            returns.push(0.0);
        } else {
            returns.push((values[i + 1] - values[i]) / values[i]);
        }
    }
    let rn = returns.len();
    let mu: f64 = returns.iter().sum::<f64>() / rn as f64;
    // Cumulative deviations
    let mut cum_dev = Vec::with_capacity(rn);
    let mut running = 0.0;
    for r in &returns {
        running += r - mu;
        cum_dev.push(running);
    }
    let r = cum_dev
        .iter()
        .cloned()
        .fold(f64::NEG_INFINITY, f64::max)
        - cum_dev
            .iter()
            .cloned()
            .fold(f64::INFINITY, f64::min);
    let s = {
        let var: f64 = returns.iter().map(|x| (x - mu) * (x - mu)).sum::<f64>() / rn as f64;
        var.sqrt()
    };
    if s == 0.0 {
        0.5
    } else {
        let rs = r / s;
        if rs <= 0.0 {
            0.5
        } else {
            rs.ln() / (rn as f64).ln()
        }
    }
}

/// Lag-1 autocorrelation.
fn autocorrelation_lag1(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 3 {
        return 0.0;
    }
    let mu: f64 = values.iter().sum::<f64>() / n as f64;
    let var: f64 = values.iter().map(|v| (v - mu) * (v - mu)).sum::<f64>() / n as f64;
    if var == 0.0 {
        return 0.0;
    }
    let mut cov = 0.0;
    for i in 0..n - 1 {
        cov += (values[i] - mu) * (values[i + 1] - mu);
    }
    cov /= (n - 1) as f64;
    cov / var
}

/// DFA fluctuation at a given segment length.
fn dfa_fluctuation(cum_dev: &[f64], seg_len: usize) -> f64 {
    let n = cum_dev.len();
    let num_segs = n / seg_len;
    if num_segs == 0 {
        return 0.0;
    }
    let mut variances = Vec::new();
    for s in 0..num_segs {
        let start = s * seg_len;
        if start + seg_len > n {
            break;
        }
        let segment: Vec<f64> = (0..seg_len).map(|i| cum_dev[start + i]).collect();
        let detrended = linear_detrend(&segment);
        let var = variance_of(&detrended);
        variances.push(var);
    }
    if variances.is_empty() {
        0.0
    } else {
        let mean_var: f64 = variances.iter().sum::<f64>() / variances.len() as f64;
        mean_var.sqrt()
    }
}

/// Subtract best-fit line from xs.
fn linear_detrend(xs: &[f64]) -> Vec<f64> {
    let n = xs.len();
    if n < 2 {
        return xs.to_vec();
    }
    let nf = n as f64;
    let x_mean = (nf - 1.0) / 2.0;
    let y_mean: f64 = xs.iter().sum::<f64>() / nf;
    let mut num = 0.0;
    let mut den = 0.0;
    for (i, &y) in xs.iter().enumerate() {
        let dx = i as f64 - x_mean;
        num += dx * (y - y_mean);
        den += dx * dx;
    }
    let slope = if den == 0.0 { 0.0 } else { num / den };
    let intercept = y_mean - slope * x_mean;
    xs.iter()
        .enumerate()
        .map(|(i, &y)| y - (intercept + slope * i as f64))
        .collect()
}

/// DFA alpha exponent.
fn dfa_alpha(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 16 {
        return 0.5;
    }
    let mu: f64 = values.iter().sum::<f64>() / n as f64;
    // Cumulative deviation from mean
    let mut cum_dev = Vec::with_capacity(n + 1);
    cum_dev.push(0.0);
    for &p in values {
        let last = *cum_dev.last().unwrap();
        cum_dev.push(last + (p - mu));
    }
    let f1 = dfa_fluctuation(&cum_dev, 4);
    let f2 = dfa_fluctuation(&cum_dev, 8);
    if f1 <= 0.0 || f2 <= 0.0 {
        0.5
    } else {
        (f2 / f1).ln() / 2.0f64.ln()
    }
}

/// Variance of a slice.
fn variance_of(vals: &[f64]) -> f64 {
    if vals.len() < 2 {
        return 0.0;
    }
    let m: f64 = vals.iter().sum::<f64>() / vals.len() as f64;
    vals.iter().map(|v| (v - m) * (v - m)).sum::<f64>() / vals.len() as f64
}

/// Variance ratio: var(N-step returns) / (N * var(1-step returns)).
fn variance_ratio(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 10 {
        return 1.0;
    }
    // Log returns scale 1
    let returns_1: Vec<f64> = (0..n - 1)
        .map(|i| {
            if values[i] == 0.0 {
                0.0
            } else {
                (values[i + 1] / values[i]).ln()
            }
        })
        .collect();
    // Log returns scale 5
    let returns_5: Vec<f64> = (0..n.saturating_sub(5))
        .map(|i| {
            if values[i] == 0.0 {
                0.0
            } else {
                (values[i + 5] / values[i]).ln()
            }
        })
        .collect();
    let var_1 = variance_of(&returns_1);
    let var_5 = variance_of(&returns_5);
    if var_1 == 0.0 {
        1.0
    } else {
        var_5 / (5.0 * var_1)
    }
}

/// Entropy rate of discretized returns.
fn entropy_rate(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 5 {
        return 1.0;
    }
    let vals = values;
    // Count occurrences of each bin
    let bins = [-2.0f64, -1.0, 0.0, 1.0, 2.0];
    let nf = n as f64;
    let mut entropy = 0.0;
    for &b in &bins {
        let count = vals.iter().filter(|&&v| v == b).count() as f64;
        if count > 0.0 {
            let p = count / nf;
            entropy -= p * p.ln();
        }
    }
    entropy
}

/// KAMA efficiency ratio over a price buffer.
fn kama_efficiency_ratio(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 2 {
        return 0.5;
    }
    let direction = (values[n - 1] - values[0]).abs();
    let mut volatility = 0.0;
    for i in 0..n - 1 {
        volatility += (values[i + 1] - values[i]).abs();
    }
    if volatility == 0.0 {
        1.0
    } else {
        direction / volatility
    }
}

/// Choppiness index.
fn choppiness_index(atr_sum: f64, high_buf: &RingBuffer, low_buf: &RingBuffer) -> f64 {
    let highest = high_buf.max();
    let lowest = low_buf.min();
    let range_val = highest - lowest;
    if range_val == 0.0 || atr_sum <= 0.0 {
        50.0
    } else {
        100.0 * (atr_sum / range_val).ln() / 14.0f64.ln()
    }
}

/// Aroon up — how recently was the highest high.
fn aroon_up(vals: &[f64]) -> f64 {
    if vals.is_empty() {
        return 50.0;
    }
    let n = vals.len();
    let max_val = vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    // Find most recent index of max (oldest first)
    let mut idx = 0;
    for (i, &v) in vals.iter().enumerate() {
        if v == max_val {
            idx = i;
        }
    }
    100.0 * idx as f64 / (n - 1).max(1) as f64
}

/// Aroon down — how recently was the lowest low.
fn aroon_down(vals: &[f64]) -> f64 {
    if vals.is_empty() {
        return 50.0;
    }
    let n = vals.len();
    let min_val = vals.iter().cloned().fold(f64::INFINITY, f64::min);
    let mut idx = 0;
    for (i, &v) in vals.iter().enumerate() {
        if v == min_val {
            idx = i;
        }
    }
    100.0 * idx as f64 / (n - 1).max(1) as f64
}

/// Fractal dimension via Higuchi method.
fn fractal_dimension(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 10 {
        return 1.5;
    }
    let l1 = higuchi_length(values, 1);
    let l4 = higuchi_length(values, 4);
    if l1 <= 0.0 || l4 <= 0.0 {
        1.5
    } else {
        let d = (l1 / l4).ln() / 4.0f64.ln();
        d.clamp(1.0, 2.0)
    }
}

/// Average curve length at scale k (Higuchi).
fn higuchi_length(prices: &[f64], k: usize) -> f64 {
    let n = prices.len();
    if k == 0 || n <= k {
        return 0.0;
    }
    let mut lengths = Vec::new();
    for m in 0..k {
        let num_steps = (n - 1 - m) / k;
        if num_steps == 0 {
            continue;
        }
        let mut sum = 0.0;
        for i in 0..num_steps {
            sum += (prices[m + (i + 1) * k] - prices[m + i * k]).abs();
        }
        let l = sum * (n - 1) as f64 / (num_steps * k * k) as f64;
        lengths.push(l);
    }
    if lengths.is_empty() {
        0.0
    } else {
        lengths.iter().sum::<f64>() / lengths.len() as f64
    }
}

/// Divergence detection between price and RSI slices.
fn detect_divergence(prices: &[f64], rsis: &[f64]) -> (f64, f64) {
    let n = prices.len().min(rsis.len());
    if n < 5 {
        return (0.0, 0.0);
    }
    let half = n / 2;
    let first_prices = &prices[..half];
    let second_prices = &prices[half..n];
    let first_rsis = &rsis[..half];
    let second_rsis = &rsis[half..n];

    let price_low_1 = first_prices.iter().cloned().fold(f64::INFINITY, f64::min);
    let price_low_2 = second_prices.iter().cloned().fold(f64::INFINITY, f64::min);
    let rsi_low_1 = first_rsis.iter().cloned().fold(f64::INFINITY, f64::min);
    let rsi_low_2 = second_rsis.iter().cloned().fold(f64::INFINITY, f64::min);

    let price_high_1 = first_prices.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let price_high_2 = second_prices.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let rsi_high_1 = first_rsis.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let rsi_high_2 = second_rsis.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

    // Bull: price lower low, RSI higher low
    let bull = if price_low_2 < price_low_1 && rsi_low_2 > rsi_low_1 {
        ((price_low_2 - price_low_1) - (rsi_low_2 - rsi_low_1)).abs()
    } else {
        0.0
    };
    // Bear: price higher high, RSI lower high
    let bear = if price_high_2 > price_high_1 && rsi_high_2 < rsi_high_1 {
        ((price_high_2 - price_high_1) - (rsi_high_2 - rsi_high_1)).abs()
    } else {
        0.0
    };
    (bull, bear)
}

/// ROC helper: rate of change at lag n.
fn compute_roc(buf: &RingBuffer, n: usize) -> f64 {
    if buf.len < n + 1 {
        return 0.0;
    }
    let current = buf.newest();
    let past = buf.get(n);
    if past == 0.0 {
        0.0
    } else {
        (current - past) / past
    }
}

/// Range position: (close - lowest) / (highest - lowest).
fn compute_range_pos(high_buf: &RingBuffer, low_buf: &RingBuffer, close: f64) -> f64 {
    let highest = high_buf.max();
    let lowest = low_buf.min();
    let range = highest - lowest;
    if range == 0.0 {
        0.5
    } else {
        (close - lowest) / range
    }
}

/// Timeframe return.
fn compute_tf_ret(buf: &RingBuffer) -> f64 {
    if buf.len < 2 {
        return 0.0;
    }
    let oldest = buf.oldest();
    let newest = buf.newest();
    if oldest == 0.0 {
        0.0
    } else {
        (newest - oldest) / oldest
    }
}

/// Timeframe body ratio.
fn compute_tf_body(buf: &RingBuffer) -> f64 {
    if buf.len < 2 {
        return 0.0;
    }
    let open_val = buf.oldest();
    let close_val = buf.newest();
    let high_val = buf.max();
    let low_val = buf.min();
    let range = high_val - low_val;
    if range == 0.0 {
        0.0
    } else {
        (close_val - open_val).abs() / range
    }
}

/// Timeframe agreement across 5m/1h/4h.
fn compute_tf_agreement(prev_close: f64, close: f64, tf_1h_buf: &RingBuffer, tf_4h_buf: &RingBuffer) -> f64 {
    let ret_5m = if prev_close == 0.0 {
        0.0
    } else {
        (close - prev_close) / prev_close
    };
    let ret_1h = compute_tf_ret(tf_1h_buf);
    let ret_4h = compute_tf_ret(tf_4h_buf);
    let signum = |x: f64| -> f64 {
        if x > 0.0 {
            1.0
        } else if x < 0.0 {
            -1.0
        } else {
            0.0
        }
    };
    let s5 = signum(ret_5m);
    let s1 = signum(ret_1h);
    let s4 = signum(ret_4h);
    (s5 * s1 + s5 * s4 + s1 * s4) / 3.0
}

/// Williams %R from stoch high/low buffers.
fn compute_williams_r(stoch: &StochState, close: f64) -> f64 {
    if !stoch.high_buf.is_full() {
        return -50.0;
    }
    let highest = stoch.high_buf.max();
    let lowest = stoch.low_buf.min();
    let range = highest - lowest;
    if range == 0.0 {
        -50.0
    } else {
        -100.0 * (highest - close) / range
    }
}

/// VWAP distance.
fn compute_vwap_distance(cum_vol: f64, cum_pv: f64, close: f64) -> f64 {
    if cum_vol == 0.0 {
        0.0
    } else {
        let vwap = cum_pv / cum_vol;
        if close == 0.0 {
            0.0
        } else {
            (close - vwap) / close
        }
    }
}

// ── Time parsing ──────────────────────────────────────────────────

fn parse_minute(ts: &str) -> f64 {
    if ts.len() >= 16 {
        ts[14..16].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

fn parse_hour(ts: &str) -> f64 {
    if ts.len() >= 13 {
        ts[11..13].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

fn parse_day_of_month(ts: &str) -> f64 {
    if ts.len() >= 10 {
        ts[8..10].parse::<f64>().unwrap_or(1.0)
    } else {
        1.0
    }
}

fn parse_month_of_year(ts: &str) -> f64 {
    if ts.len() >= 7 {
        ts[5..7].parse::<f64>().unwrap_or(1.0)
    } else {
        1.0
    }
}

/// Day of week via Zeller's congruence (0=Mon..6=Sun).
fn parse_day_of_week(ts: &str) -> f64 {
    if ts.len() < 10 {
        return 0.0;
    }
    let y: i64 = ts[0..4].parse().unwrap_or(2024);
    let m: i64 = ts[5..7].parse().unwrap_or(1);
    let d: i64 = ts[8..10].parse().unwrap_or(1);
    let (y_adj, m_adj) = if m <= 2 { (y - 1, m + 12) } else { (y, m) };
    let q = d;
    let k = y_adj % 100;
    let j = y_adj / 100;
    let h = (q + (13 * (m_adj + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7;
    // h: 0=Sat,1=Sun,2=Mon,...,6=Fri -> convert to 0=Mon,...,6=Sun
    ((h + 5) % 7) as f64
}

// ════════════════════════════════════════════════════════════════════
// INDICATOR BANK — composed from the streaming primitives
// ════════════════════════════════════════════════════════════════════

#[derive(Clone, Debug)]
pub struct IndicatorBank {
    // Moving averages
    pub sma20: SmaState,
    pub sma50: SmaState,
    pub sma200: SmaState,
    pub ema20: EmaState,
    // Bollinger
    pub bb_stddev: RollingStddev,
    // Oscillators
    pub rsi: RsiState,
    pub macd: MacdState,
    pub dmi: DmiState,
    pub atr: AtrState,
    pub stoch: StochState,
    pub cci: CciState,
    pub mfi: MfiState,
    pub obv: ObvState,
    pub volume_sma20: SmaState,
    // ROC
    pub roc_buf: RingBuffer,
    // Range position
    pub range_high_12: RingBuffer,
    pub range_low_12: RingBuffer,
    pub range_high_24: RingBuffer,
    pub range_low_24: RingBuffer,
    pub range_high_48: RingBuffer,
    pub range_low_48: RingBuffer,
    // Trend consistency
    pub trend_buf_24: RingBuffer,
    // ATR history
    pub atr_history: RingBuffer,
    // Multi-timeframe
    pub tf_1h_buf: RingBuffer,
    pub tf_1h_high: RingBuffer,
    pub tf_1h_low: RingBuffer,
    pub tf_4h_buf: RingBuffer,
    pub tf_4h_high: RingBuffer,
    pub tf_4h_low: RingBuffer,
    // Ichimoku
    pub ichimoku: IchimokuState,
    // Persistence
    pub close_buf_48: RingBuffer,
    // VWAP
    pub vwap_cum_vol: f64,
    pub vwap_cum_pv: f64,
    // Regime
    pub kama_er_buf: RingBuffer,
    pub chop_atr_sum: f64,
    pub chop_buf: RingBuffer,
    pub dfa_buf: RingBuffer,
    pub var_ratio_buf: RingBuffer,
    pub entropy_buf: RingBuffer,
    pub aroon_high_buf: RingBuffer,
    pub aroon_low_buf: RingBuffer,
    pub fractal_buf: RingBuffer,
    // Divergence
    pub rsi_peak_buf: RingBuffer,
    pub price_peak_buf: RingBuffer,
    // Cross deltas
    pub prev_tk_spread: f64,
    pub prev_stoch_kd: f64,
    // Price action
    pub prev_range: f64,
    pub consecutive_up_count: usize,
    pub consecutive_down_count: usize,
    // Timeframe agreement
    pub prev_tf_1h_ret: f64,
    pub prev_tf_4h_ret: f64,
    // Previous values
    pub prev_close: f64,
    // Phase labeler
    pub phase_state: PhaseState,
    // Phase history cache — only re-clone when generation changes
    pub last_phase_generation: u64,
    pub cached_phase_history: Vec<PhaseRecord>,
    // Scratch buffer — reused across indicator computations to avoid allocation
    scratch: Vec<f64>,
    // Counter
    pub count: usize,
}

impl IndicatorBank {
    pub fn new() -> Self {
        Self {
            // Moving averages
            sma20: SmaState::new(20),
            sma50: SmaState::new(50),
            sma200: SmaState::new(200),
            ema20: EmaState::new(20),
            // Bollinger
            bb_stddev: RollingStddev::new(20),
            // Oscillators
            rsi: RsiState::new(14),
            macd: MacdState::new(),
            dmi: DmiState::new(14),
            atr: AtrState::new(14),
            stoch: StochState::new(14, 3),
            cci: CciState::new(20),
            mfi: MfiState::new(14),
            obv: ObvState::new(12),
            volume_sma20: SmaState::new(20),
            // ROC
            roc_buf: RingBuffer::new(12),
            // Range position
            range_high_12: RingBuffer::new(12),
            range_low_12: RingBuffer::new(12),
            range_high_24: RingBuffer::new(24),
            range_low_24: RingBuffer::new(24),
            range_high_48: RingBuffer::new(48),
            range_low_48: RingBuffer::new(48),
            // Trend consistency
            trend_buf_24: RingBuffer::new(24),
            // ATR history
            atr_history: RingBuffer::new(12),
            // Multi-timeframe: 1h = 12 candles, 4h = 48 candles
            tf_1h_buf: RingBuffer::new(12),
            tf_1h_high: RingBuffer::new(12),
            tf_1h_low: RingBuffer::new(12),
            tf_4h_buf: RingBuffer::new(48),
            tf_4h_high: RingBuffer::new(48),
            tf_4h_low: RingBuffer::new(48),
            // Ichimoku
            ichimoku: IchimokuState::new(),
            // Persistence
            close_buf_48: RingBuffer::new(48),
            // VWAP
            vwap_cum_vol: 0.0,
            vwap_cum_pv: 0.0,
            // Regime
            kama_er_buf: RingBuffer::new(10),
            chop_atr_sum: 0.0,
            chop_buf: RingBuffer::new(14),
            dfa_buf: RingBuffer::new(48),
            var_ratio_buf: RingBuffer::new(30),
            entropy_buf: RingBuffer::new(30),
            aroon_high_buf: RingBuffer::new(25),
            aroon_low_buf: RingBuffer::new(25),
            fractal_buf: RingBuffer::new(30),
            // Divergence
            rsi_peak_buf: RingBuffer::new(20),
            price_peak_buf: RingBuffer::new(20),
            // Cross deltas
            prev_tk_spread: 0.0,
            prev_stoch_kd: 0.0,
            // Price action
            prev_range: 0.0,
            consecutive_up_count: 0,
            consecutive_down_count: 0,
            // Timeframe agreement
            prev_tf_1h_ret: 0.0,
            prev_tf_4h_ret: 0.0,
            // Previous values
            prev_close: 0.0,
            // Phase labeler
            phase_state: PhaseState::new(),
            // Phase history cache
            last_phase_generation: 0,
            cached_phase_history: Vec::new(),
            // Scratch buffer — capacity = largest ring buffer (48)
            scratch: Vec::with_capacity(48),
            // Counter
            count: 0,
        }
    }

    // ════════════════════════════════════════════════════════════════
    // STEP FUNCTIONS — the tick waterfall, one per indicator family
    // ════════════════════════════════════════════════════════════════

    fn step_sma(&mut self, close: f64) {
        self.sma20.update(close);
        self.sma50.update(close);
        self.sma200.update(close);
        self.ema20.update(close);
    }

    fn step_bollinger(&mut self, close: f64) {
        self.bb_stddev.update(close);
    }

    fn step_rsi(&mut self, close: f64) {
        self.rsi.update(close);
    }

    fn step_macd(&mut self, close: f64) {
        self.macd.update(close);
    }

    fn step_dmi(&mut self, high: f64, low: f64, close: f64) {
        self.dmi.update(high, low, close);
    }

    fn step_atr(&mut self, high: f64, low: f64, close: f64) {
        self.atr.update(high, low, close);
        if self.atr.ready() {
            self.atr_history.push(self.atr.value());
        }
    }

    fn step_stoch(&mut self, high: f64, low: f64, close: f64) {
        self.stoch.update(high, low, close);
    }

    fn step_cci(&mut self, high: f64, low: f64, close: f64) {
        self.cci.update(high, low, close);
    }

    fn step_mfi(&mut self, high: f64, low: f64, close: f64, volume: f64) {
        self.mfi.update(high, low, close, volume);
    }

    fn step_obv(&mut self, close: f64, volume: f64) {
        self.obv.update(close, volume);
    }

    fn step_volume_sma(&mut self, volume: f64) {
        self.volume_sma20.update(volume);
    }

    fn step_roc(&mut self, close: f64) {
        self.roc_buf.push(close);
    }

    fn step_range_pos(&mut self, high: f64, low: f64) {
        self.range_high_12.push(high);
        self.range_low_12.push(low);
        self.range_high_24.push(high);
        self.range_low_24.push(low);
        self.range_high_48.push(high);
        self.range_low_48.push(low);
    }

    fn step_trend_consistency(&mut self, close: f64) {
        let bullish = if close > self.prev_close { 1.0 } else { 0.0 };
        self.trend_buf_24.push(bullish);
    }

    fn step_timeframe(&mut self, close: f64, high: f64, low: f64) {
        self.tf_1h_buf.push(close);
        self.tf_1h_high.push(high);
        self.tf_1h_low.push(low);
        self.tf_4h_buf.push(close);
        self.tf_4h_high.push(high);
        self.tf_4h_low.push(low);
    }

    fn step_ichimoku(&mut self, high: f64, low: f64) {
        self.ichimoku.update(high, low);
    }

    fn step_persistence(&mut self, close: f64) {
        self.close_buf_48.push(close);
    }

    fn step_vwap(&mut self, close: f64, volume: f64) {
        self.vwap_cum_vol += volume;
        self.vwap_cum_pv += close * volume;
    }

    fn step_kama_er(&mut self, close: f64) {
        self.kama_er_buf.push(close);
    }

    fn step_choppiness(&mut self) {
        if self.atr.ready() {
            let current_atr = self.atr.value();
            if self.chop_buf.is_full() {
                self.chop_atr_sum -= self.chop_buf.oldest();
            }
            self.chop_atr_sum += current_atr;
            self.chop_buf.push(current_atr);
        }
    }

    fn step_dfa(&mut self, close: f64) {
        self.dfa_buf.push(close);
    }

    fn step_var_ratio(&mut self, close: f64) {
        self.var_ratio_buf.push(close);
    }

    fn step_entropy(&mut self, close: f64) {
        let ret = if self.prev_close == 0.0 {
            0.0
        } else {
            (close - self.prev_close) / self.prev_close
        };
        let bin = if ret < -0.005 {
            -2.0
        } else if ret < -0.001 {
            -1.0
        } else if ret < 0.001 {
            0.0
        } else if ret < 0.005 {
            1.0
        } else {
            2.0
        };
        self.entropy_buf.push(bin);
    }

    fn step_aroon(&mut self, high: f64, low: f64) {
        self.aroon_high_buf.push(high);
        self.aroon_low_buf.push(low);
    }

    fn step_fractal(&mut self, close: f64) {
        self.fractal_buf.push(close);
    }

    fn step_divergence(&mut self, close: f64) {
        self.price_peak_buf.push(close);
        if self.rsi.ready() {
            self.rsi_peak_buf.push(self.rsi.value());
        }
    }

    fn step_price_action(&mut self, close: f64, high: f64, low: f64) {
        let current_range = high - low;
        if close > self.prev_close {
            self.consecutive_up_count += 1;
            self.consecutive_down_count = 0;
        } else if close < self.prev_close {
            self.consecutive_down_count += 1;
            self.consecutive_up_count = 0;
        }
        self.prev_range = current_range;
    }

    // ════════════════════════════════════════════════════════════════
    // TICK — the main entry point
    // ════════════════════════════════════════════════════════════════

    /// One raw candle in, one enriched Candle out.
    pub fn tick(&mut self, raw: &Ohlcv) -> Candle {
        let o = raw.open;
        let h = raw.high;
        let l = raw.low;
        let c = raw.close;
        let v = raw.volume;
        let ts = &raw.ts;

        // ── 1. Advance all streaming primitives ──────────────────
        self.step_sma(c);
        self.step_bollinger(c);
        self.step_rsi(c);
        self.step_macd(c);
        self.step_dmi(h, l, c);
        self.step_atr(h, l, c);
        self.step_stoch(h, l, c);
        self.step_cci(h, l, c);
        self.step_mfi(h, l, c, v);
        self.step_obv(c, v);
        self.step_volume_sma(v);
        self.step_roc(c);
        self.step_range_pos(h, l);
        self.step_trend_consistency(c);
        self.step_timeframe(c, h, l);
        self.step_ichimoku(h, l);
        self.step_persistence(c);
        self.step_vwap(c, v);
        self.step_kama_er(c);
        self.step_choppiness();
        self.step_dfa(c);
        self.step_var_ratio(c);
        self.step_entropy(c);
        self.step_aroon(h, l);
        self.step_fractal(c);
        self.step_divergence(c);
        self.step_price_action(c, h, l);

        // ── 2. Compute derived values ────────────────────────────

        // Moving averages
        let sma20_val = self.sma20.value();
        let sma50_val = self.sma50.value();
        let sma200_val = self.sma200.value();

        // Bollinger
        let bb_std = self.bb_stddev.value();
        let bb_upper_val = sma20_val + 2.0 * bb_std;
        let bb_lower_val = sma20_val - 2.0 * bb_std;
        let bb_range = bb_upper_val - bb_lower_val;
        let bb_width_val = if c == 0.0 {
            0.0
        } else {
            bb_range / c
        };
        let bb_pos_val = if bb_range == 0.0 {
            0.5
        } else {
            (c - bb_lower_val) / bb_range
        };

        // RSI
        let rsi_val = self.rsi.value();

        // MACD
        let macd_hist_val = self.macd.hist_value();

        // DMI
        let plus_di_val = self.dmi.plus_di();
        let minus_di_val = self.dmi.minus_di();
        let adx_val = self.dmi.adx();

        // ATR
        let atr_val = self.atr.value();
        let atr_r_val = if c == 0.0 { 0.0 } else { atr_val / c };

        // Stochastic
        let stoch_k_val = self.stoch.k();
        let stoch_d_val = self.stoch.d();

        // Williams %R
        let williams_val = compute_williams_r(&self.stoch, c);

        // CCI, MFI
        let cci_val = self.cci.value();
        let mfi_val = self.mfi.value();

        // OBV slope
        // Take scratch buffer out to avoid split-borrow issues.
        // Capacity persists across the lifetime of IndicatorBank.
        let mut scratch = std::mem::take(&mut self.scratch);

        self.obv.history.fill_vec(&mut scratch);
        let obv_slope_val = obv_slope_12(&scratch);

        // Volume accel
        let vol_sma_val = self.volume_sma20.value();
        let vol_accel = if vol_sma_val == 0.0 {
            1.0
        } else {
            v / vol_sma_val
        };

        // Keltner (EMA(20) +/- 2 * ATR per wat spec)
        let ema20_val = self.ema20.value;
        let kelt_upper_val = ema20_val + 2.0 * atr_val;
        let kelt_lower_val = ema20_val - 2.0 * atr_val;
        let kelt_range = kelt_upper_val - kelt_lower_val;
        let kelt_pos_val = if kelt_range == 0.0 {
            0.5
        } else {
            (c - kelt_lower_val) / kelt_range
        };

        // Squeeze: bb_width / kelt_width (continuous)
        let kelt_width_ratio = if c == 0.0 {
            0.0
        } else {
            kelt_range / c
        };
        let squeeze_val = if kelt_width_ratio == 0.0 {
            1.0
        } else {
            bb_width_val / kelt_width_ratio
        };

        // ROC
        let roc_1_val = compute_roc(&self.roc_buf, 1);
        let roc_3_val = compute_roc(&self.roc_buf, 3);
        let roc_6_val = compute_roc(&self.roc_buf, 6);
        let roc_12_val = compute_roc(&self.roc_buf, 12);

        // Range position
        let rp_12 = compute_range_pos(&self.range_high_12, &self.range_low_12, c);
        let rp_24 = compute_range_pos(&self.range_high_24, &self.range_low_24, c);
        let rp_48 = compute_range_pos(&self.range_high_48, &self.range_low_48, c);

        // Multi-timeframe
        let tf_1h_ret_val = compute_tf_ret(&self.tf_1h_buf);
        let tf_1h_body_val = compute_tf_body(&self.tf_1h_buf);
        let tf_4h_ret_val = compute_tf_ret(&self.tf_4h_buf);
        let tf_4h_body_val = compute_tf_body(&self.tf_4h_buf);

        // Ichimoku
        let tenkan = self.ichimoku.tenkan();
        let kijun = self.ichimoku.kijun();
        let span_a = self.ichimoku.senkou_a();
        let span_b = self.ichimoku.senkou_b();
        let cloud_top_val = span_a.max(span_b);
        let cloud_bottom_val = span_a.min(span_b);

        // TK cross delta
        let tk_spread = tenkan - kijun;
        let tk_delta = tk_spread - self.prev_tk_spread;

        // Stochastic cross delta
        let stoch_kd = stoch_k_val - stoch_d_val;
        let stoch_delta = stoch_kd - self.prev_stoch_kd;

        // Persistence — reuse scratch buffer for all ring buffer extractions
        self.close_buf_48.fill_vec(&mut scratch);
        let hurst_val = hurst_exponent(&scratch);
        let autocorr_val = autocorrelation_lag1(&scratch);
        let vwap_val = compute_vwap_distance(self.vwap_cum_vol, self.vwap_cum_pv, c);

        // Regime
        self.kama_er_buf.fill_vec(&mut scratch);
        let kama_er_val = if self.kama_er_buf.is_full() {
            kama_efficiency_ratio(&scratch)
        } else {
            0.5
        };
        let chop_val = if self.chop_buf.is_full() {
            choppiness_index(self.chop_atr_sum, &self.range_high_12, &self.range_low_12)
        } else {
            50.0
        };
        self.dfa_buf.fill_vec(&mut scratch);
        let dfa_val = dfa_alpha(&scratch);
        self.var_ratio_buf.fill_vec(&mut scratch);
        let var_ratio_val = variance_ratio(&scratch);
        self.entropy_buf.fill_vec(&mut scratch);
        let entropy_val = entropy_rate(&scratch);
        self.aroon_high_buf.fill_vec(&mut scratch);
        let aroon_up_val = if self.aroon_high_buf.is_full() { aroon_up(&scratch) } else { 50.0 };
        self.aroon_low_buf.fill_vec(&mut scratch);
        let aroon_down_val = if self.aroon_low_buf.is_full() { aroon_down(&scratch) } else { 50.0 };
        self.fractal_buf.fill_vec(&mut scratch);
        let fractal_val = fractal_dimension(&scratch);

        // Divergence — needs two buffers simultaneously, use a second local vec
        let price_vals = self.price_peak_buf.to_vec();
        self.rsi_peak_buf.fill_vec(&mut scratch);
        let (div_bull, div_bear) = detect_divergence(&price_vals, &scratch);

        // Keltner, squeeze already computed above

        // Timeframe agreement
        let tf_agree = compute_tf_agreement(self.prev_close, c, &self.tf_1h_buf, &self.tf_4h_buf);

        // Price action
        let range_ratio_val = if self.prev_range == 0.0 {
            1.0
        } else {
            (h - l) / self.prev_range
        };
        let gap_val = if self.prev_close == 0.0 {
            0.0
        } else {
            (o - self.prev_close) / self.prev_close
        };
        let cons_up = self.consecutive_up_count as f64;
        let cons_down = self.consecutive_down_count as f64;

        // Time
        let minute_val = parse_minute(ts);
        let hour_val = parse_hour(ts);
        let dow_val = parse_day_of_week(ts);
        let dom_val = parse_day_of_month(ts);
        let moy_val = parse_month_of_year(ts);

        // Return scratch buffer to struct for reuse next candle.
        self.scratch = scratch;

        // ── 2b. Phase labeler (after ATR) ────────────────────────
        let smoothing = atr_val * 2.0; // 2.0 ATR — twice the noise floor (Proposal 052)
        self.phase_state.step(c, v, self.count + 1, smoothing);
        let phase_label = self.phase_state.current_label;
        let phase_direction = self.phase_state.current_direction;
        let phase_duration = self.phase_state.current_duration();
        // Only clone phase history when generation changes (every ~6 candles)
        if self.phase_state.generation != self.last_phase_generation {
            self.cached_phase_history = self.phase_state.history_snapshot();
            self.last_phase_generation = self.phase_state.generation;
        }
        let phase_history = self.cached_phase_history.clone();

        // ── 3. Update prev-state for next candle ─────────────────
        self.prev_tk_spread = tk_spread;
        self.prev_stoch_kd = stoch_kd;
        self.prev_close = c;
        self.count += 1;

        // ── 4. Assemble the enriched Candle ──────────────────────
        Candle {
            ts: ts.clone(),
            open: o,
            high: h,
            low: l,
            close: c,
            volume: v,
            sma20: sma20_val,
            sma50: sma50_val,
            sma200: sma200_val,
            bb_width: bb_width_val,
            bb_pos: bb_pos_val,
            rsi: rsi_val,
            macd_hist: macd_hist_val,
            plus_di: plus_di_val,
            minus_di: minus_di_val,
            adx: adx_val,
            atr_ratio: atr_r_val,
            stoch_k: stoch_k_val,
            stoch_d: stoch_d_val,
            williams_r: williams_val,
            cci: cci_val,
            mfi: mfi_val,
            obv_slope_12: obv_slope_val,
            volume_accel: vol_accel,
            kelt_upper: kelt_upper_val,
            kelt_lower: kelt_lower_val,
            kelt_pos: kelt_pos_val,
            squeeze: squeeze_val,
            roc_1: roc_1_val,
            roc_3: roc_3_val,
            roc_6: roc_6_val,
            roc_12: roc_12_val,
            range_pos_12: rp_12,
            range_pos_24: rp_24,
            range_pos_48: rp_48,
            tf_1h_ret: tf_1h_ret_val,
            tf_1h_body: tf_1h_body_val,
            tf_4h_ret: tf_4h_ret_val,
            tf_4h_body: tf_4h_body_val,
            tenkan_sen: tenkan,
            kijun_sen: kijun,
            cloud_top: cloud_top_val,
            cloud_bottom: cloud_bottom_val,
            hurst: hurst_val,
            autocorrelation: autocorr_val,
            vwap_distance: vwap_val,
            kama_er: kama_er_val,
            choppiness: chop_val,
            dfa_alpha: dfa_val,
            variance_ratio: var_ratio_val,
            entropy_rate: entropy_val,
            aroon_up: aroon_up_val,
            aroon_down: aroon_down_val,
            fractal_dim: fractal_val,
            rsi_divergence_bull: div_bull,
            rsi_divergence_bear: div_bear,
            tk_cross_delta: tk_delta,
            stoch_cross_delta: stoch_delta,
            range_ratio: range_ratio_val,
            gap: gap_val,
            consecutive_up: cons_up,
            consecutive_down: cons_down,
            tf_agreement: tf_agree,
            minute: minute_val,
            hour: hour_val,
            day_of_week: dow_val,
            day_of_month: dom_val,
            month_of_year: moy_val,
            phase_label,
            phase_direction,
            phase_duration,
            phase_history,
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// TESTS
// ════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ohlcv::Asset;

    fn make_raw_candle(
        ts: &str,
        open: f64,
        high: f64,
        low: f64,
        close: f64,
        volume: f64,
    ) -> Ohlcv {
        Ohlcv::new(Asset::new("BTC"), Asset::new("USD"), ts, open, high, low, close, volume)
    }

    // ── RingBuffer tests ──

    #[test]
    fn test_ring_buffer_new() {
        let rb = RingBuffer::new(5);
        assert_eq!(rb.capacity, 5);
        assert_eq!(rb.len, 0);
        assert_eq!(rb.head, 0);
    }

    #[test]
    fn test_ring_buffer_push_and_get() {
        let mut rb = RingBuffer::new(3);
        rb.push(1.0);
        rb.push(2.0);
        rb.push(3.0);
        assert_eq!(rb.get(0), 3.0); // most recent
        assert_eq!(rb.get(1), 2.0);
        assert_eq!(rb.get(2), 1.0); // oldest
        assert!(rb.is_full());
    }

    #[test]
    fn test_ring_buffer_wrap() {
        let mut rb = RingBuffer::new(3);
        rb.push(1.0);
        rb.push(2.0);
        rb.push(3.0);
        rb.push(4.0); // wraps, evicts 1.0
        assert_eq!(rb.get(0), 4.0);
        assert_eq!(rb.get(1), 3.0);
        assert_eq!(rb.get(2), 2.0);
        assert_eq!(rb.len, 3);
    }

    #[test]
    fn test_ring_buffer_max_min_sum() {
        let mut rb = RingBuffer::new(5);
        rb.push(3.0);
        rb.push(1.0);
        rb.push(4.0);
        rb.push(1.5);
        rb.push(9.0);
        assert_eq!(rb.max(), 9.0);
        assert_eq!(rb.min(), 1.0);
        assert!((rb.sum() - 18.5).abs() < 1e-10);
    }

    #[test]
    fn test_ring_buffer_to_vec() {
        let mut rb = RingBuffer::new(3);
        rb.push(10.0);
        rb.push(20.0);
        rb.push(30.0);
        let v = rb.to_vec();
        assert_eq!(v, vec![10.0, 20.0, 30.0]); // oldest to newest
    }

    #[test]
    fn test_ring_buffer_newest_oldest() {
        let mut rb = RingBuffer::new(4);
        rb.push(1.0);
        rb.push(2.0);
        rb.push(3.0);
        assert_eq!(rb.newest(), 3.0);
        assert_eq!(rb.oldest(), 1.0);
        rb.push(4.0);
        rb.push(5.0); // wraps
        assert_eq!(rb.newest(), 5.0);
        assert_eq!(rb.oldest(), 2.0);
    }

    // ── EMA tests ──

    #[test]
    fn test_ema_state() {
        let mut ema = EmaState::new(3);
        ema.update(10.0);
        ema.update(20.0);
        ema.update(30.0);
        // First valid: SMA = (10+20+30)/3 = 20
        assert!((ema.value - 20.0).abs() < 1e-10);
        ema.update(40.0);
        // EMA with smoothing = 0.5: 0.5*40 + 0.5*20 = 30
        assert!((ema.value - 30.0).abs() < 1e-10);
    }

    // ── Wilder tests ──

    #[test]
    fn test_wilder_state() {
        let mut ws = WilderState::new(3);
        ws.update(10.0);
        ws.update(20.0);
        ws.update(30.0);
        // First valid: average = (10+20+30)/3 = 20
        assert!((ws.value - 20.0).abs() < 1e-10);
        ws.update(40.0);
        // Wilder: 40/3 + 20*2/3 = 13.333 + 13.333 = 26.666...
        assert!((ws.value - 80.0 / 3.0).abs() < 1e-10);
    }

    // ── SMA tests ──

    #[test]
    fn test_sma_state() {
        let mut sma = SmaState::new(3);
        sma.update(10.0);
        sma.update(20.0);
        sma.update(30.0);
        assert!((sma.value() - 20.0).abs() < 1e-10);
        sma.update(40.0); // evicts 10.0
        assert!((sma.value() - 30.0).abs() < 1e-10);
    }

    // ── RollingStddev tests ──

    #[test]
    fn test_rolling_stddev() {
        let mut sd = RollingStddev::new(3);
        sd.update(10.0);
        sd.update(10.0);
        sd.update(10.0);
        assert!((sd.value() - 0.0).abs() < 1e-10, "Stddev of constants should be 0");
    }

    // ── RSI tests ──

    #[test]
    fn test_rsi_boundaries() {
        let mut rsi = RsiState::new(14);
        // Feed purely ascending prices
        for i in 0..30 {
            rsi.update(100.0 + i as f64);
        }
        let val = rsi.value();
        assert!(
            val > 50.0 && val <= 100.0,
            "RSI for ascending should be >50, got {}",
            val
        );

        // Feed purely descending prices
        let mut rsi2 = RsiState::new(14);
        for i in 0..30 {
            rsi2.update(200.0 - i as f64);
        }
        let val2 = rsi2.value();
        assert!(
            val2 < 50.0 && val2 >= 0.0,
            "RSI for descending should be <50, got {}",
            val2
        );
    }

    // ── Linreg slope ──

    #[test]
    fn test_linreg_slope_ascending() {
        let vals = vec![0.0, 10.0, 20.0, 30.0, 40.0];
        let slope = linreg_slope(&vals);
        assert!(
            (slope - 10.0).abs() < 1e-6,
            "Slope of 0,10,20,30,40 should be 10, got {}",
            slope
        );
    }

    #[test]
    fn test_linreg_slope_flat() {
        let vals = vec![5.0, 5.0, 5.0, 5.0];
        let slope = linreg_slope(&vals);
        assert!((slope - 0.0).abs() < 1e-10, "Slope of constants should be 0");
    }

    // ── Time parsing ──

    #[test]
    fn test_parse_minute() {
        assert_eq!(parse_minute("2024-01-15T14:30:00"), 30.0);
    }

    #[test]
    fn test_parse_hour() {
        assert_eq!(parse_hour("2024-01-15T14:30:00"), 14.0);
    }

    #[test]
    fn test_parse_day_of_month() {
        assert_eq!(parse_day_of_month("2024-01-15T14:30:00"), 15.0);
    }

    #[test]
    fn test_parse_month() {
        assert_eq!(parse_month_of_year("2024-06-15T14:30:00"), 6.0);
    }

    #[test]
    fn test_parse_day_of_week() {
        // 2024-01-15 is a Monday = 0
        let dow = parse_day_of_week("2024-01-15T14:30:00");
        assert_eq!(dow, 0.0, "2024-01-15 should be Monday (0), got {}", dow);
    }

    // ── IndicatorBank tests ──

    #[test]
    fn test_indicator_bank_new() {
        let bank = IndicatorBank::new();
        assert_eq!(bank.count, 0);
        assert_eq!(bank.prev_close, 0.0);
        assert_eq!(bank.sma20.buffer.capacity, 20);
        assert_eq!(bank.sma50.buffer.capacity, 50);
        assert_eq!(bank.sma200.buffer.capacity, 200);
        assert_eq!(bank.atr_history.capacity, 12);
        assert_eq!(bank.chop_buf.capacity, 14);
        assert_eq!(bank.kama_er_buf.capacity, 10);
    }

    #[test]
    fn test_tick_count() {
        let mut bank = IndicatorBank::new();
        let rc = make_raw_candle("2024-01-01T14:30:00", 100.0, 105.0, 95.0, 102.0, 50.0);
        bank.tick(&rc);
        assert_eq!(bank.count, 1);
        bank.tick(&rc);
        assert_eq!(bank.count, 2);
    }

    #[test]
    fn test_tick_preserves_raw_fields() {
        let mut bank = IndicatorBank::new();
        let rc = make_raw_candle("2024-03-15T09:45:00", 42000.0, 42500.0, 41800.0, 42200.0, 1500.0);
        let candle = bank.tick(&rc);
        assert_eq!(candle.ts, "2024-03-15T09:45:00");
        assert_eq!(candle.open, 42000.0);
        assert_eq!(candle.high, 42500.0);
        assert_eq!(candle.low, 41800.0);
        assert_eq!(candle.close, 42200.0);
        assert_eq!(candle.volume, 1500.0);
    }

    #[test]
    fn test_tick_produces_finite_after_warmup() {
        let mut bank = IndicatorBank::new();
        // Feed 300 candles to warm up all indicators
        for i in 0..300 {
            let price = 42000.0 + (i as f64).sin() * 500.0;
            let rc = make_raw_candle(
                "2024-01-01T14:30:00",
                price - 50.0,
                price + 100.0,
                price - 100.0,
                price,
                1000.0 + i as f64,
            );
            bank.tick(&rc);
        }
        // After warmup, all fields should be finite
        let rc = make_raw_candle(
            "2024-01-01T14:30:00",
            42000.0, 42100.0, 41900.0, 42050.0, 1500.0,
        );
        let candle = bank.tick(&rc);
        assert!(candle.sma20.is_finite());
        assert!(candle.sma50.is_finite());
        assert!(candle.sma200.is_finite());
        assert!(candle.rsi.is_finite());
        assert!(candle.macd_hist.is_finite());
        assert!(candle.atr_ratio.is_finite());
        assert!(candle.adx.is_finite());
        assert!(candle.plus_di.is_finite());
        assert!(candle.minus_di.is_finite());
        assert!(candle.bb_width.is_finite());
        assert!(candle.bb_pos.is_finite());
        assert!(candle.stoch_k.is_finite());
        assert!(candle.stoch_d.is_finite());
        assert!(candle.williams_r.is_finite());
        assert!(candle.cci.is_finite());
        assert!(candle.mfi.is_finite());
        assert!(candle.obv_slope_12.is_finite());
        assert!(candle.volume_accel.is_finite());
        assert!(candle.kelt_upper.is_finite());
        assert!(candle.kelt_lower.is_finite());
        assert!(candle.kelt_pos.is_finite());
        assert!(candle.squeeze.is_finite());
        assert!(candle.roc_1.is_finite());
        assert!(candle.roc_3.is_finite());
        assert!(candle.roc_6.is_finite());
        assert!(candle.roc_12.is_finite());
        assert!(candle.range_pos_12.is_finite());
        assert!(candle.range_pos_24.is_finite());
        assert!(candle.range_pos_48.is_finite());
        assert!(candle.tf_1h_ret.is_finite());
        assert!(candle.tf_1h_body.is_finite());
        assert!(candle.tf_4h_ret.is_finite());
        assert!(candle.tf_4h_body.is_finite());
        assert!(candle.tenkan_sen.is_finite());
        assert!(candle.kijun_sen.is_finite());
        assert!(candle.cloud_top.is_finite());
        assert!(candle.cloud_bottom.is_finite());
        assert!(candle.hurst.is_finite());
        assert!(candle.autocorrelation.is_finite());
        assert!(candle.vwap_distance.is_finite());
        assert!(candle.kama_er.is_finite());
        assert!(candle.choppiness.is_finite());
        assert!(candle.dfa_alpha.is_finite());
        assert!(candle.variance_ratio.is_finite());
        assert!(candle.entropy_rate.is_finite());
        assert!(candle.aroon_up.is_finite());
        assert!(candle.aroon_down.is_finite());
        assert!(candle.fractal_dim.is_finite());
        assert!(candle.rsi_divergence_bull.is_finite());
        assert!(candle.rsi_divergence_bear.is_finite());
        assert!(candle.tk_cross_delta.is_finite());
        assert!(candle.stoch_cross_delta.is_finite());
        assert!(candle.range_ratio.is_finite());
        assert!(candle.gap.is_finite());
        assert!(candle.consecutive_up.is_finite());
        assert!(candle.consecutive_down.is_finite());
        assert!(candle.tf_agreement.is_finite());
        assert!(candle.minute.is_finite());
        assert!(candle.hour.is_finite());
        assert!(candle.day_of_week.is_finite());
        assert!(candle.day_of_month.is_finite());
        assert!(candle.month_of_year.is_finite());
    }

    #[test]
    fn test_consecutive_counts() {
        let mut bank = IndicatorBank::new();
        // First candle — prev_close=0, close=100 > 0, so counts as up
        let c1 = bank.tick(&make_raw_candle("2024-01-01T00:00:00", 100.0, 105.0, 95.0, 100.0, 50.0));
        assert_eq!(c1.consecutive_up, 1.0);
        // Second ascending candle
        let c2 = bank.tick(&make_raw_candle("2024-01-01T00:05:00", 100.0, 106.0, 99.0, 105.0, 50.0));
        assert_eq!(c2.consecutive_up, 2.0);
        assert_eq!(c2.consecutive_down, 0.0);
        let c3 = bank.tick(&make_raw_candle("2024-01-01T00:10:00", 105.0, 112.0, 104.0, 110.0, 50.0));
        assert_eq!(c3.consecutive_up, 3.0);
        // One descending candle resets
        let c4 = bank.tick(&make_raw_candle("2024-01-01T00:15:00", 110.0, 111.0, 104.0, 108.0, 50.0));
        assert_eq!(c4.consecutive_up, 0.0);
        assert_eq!(c4.consecutive_down, 1.0);
    }

    #[test]
    fn test_sma_convergence() {
        let mut bank = IndicatorBank::new();
        // Feed 25 candles at constant price
        for _ in 0..25 {
            bank.tick(&make_raw_candle("2024-01-01T14:30:00", 100.0, 100.0, 100.0, 100.0, 50.0));
        }
        let c = bank.tick(&make_raw_candle("2024-01-01T14:30:00", 100.0, 100.0, 100.0, 100.0, 50.0));
        assert!((c.sma20 - 100.0).abs() < 1e-10, "SMA20 should be 100 for constant price");
    }

    #[test]
    fn test_hurst_random_walk_region() {
        // Hurst of a constant series should be 0.5
        let vals = vec![100.0; 20];
        let h = hurst_exponent(&vals);
        assert!((h - 0.5).abs() < 0.01, "Hurst of constant should be ~0.5, got {}", h);
    }

    #[test]
    fn test_fractal_dimension_range() {
        let mut vals: Vec<f64> = (0..30).map(|i| 100.0 + (i as f64 * 0.1).sin() * 10.0).collect();
        let fd = fractal_dimension(&vals);
        assert!(fd >= 1.0 && fd <= 2.0, "Fractal dim should be [1,2], got {}", fd);

        // Pure trend should be closer to 1
        vals = (0..30).map(|i| 100.0 + i as f64).collect();
        let fd_trend = fractal_dimension(&vals);
        assert!(fd_trend >= 1.0, "Trending fractal dim should be >= 1, got {}", fd_trend);
    }

    #[test]
    fn test_kama_er_constant() {
        let vals = vec![100.0; 10];
        let er = kama_efficiency_ratio(&vals);
        // Constant price: direction = 0, volatility = 0 -> 1.0 (per spec)
        assert_eq!(er, 1.0);
    }

    #[test]
    fn test_kama_er_trending() {
        let vals: Vec<f64> = (0..10).map(|i| 100.0 + i as f64).collect();
        let er = kama_efficiency_ratio(&vals);
        assert!((er - 1.0).abs() < 1e-10, "Pure trend ER should be 1.0, got {}", er);
    }
}
