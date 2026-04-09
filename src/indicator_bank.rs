//! indicator-bank.wat — streaming state machine for all technical indicators
//! Depends on: raw-candle.wat, candle.wat

use crate::candle::Candle;
use crate::raw_candle::RawCandle;

// ═══════════════════════════════════════════════════════════════════
// Streaming Primitives — the building blocks of indicator state
// ═══════════════════════════════════════════════════════════════════

// ── RingBuffer ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct RingBuffer {
    data: Vec<f64>,
    capacity: usize,
    head: usize,
    len: usize,
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

    /// i=0 is the oldest element
    pub fn get(&self, i: usize) -> f64 {
        let idx = (self.head + self.capacity - self.len + i) % self.capacity;
        self.data[idx]
    }

    /// Index from the end: 0 = newest, 1 = second newest, etc.
    pub fn get_from_end(&self, i: usize) -> f64 {
        self.get(self.len - 1 - i)
    }

    pub fn newest(&self) -> f64 {
        self.get(self.len - 1)
    }

    pub fn oldest(&self) -> f64 {
        self.get(0)
    }

    pub fn full(&self) -> bool {
        self.len == self.capacity
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn max(&self) -> f64 {
        let mut m = f64::NEG_INFINITY;
        for i in 0..self.len {
            let v = self.get(i);
            if v > m {
                m = v;
            }
        }
        m
    }

    pub fn min(&self) -> f64 {
        let mut m = f64::INFINITY;
        for i in 0..self.len {
            let v = self.get(i);
            if v < m {
                m = v;
            }
        }
        m
    }

    pub fn sum(&self) -> f64 {
        let mut s = 0.0;
        for i in 0..self.len {
            s += self.get(i);
        }
        s
    }

    pub fn to_vec(&self) -> Vec<f64> {
        (0..self.len).map(|i| self.get(i)).collect()
    }
}

// ── EmaState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct EmaState {
    value: f64,
    smoothing: f64,
    period: usize,
    count: usize,
    accum: f64,
}

impl EmaState {
    pub fn new(period: usize) -> Self {
        let smoothing = 2.0 / (period as f64 + 1.0);
        Self {
            value: 0.0,
            smoothing,
            period,
            count: 0,
            accum: 0.0,
        }
    }
}

// ── WilderState ────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct WilderState {
    value: f64,
    period: usize,
    count: usize,
    accum: f64,
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
}

// ── RsiState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct RsiState {
    gain_smoother: WilderState,
    loss_smoother: WilderState,
    prev_close: f64,
    started: bool,
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
}

// ── AtrState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct AtrState {
    wilder: WilderState,
    prev_close: f64,
    started: bool,
}

impl AtrState {
    pub fn new(period: usize) -> Self {
        Self {
            wilder: WilderState::new(period),
            prev_close: 0.0,
            started: false,
        }
    }
}

// ── ObvState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct ObvState {
    obv: f64,
    prev_close: f64,
    history: RingBuffer,
    started: bool,
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
}

// ── SmaState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct SmaState {
    buffer: RingBuffer,
    sum: f64,
    period: usize,
}

impl SmaState {
    pub fn new(period: usize) -> Self {
        Self {
            buffer: RingBuffer::new(period),
            sum: 0.0,
            period,
        }
    }
}

// ── RollingStddev ──────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct RollingStddev {
    buffer: RingBuffer,
    sum: f64,
    sum_sq: f64,
    period: usize,
}

impl RollingStddev {
    pub fn new(period: usize) -> Self {
        Self {
            buffer: RingBuffer::new(period),
            sum: 0.0,
            sum_sq: 0.0,
            period,
        }
    }
}

// ── StochState ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct StochState {
    high_buf: RingBuffer,
    low_buf: RingBuffer,
    k_buf: RingBuffer,
}

impl StochState {
    pub fn new(period: usize, k_smooth: usize) -> Self {
        Self {
            high_buf: RingBuffer::new(period),
            low_buf: RingBuffer::new(period),
            k_buf: RingBuffer::new(k_smooth),
        }
    }
}

// ── CciState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct CciState {
    tp_buf: RingBuffer,
    tp_sma: SmaState,
}

impl CciState {
    pub fn new(period: usize) -> Self {
        Self {
            tp_buf: RingBuffer::new(period),
            tp_sma: SmaState::new(period),
        }
    }
}

// ── MfiState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct MfiState {
    pos_flow_buf: RingBuffer,
    neg_flow_buf: RingBuffer,
    prev_tp: f64,
    started: bool,
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
}

// ── IchimokuState ──────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct IchimokuState {
    high_9: RingBuffer,
    low_9: RingBuffer,
    high_26: RingBuffer,
    low_26: RingBuffer,
    high_52: RingBuffer,
    low_52: RingBuffer,
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
}

// ── MacdState ──────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct MacdState {
    fast_ema: EmaState,
    slow_ema: EmaState,
    signal_ema: EmaState,
}

impl MacdState {
    pub fn new() -> Self {
        Self {
            fast_ema: EmaState::new(12),
            slow_ema: EmaState::new(26),
            signal_ema: EmaState::new(9),
        }
    }
}

// ── DmiState ───────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct DmiState {
    plus_smoother: WilderState,
    minus_smoother: WilderState,
    tr_smoother: WilderState,
    adx_smoother: WilderState,
    prev_high: f64,
    prev_low: f64,
    prev_close: f64,
    started: bool,
    count: usize,
    period: usize,
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
            period,
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Streaming step functions
// ═══════════════════════════════════════════════════════════════════

pub fn sma_step(sma: &mut SmaState, value: f64) -> f64 {
    if sma.buffer.full() {
        sma.sum -= sma.buffer.oldest();
    }
    sma.sum += value;
    sma.buffer.push(value);
    sma.sum / sma.buffer.len() as f64
}

pub fn ema_step(ema: &mut EmaState, value: f64) -> f64 {
    ema.count += 1;
    if ema.count <= ema.period {
        // Warmup: accumulate for SMA seed
        ema.accum += value;
        if ema.count == ema.period {
            let seed = ema.accum / ema.period as f64;
            ema.value = seed;
            seed
        } else {
            ema.value = value;
            value
        }
    } else {
        // Running: exponential smoothing
        let new_val = ema.smoothing * value + (1.0 - ema.smoothing) * ema.value;
        ema.value = new_val;
        new_val
    }
}

pub fn wilder_step(ws: &mut WilderState, value: f64) -> f64 {
    let period_float = ws.period as f64;
    ws.count += 1;
    if ws.count <= ws.period {
        // Warmup: accumulate for SMA seed
        ws.accum += value;
        if ws.count == ws.period {
            let seed = ws.accum / period_float;
            ws.value = seed;
            seed
        } else {
            ws.value = value;
            value
        }
    } else {
        // Running: Wilder smoothing
        let new_val = value / period_float + (period_float - 1.0) / period_float * ws.value;
        ws.value = new_val;
        new_val
    }
}

pub fn rolling_stddev_step(rs: &mut RollingStddev, value: f64) -> f64 {
    if rs.buffer.full() {
        let old = rs.buffer.oldest();
        rs.sum -= old;
        rs.sum_sq -= old * old;
    }
    rs.sum += value;
    rs.sum_sq += value * value;
    rs.buffer.push(value);
    let n = rs.buffer.len() as f64;
    let mean = rs.sum / n;
    let variance = rs.sum_sq / n - mean * mean;
    variance.max(0.0).sqrt()
}

pub fn rsi_step(rsi: &mut RsiState, close: f64) -> f64 {
    if !rsi.started {
        rsi.prev_close = close;
        rsi.started = true;
        return 50.0;
    }
    let change = close - rsi.prev_close;
    let gain = if change > 0.0 { change } else { 0.0 };
    let loss = if change < 0.0 { change.abs() } else { 0.0 };
    let avg_gain = wilder_step(&mut rsi.gain_smoother, gain);
    let avg_loss = wilder_step(&mut rsi.loss_smoother, loss);
    rsi.prev_close = close;
    if avg_loss == 0.0 {
        100.0
    } else {
        let rs = avg_gain / avg_loss;
        100.0 - 100.0 / (1.0 + rs)
    }
}

pub fn atr_step(atr_st: &mut AtrState, high: f64, low: f64, close: f64) -> f64 {
    if !atr_st.started {
        atr_st.prev_close = close;
        atr_st.started = true;
        let tr = high - low;
        return wilder_step(&mut atr_st.wilder, tr);
    }
    let tr = (high - low)
        .max((high - atr_st.prev_close).abs())
        .max((low - atr_st.prev_close).abs());
    atr_st.prev_close = close;
    wilder_step(&mut atr_st.wilder, tr)
}

pub fn macd_step(ms: &mut MacdState, close: f64) -> (f64, f64, f64) {
    let fast = ema_step(&mut ms.fast_ema, close);
    let slow = ema_step(&mut ms.slow_ema, close);
    let macd_val = fast - slow;
    let signal = ema_step(&mut ms.signal_ema, macd_val);
    let hist = macd_val - signal;
    (macd_val, signal, hist)
}

pub fn dmi_step(ds: &mut DmiState, high: f64, low: f64, close: f64) -> (f64, f64, f64) {
    if !ds.started {
        ds.prev_high = high;
        ds.prev_low = low;
        ds.prev_close = close;
        ds.started = true;
        return (0.0, 0.0, 0.0);
    }
    let up_move = high - ds.prev_high;
    let down_move = ds.prev_low - low;
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
        .max((high - ds.prev_close).abs())
        .max((low - ds.prev_close).abs());
    let smoothed_tr = wilder_step(&mut ds.tr_smoother, tr);
    let smoothed_plus = wilder_step(&mut ds.plus_smoother, plus_dm);
    let smoothed_minus = wilder_step(&mut ds.minus_smoother, minus_dm);
    let plus_di = if smoothed_tr == 0.0 {
        0.0
    } else {
        smoothed_plus / smoothed_tr * 100.0
    };
    let minus_di = if smoothed_tr == 0.0 {
        0.0
    } else {
        smoothed_minus / smoothed_tr * 100.0
    };
    let di_sum = plus_di + minus_di;
    let dx = if di_sum == 0.0 {
        0.0
    } else {
        (plus_di - minus_di).abs() / di_sum * 100.0
    };
    ds.count += 1;
    ds.prev_high = high;
    ds.prev_low = low;
    ds.prev_close = close;
    let adx = wilder_step(&mut ds.adx_smoother, dx);
    (plus_di, minus_di, adx)
}

pub fn stoch_step(ss: &mut StochState, high: f64, low: f64, close: f64) -> (f64, f64) {
    ss.high_buf.push(high);
    ss.low_buf.push(low);
    let highest = ss.high_buf.max();
    let lowest = ss.low_buf.min();
    let denom = highest - lowest;
    let raw_k = if denom == 0.0 {
        50.0
    } else {
        (close - lowest) / denom * 100.0
    };
    ss.k_buf.push(raw_k);
    // %D = SMA of %K
    let d = ss.k_buf.sum() / ss.k_buf.len() as f64;
    (raw_k, d)
}

pub fn cci_step(cs: &mut CciState, high: f64, low: f64, close: f64) -> f64 {
    let tp = (high + low + close) / 3.0;
    let tp_mean = sma_step(&mut cs.tp_sma, tp);
    cs.tp_buf.push(tp);
    // Mean deviation = mean of |tp_i - tp_mean|
    let mut mean_dev_sum = 0.0;
    for i in 0..cs.tp_buf.len() {
        mean_dev_sum += (cs.tp_buf.get(i) - tp_mean).abs();
    }
    let mean_dev = mean_dev_sum / cs.tp_buf.len() as f64;
    let cci_constant = 0.015;
    if mean_dev == 0.0 {
        0.0
    } else {
        (tp - tp_mean) / (cci_constant * mean_dev)
    }
}

pub fn mfi_step(ms: &mut MfiState, high: f64, low: f64, close: f64, volume: f64) -> f64 {
    let tp = (high + low + close) / 3.0;
    let raw_money_flow = tp * volume;
    if !ms.started {
        ms.prev_tp = tp;
        ms.started = true;
        ms.pos_flow_buf.push(0.0);
        ms.neg_flow_buf.push(0.0);
        return 50.0;
    }
    if tp > ms.prev_tp {
        ms.pos_flow_buf.push(raw_money_flow);
        ms.neg_flow_buf.push(0.0);
    } else {
        ms.pos_flow_buf.push(0.0);
        ms.neg_flow_buf.push(raw_money_flow);
    }
    ms.prev_tp = tp;
    let pos_sum = ms.pos_flow_buf.sum();
    let neg_sum = ms.neg_flow_buf.sum();
    if neg_sum == 0.0 {
        100.0
    } else {
        let mfr = pos_sum / neg_sum;
        100.0 - 100.0 / (1.0 + mfr)
    }
}

pub fn obv_step(os: &mut ObvState, close: f64, volume: f64) -> f64 {
    if !os.started {
        os.prev_close = close;
        os.started = true;
        os.history.push(os.obv);
        return os.obv;
    }
    if close > os.prev_close {
        os.obv += volume;
    } else if close < os.prev_close {
        os.obv -= volume;
    }
    os.prev_close = close;
    os.history.push(os.obv);
    os.obv
}

pub fn ichimoku_step(is: &mut IchimokuState, high: f64, low: f64) -> (f64, f64, f64, f64, f64, f64) {
    is.high_9.push(high);
    is.low_9.push(low);
    is.high_26.push(high);
    is.low_26.push(low);
    is.high_52.push(high);
    is.low_52.push(low);
    let tenkan = (is.high_9.max() + is.low_9.min()) / 2.0;
    let kijun = (is.high_26.max() + is.low_26.min()) / 2.0;
    let senkou_a = (tenkan + kijun) / 2.0;
    let senkou_b = (is.high_52.max() + is.low_52.min()) / 2.0;
    let c_top = senkou_a.max(senkou_b);
    let c_bottom = senkou_a.min(senkou_b);
    (tenkan, kijun, senkou_a, senkou_b, c_top, c_bottom)
}

// ═══════════════════════════════════════════════════════════════════
// Linear Regression Slope — co-located above OBV per wat spec
// (define before use: needed for obv_slope_12 in tick)
// ═══════════════════════════════════════════════════════════════════

pub fn linreg_slope(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 2 {
        return 0.0;
    }
    let mut sum_x = 0.0;
    let mut sum_y = 0.0;
    let mut sum_xy = 0.0;
    let mut sum_x2 = 0.0;
    let nf = n as f64;
    for i in 0..n {
        let x = i as f64;
        let y = rb.get(i);
        sum_x += x;
        sum_y += y;
        sum_xy += x * y;
        sum_x2 += x * x;
    }
    let denom = nf * sum_x2 - sum_x * sum_x;
    if denom == 0.0 {
        0.0
    } else {
        (nf * sum_xy - sum_x * sum_y) / denom
    }
}

// ═══════════════════════════════════════════════════════════════════
// Helper computations — used inside tick
// ═══════════════════════════════════════════════════════════════════

fn compute_roc(rb: &RingBuffer, n: usize, close: f64) -> f64 {
    let buf_len = rb.len();
    if buf_len < n + 1 {
        return 0.0;
    }
    let old_val = rb.get(buf_len - 1 - n);
    if old_val == 0.0 {
        0.0
    } else {
        (close - old_val) / old_val
    }
}

fn compute_range_pos(hi_buf: &RingBuffer, lo_buf: &RingBuffer, close: f64) -> f64 {
    let highest = hi_buf.max();
    let lowest = lo_buf.min();
    let r = highest - lowest;
    if r == 0.0 {
        0.5
    } else {
        (close - lowest) / r
    }
}

fn compute_trend_consistency(rb: &RingBuffer, window: usize) -> f64 {
    let n = rb.len().min(window);
    if n < 2 {
        return 0.5;
    }
    let start = rb.len() - n;
    let mut up_count = 0usize;
    for i in (start + 1)..rb.len() {
        if rb.get(i) > rb.get(i - 1) {
            up_count += 1;
        }
    }
    up_count as f64 / (n - 1) as f64
}

fn compute_vwap_distance(vwap_cum_vol: f64, vwap_cum_pv: f64, close: f64) -> f64 {
    let vwap = if vwap_cum_vol == 0.0 {
        close
    } else {
        vwap_cum_pv / vwap_cum_vol
    };
    (close - vwap) / close
}

/// Hurst exponent via R/S analysis
fn compute_hurst(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 8 {
        return 0.5;
    }
    let vals = rb.to_vec();
    let mean_val: f64 = vals.iter().sum::<f64>() / n as f64;
    let deviations: Vec<f64> = vals.iter().map(|v| v - mean_val).collect();
    // Cumulative sum of deviations
    let mut cumulative = Vec::with_capacity(n);
    let mut running = 0.0;
    for d in &deviations {
        running += d;
        cumulative.push(running);
    }
    let r = cumulative.iter().copied().fold(f64::NEG_INFINITY, f64::max)
        - cumulative.iter().copied().fold(f64::INFINITY, f64::min);
    let s = (deviations.iter().map(|d| d * d).sum::<f64>() / n as f64).sqrt();
    if s == 0.0 {
        return 0.5;
    }
    let rs = r / s;
    if rs <= 0.0 {
        0.5
    } else {
        rs.ln() / (n as f64).ln()
    }
}

/// Lag-1 autocorrelation
fn compute_autocorrelation(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 3 {
        return 0.0;
    }
    let vals = rb.to_vec();
    let mean_val: f64 = vals.iter().sum::<f64>() / n as f64;
    let var_sum: f64 = vals.iter().map(|v| (v - mean_val) * (v - mean_val)).sum();
    if var_sum == 0.0 {
        return 0.0;
    }
    let mut cov_sum = 0.0;
    for i in 1..n {
        cov_sum += (vals[i] - mean_val) * (vals[i - 1] - mean_val);
    }
    cov_sum / var_sum
}

/// KAMA Efficiency Ratio
fn compute_kama_er(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 2 {
        return 0.0;
    }
    let direction = (rb.newest() - rb.oldest()).abs();
    let mut volatility = 0.0;
    for i in 1..n {
        volatility += (rb.get(i) - rb.get(i - 1)).abs();
    }
    if volatility == 0.0 {
        0.0
    } else {
        direction / volatility
    }
}

/// Choppiness Index
fn compute_choppiness(atr_sum: f64, high_buf: &RingBuffer, low_buf: &RingBuffer, period: usize) -> f64 {
    let highest = high_buf.max();
    let lowest = low_buf.min();
    let price_range = highest - lowest;
    if price_range <= 0.0 {
        50.0
    } else {
        100.0 * (atr_sum / price_range).ln() / (period as f64).ln()
    }
}

/// DFA alpha
fn compute_dfa(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 8 {
        return 0.5;
    }
    let vals = rb.to_vec();
    let mean_val: f64 = vals.iter().sum::<f64>() / n as f64;
    // Cumulative sum of demeaned series
    let mut profile = Vec::with_capacity(n);
    let mut running = 0.0;
    for v in &vals {
        running += v - mean_val;
        profile.push(running);
    }
    // Fluctuation at one scale (n/4)
    let seg_len = (n / 4).max(2);
    let n_segs = n / seg_len;
    let mut fluct_sum = 0.0;
    for seg_i in 0..n_segs {
        let start = seg_i * seg_len;
        let end = ((seg_i + 1) * seg_len).min(n);
        let seg_n = end - start;
        let seg_vals: Vec<f64> = (start..end).map(|j| profile[j]).collect();
        let seg_mean: f64 = seg_vals.iter().sum::<f64>() / seg_n as f64;
        let var: f64 =
            seg_vals.iter().map(|v| (v - seg_mean) * (v - seg_mean)).sum::<f64>() / seg_n as f64;
        fluct_sum += var;
    }
    let f_val = (fluct_sum / n_segs.max(1) as f64).sqrt();
    if f_val <= 0.0 {
        0.5
    } else {
        f_val.ln() / (seg_len as f64).ln()
    }
}

/// Variance ratio
fn compute_variance_ratio(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 4 {
        return 1.0;
    }
    let vals = rb.to_vec();
    // Returns at scale 1
    let ret1: Vec<f64> = (1..n).map(|i| vals[i] - vals[i - 1]).collect();
    let var1 = variance(&ret1);
    // Returns at scale 2
    let ret2: Vec<f64> = (2..n).map(|i| vals[i] - vals[i - 2]).collect();
    let var2 = variance(&ret2);
    if var1 == 0.0 {
        1.0
    } else {
        var2 / (2.0 * var1)
    }
}

fn variance(vals: &[f64]) -> f64 {
    if vals.is_empty() {
        return 0.0;
    }
    let n = vals.len() as f64;
    let mean: f64 = vals.iter().sum::<f64>() / n;
    vals.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / n
}

/// Conditional entropy rate
fn compute_entropy_rate(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 4 {
        return 1.0;
    }
    let vals = rb.to_vec();
    // Discretize returns into bins: -1, 0, +1
    let bins: Vec<i32> = (1..n)
        .map(|i| {
            let ret = vals[i] - vals[i - 1];
            if ret > 0.001 {
                1
            } else if ret < -0.001 {
                -1
            } else {
                0
            }
        })
        .collect();
    let n_bins = bins.len() - 1;
    if n_bins == 0 {
        return 1.0;
    }
    // Count transitions for conditional entropy H(X_t | X_{t-1})
    // Use a flat array: index = (prev+1)*3 + (curr+1) for {-1,0,1} mapped to {0,1,2}
    let mut pair_counts = [0usize; 9];
    let mut single_counts = [0usize; 3];
    for i in 0..n_bins {
        let prev = (bins[i] + 1) as usize; // 0,1,2
        let curr = (bins[i + 1] + 1) as usize;
        pair_counts[prev * 3 + curr] += 1;
        single_counts[prev] += 1;
    }
    // H(X_t | X_{t-1}) = - sum P(x_t, x_{t-1}) * log(P(x_t | x_{t-1}))
    let mut entropy_sum = 0.0;
    for prev in 0..3 {
        for curr in 0..3 {
            let pc = pair_counts[prev * 3 + curr];
            if pc == 0 {
                continue;
            }
            let p_joint = pc as f64 / n_bins as f64;
            let p_prev = single_counts[prev] as f64 / n_bins as f64;
            if p_prev == 0.0 {
                continue;
            }
            let p_cond = p_joint / p_prev;
            if p_cond > 0.0 {
                entropy_sum -= p_joint * p_cond.ln();
            }
        }
    }
    entropy_sum
}

/// Aroon Up
fn compute_aroon_up(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    let aroon_period = 25;
    if n < 2 {
        return 50.0;
    }
    let mut max_idx = 0;
    for i in 1..n {
        if rb.get(i) >= rb.get(max_idx) {
            max_idx = i;
        }
    }
    let periods_since = n - 1 - max_idx;
    (aroon_period as f64 - periods_since as f64) / aroon_period as f64 * 100.0
}

/// Aroon Down
fn compute_aroon_down(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    let aroon_period = 25;
    if n < 2 {
        return 50.0;
    }
    let mut min_idx = 0;
    for i in 1..n {
        if rb.get(i) <= rb.get(min_idx) {
            min_idx = i;
        }
    }
    let periods_since = n - 1 - min_idx;
    (aroon_period as f64 - periods_since as f64) / aroon_period as f64 * 100.0
}

/// Fractal dimension (simplified box-counting)
fn compute_fractal_dim(rb: &RingBuffer) -> f64 {
    let n = rb.len();
    if n < 8 {
        return 1.5;
    }
    let vals = rb.to_vec();
    let mut changes = 0usize;
    for i in 1..n {
        let d1 = vals[i] - vals[i - 1];
        let d2 = if i < 2 {
            0.0
        } else {
            vals[i - 1] - vals[i - 2]
        };
        if d1 != 0.0 && d2 != 0.0 && d1 * d2 < 0.0 {
            changes += 1;
        }
    }
    let roughness = changes as f64 / (n - 1).max(1) as f64;
    1.0 + roughness
}

/// RSI divergence detection (simplified)
fn compute_rsi_divergence(price_buf: &RingBuffer, rsi_buf: &RingBuffer) -> (f64, f64) {
    let n = price_buf.len().min(rsi_buf.len());
    if n < 6 {
        return (0.0, 0.0);
    }
    let mid = n / 2;
    // First half extremes
    let mut fh_price_low = f64::INFINITY;
    let mut fh_price_high = f64::NEG_INFINITY;
    let mut fh_rsi_low = f64::INFINITY;
    let mut fh_rsi_high = f64::NEG_INFINITY;
    for i in 0..mid {
        let p = price_buf.get(i);
        let r = rsi_buf.get(i);
        if p < fh_price_low { fh_price_low = p; }
        if p > fh_price_high { fh_price_high = p; }
        if r < fh_rsi_low { fh_rsi_low = r; }
        if r > fh_rsi_high { fh_rsi_high = r; }
    }
    // Second half extremes
    let mut sh_price_low = f64::INFINITY;
    let mut sh_price_high = f64::NEG_INFINITY;
    let mut sh_rsi_low = f64::INFINITY;
    let mut sh_rsi_high = f64::NEG_INFINITY;
    for i in mid..n {
        let p = price_buf.get(i);
        let r = rsi_buf.get(i);
        if p < sh_price_low { sh_price_low = p; }
        if p > sh_price_high { sh_price_high = p; }
        if r < sh_rsi_low { sh_rsi_low = r; }
        if r > sh_rsi_high { sh_rsi_high = r; }
    }
    // Bullish: price makes lower low, RSI makes higher low
    let bull_mag = if sh_price_low < fh_price_low && sh_rsi_low > fh_rsi_low {
        (sh_rsi_low - fh_rsi_low).abs()
    } else {
        0.0
    };
    // Bearish: price makes higher high, RSI makes lower high
    let bear_mag = if sh_price_high > fh_price_high && sh_rsi_high < fh_rsi_high {
        (fh_rsi_high - sh_rsi_high).abs()
    } else {
        0.0
    };
    (bull_mag, bear_mag)
}

/// Timeframe agreement: compare 5m, 1h, 4h direction
fn compute_tf_agreement(five_min_ret: f64, one_h_ret: f64, four_h_ret: f64) -> f64 {
    let five_dir = five_min_ret.signum();
    let one_dir = one_h_ret.signum();
    let four_dir = four_h_ret.signum();
    let mut score = 0.0;
    if five_dir == one_dir {
        score += 1.0;
    }
    if five_dir == four_dir {
        score += 1.0;
    }
    if one_dir == four_dir {
        score += 1.0;
    }
    score / 3.0
}

// ═══════════════════════════════════════════════════════════════════
// Time parsing
// ═══════════════════════════════════════════════════════════════════

/// Parse minute from timestamp "YYYY-MM-DDTHH:MM:SS..."
pub fn parse_minute(ts: &str) -> f64 {
    if ts.len() >= 16 {
        ts[14..16].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

/// Parse hour from timestamp
pub fn parse_hour(ts: &str) -> f64 {
    if ts.len() >= 13 {
        ts[11..13].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

/// Parse day of week from timestamp (uses chrono)
pub fn parse_day_of_week(ts: &str) -> f64 {
    use chrono::NaiveDateTime;
    // Try common formats
    if let Ok(dt) = NaiveDateTime::parse_from_str(ts, "%Y-%m-%dT%H:%M:%S%.fZ") {
        return dt.format("%u").to_string().parse::<f64>().unwrap_or(0.0);
    }
    if let Ok(dt) = NaiveDateTime::parse_from_str(ts, "%Y-%m-%dT%H:%M:%SZ") {
        return dt.format("%u").to_string().parse::<f64>().unwrap_or(0.0);
    }
    if let Ok(dt) = NaiveDateTime::parse_from_str(ts, "%Y-%m-%dT%H:%M:%S") {
        return dt.format("%u").to_string().parse::<f64>().unwrap_or(0.0);
    }
    if let Ok(dt) = NaiveDateTime::parse_from_str(ts, "%Y-%m-%d %H:%M:%S") {
        return dt.format("%u").to_string().parse::<f64>().unwrap_or(0.0);
    }
    0.0
}

/// Parse day of month from timestamp
pub fn parse_day_of_month(ts: &str) -> f64 {
    if ts.len() >= 10 {
        ts[8..10].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

/// Parse month from timestamp
pub fn parse_month(ts: &str) -> f64 {
    if ts.len() >= 7 {
        ts[5..7].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

// ═══════════════════════════════════════════════════════════════════
// IndicatorBank — composed from the streaming primitives
// ═══════════════════════════════════════════════════════════════════

pub struct IndicatorBank {
    // Moving averages
    sma20: SmaState,
    sma50: SmaState,
    sma200: SmaState,
    ema20: EmaState,
    // Bollinger
    bb_stddev: RollingStddev,
    // Oscillators
    rsi: RsiState,
    macd: MacdState,
    dmi: DmiState,
    atr: AtrState,
    stoch: StochState,
    cci: CciState,
    mfi: MfiState,
    obv: ObvState,
    volume_sma20: SmaState,
    // ROC
    roc_buf: RingBuffer,
    // Range position
    range_high_12: RingBuffer,
    range_low_12: RingBuffer,
    range_high_24: RingBuffer,
    range_low_24: RingBuffer,
    range_high_48: RingBuffer,
    range_low_48: RingBuffer,
    // Trend consistency
    trend_buf_24: RingBuffer,
    // ATR history
    atr_history: RingBuffer,
    // Multi-timeframe
    tf_1h_buf: RingBuffer,
    tf_1h_high: RingBuffer,
    tf_1h_low: RingBuffer,
    tf_4h_buf: RingBuffer,
    tf_4h_high: RingBuffer,
    tf_4h_low: RingBuffer,
    // Ichimoku
    ichimoku: IchimokuState,
    // Persistence
    close_buf_48: RingBuffer,
    // VWAP
    vwap_cum_vol: f64,
    vwap_cum_pv: f64,
    // Regime
    kama_er_buf: RingBuffer,
    chop_atr_sum: f64,
    chop_buf: RingBuffer,
    dfa_buf: RingBuffer,
    var_ratio_buf: RingBuffer,
    entropy_buf: RingBuffer,
    aroon_high_buf: RingBuffer,
    aroon_low_buf: RingBuffer,
    fractal_buf: RingBuffer,
    // Divergence
    rsi_peak_buf: RingBuffer,
    price_peak_buf: RingBuffer,
    // Cross deltas
    prev_tk_spread: f64,
    prev_stoch_kd: f64,
    // Price action
    prev_range: f64,
    consecutive_up_count: usize,
    consecutive_down_count: usize,
    // Timeframe agreement
    prev_tf_1h_ret: f64,
    prev_tf_4h_ret: f64,
    // Previous values
    prev_close: f64,
    // Counter
    count: usize,
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
            // Multi-timeframe — aggregate 12 for 1h, 48 for 4h
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
            rsi_peak_buf: RingBuffer::new(30),
            price_peak_buf: RingBuffer::new(30),
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
            // Counter
            count: 0,
        }
    }

    /// The full waterfall. Advances all indicators by one candle.
    pub fn tick(&mut self, rc: &RawCandle) -> Candle {
        let open = rc.open;
        let high = rc.high;
        let low = rc.low;
        let close = rc.close;
        let volume = rc.volume;
        let ts = &rc.ts;

        // ── Moving averages ──────────────────────────────────────────
        let sma20_val = sma_step(&mut self.sma20, close);
        let sma50_val = sma_step(&mut self.sma50, close);
        let sma200_val = sma_step(&mut self.sma200, close);
        let ema20_val = ema_step(&mut self.ema20, close);

        // ── Bollinger ────────────────────────────────────────────────
        let bb_std = rolling_stddev_step(&mut self.bb_stddev, close);
        let bb_upper_val = sma20_val + 2.0 * bb_std;
        let bb_lower_val = sma20_val - 2.0 * bb_std;
        let bb_width_val = if close == 0.0 {
            0.0
        } else {
            (bb_upper_val - bb_lower_val) / close
        };
        let bb_range = bb_upper_val - bb_lower_val;
        let bb_pos_val = if bb_range == 0.0 {
            0.5
        } else {
            (close - bb_lower_val) / bb_range
        };

        // ── Oscillators ──────────────────────────────────────────────
        let rsi_val = rsi_step(&mut self.rsi, close);
        let (macd_val, macd_signal_val, macd_hist_val) = macd_step(&mut self.macd, close);
        let (plus_di_val, minus_di_val, adx_val) = dmi_step(&mut self.dmi, high, low, close);
        let atr_val = atr_step(&mut self.atr, high, low, close);
        let atr_r_val = if close == 0.0 { 0.0 } else { atr_val / close };
        let (stoch_k_val, stoch_d_val) = stoch_step(&mut self.stoch, high, low, close);
        let cci_val = cci_step(&mut self.cci, high, low, close);
        let mfi_val = mfi_step(&mut self.mfi, high, low, close, volume);
        let _obv_val = obv_step(&mut self.obv, close, volume);
        let vol_sma20 = sma_step(&mut self.volume_sma20, volume);
        let volume_accel_val = if vol_sma20 == 0.0 { 1.0 } else { volume / vol_sma20 };

        // Williams %R — reuse stoch high/low buffers (same period=14)
        let highest14 = self.stoch.high_buf.max();
        let lowest14 = self.stoch.low_buf.min();
        let stoch_range = highest14 - lowest14;
        let williams_r_val = if stoch_range == 0.0 {
            -50.0
        } else {
            (highest14 - close) / stoch_range * -100.0
        };

        // ── OBV slope ────────────────────────────────────────────────
        let obv_slope_12_val = linreg_slope(&self.obv.history);

        // ── Keltner ──────────────────────────────────────────────────
        let kelt_width_mult = 1.5;
        let kelt_upper_val = ema20_val + kelt_width_mult * atr_val;
        let kelt_lower_val = ema20_val - kelt_width_mult * atr_val;
        let kelt_range = kelt_upper_val - kelt_lower_val;
        let kelt_pos_val = if kelt_range == 0.0 {
            0.5
        } else {
            (close - kelt_lower_val) / kelt_range
        };
        let kelt_width = kelt_upper_val - kelt_lower_val;
        let squeeze_val = if kelt_width == 0.0 {
            1.0
        } else {
            (bb_upper_val - bb_lower_val) / kelt_width
        };

        // ── Rate of Change ───────────────────────────────────────────
        self.roc_buf.push(close);
        let roc_1_val = compute_roc(&self.roc_buf, 1, close);
        let roc_3_val = compute_roc(&self.roc_buf, 3, close);
        let roc_6_val = compute_roc(&self.roc_buf, 6, close);
        let roc_12_val = compute_roc(&self.roc_buf, 12, close);

        // ── ATR Rate of Change ───────────────────────────────────────
        self.atr_history.push(atr_val);
        let atr_roc_6_val = compute_roc(&self.atr_history, 6, atr_val);
        let atr_roc_12_val = compute_roc(&self.atr_history, 12, atr_val);

        // ── Range position ───────────────────────────────────────────
        self.range_high_12.push(high);
        self.range_low_12.push(low);
        self.range_high_24.push(high);
        self.range_low_24.push(low);
        self.range_high_48.push(high);
        self.range_low_48.push(low);
        let range_pos_12_val = compute_range_pos(&self.range_high_12, &self.range_low_12, close);
        let range_pos_24_val = compute_range_pos(&self.range_high_24, &self.range_low_24, close);
        let range_pos_48_val = compute_range_pos(&self.range_high_48, &self.range_low_48, close);

        // ── Trend consistency ────────────────────────────────────────
        let up_candle = if close > self.prev_close { 1.0 } else { 0.0 };
        self.trend_buf_24.push(up_candle);
        let tc_6 = compute_trend_consistency(&self.trend_buf_24, 6);
        let tc_12 = compute_trend_consistency(&self.trend_buf_24, 12);
        let tc_24 = compute_trend_consistency(&self.trend_buf_24, 24);

        // ── Multi-timeframe ──────────────────────────────────────────
        self.tf_1h_buf.push(close);
        self.tf_1h_high.push(high);
        self.tf_1h_low.push(low);
        self.tf_4h_buf.push(close);
        self.tf_4h_high.push(high);
        self.tf_4h_low.push(low);

        let tf_1h_close_val = close;
        let tf_1h_high_val = self.tf_1h_high.max();
        let tf_1h_low_val = self.tf_1h_low.min();
        let tf_1h_first = self.tf_1h_buf.oldest();
        let tf_1h_ret_val = if tf_1h_first == 0.0 {
            0.0
        } else {
            (close - tf_1h_first) / tf_1h_first
        };
        let tf_1h_body_val = if tf_1h_first == 0.0 {
            0.0
        } else {
            (close - tf_1h_first).abs() / (tf_1h_high_val - tf_1h_low_val).max(0.0001)
        };

        let tf_4h_close_val = close;
        let tf_4h_high_val = self.tf_4h_high.max();
        let tf_4h_low_val = self.tf_4h_low.min();
        let tf_4h_first = self.tf_4h_buf.oldest();
        let tf_4h_ret_val = if tf_4h_first == 0.0 {
            0.0
        } else {
            (close - tf_4h_first) / tf_4h_first
        };
        let tf_4h_body_val = if tf_4h_first == 0.0 {
            0.0
        } else {
            (close - tf_4h_first).abs() / (tf_4h_high_val - tf_4h_low_val).max(0.0001)
        };

        // ── Ichimoku ─────────────────────────────────────────────────
        let (tenkan_val, kijun_val, senkou_a_val, senkou_b_val, cloud_top_val, cloud_bottom_val) =
            ichimoku_step(&mut self.ichimoku, high, low);
        let tk_spread = tenkan_val - kijun_val;
        let tk_cross_delta_val = tk_spread - self.prev_tk_spread;
        self.prev_tk_spread = tk_spread;

        // ── Stochastic cross delta ───────────────────────────────────
        let stoch_kd = stoch_k_val - stoch_d_val;
        let stoch_cross_delta_val = stoch_kd - self.prev_stoch_kd;
        self.prev_stoch_kd = stoch_kd;

        // ── Persistence ──────────────────────────────────────────────
        self.close_buf_48.push(close);
        let hurst_val = compute_hurst(&self.close_buf_48);
        let autocorrelation_val = compute_autocorrelation(&self.close_buf_48);

        // ── VWAP ─────────────────────────────────────────────────────
        let tp = (high + low + close) / 3.0;
        self.vwap_cum_vol += volume;
        self.vwap_cum_pv += tp * volume;
        let vwap_distance_val = compute_vwap_distance(self.vwap_cum_vol, self.vwap_cum_pv, close);

        // ── Regime ───────────────────────────────────────────────────
        self.kama_er_buf.push(close);
        let kama_er_val = compute_kama_er(&self.kama_er_buf);

        // Choppiness
        if self.chop_buf.full() {
            self.chop_atr_sum -= self.chop_buf.oldest();
        }
        self.chop_atr_sum += atr_val;
        self.chop_buf.push(atr_val);
        let choppiness_val =
            compute_choppiness(self.chop_atr_sum, &self.range_high_12, &self.range_low_12, 14);

        // DFA
        self.dfa_buf.push(close);
        let dfa_alpha_val = compute_dfa(&self.dfa_buf);

        // Variance ratio
        self.var_ratio_buf.push(close);
        let variance_ratio_val = compute_variance_ratio(&self.var_ratio_buf);

        // Entropy
        self.entropy_buf.push(close);
        let entropy_rate_val = compute_entropy_rate(&self.entropy_buf);

        // Aroon
        self.aroon_high_buf.push(high);
        self.aroon_low_buf.push(low);
        let aroon_up_val = compute_aroon_up(&self.aroon_high_buf);
        let aroon_down_val = compute_aroon_down(&self.aroon_low_buf);

        // Fractal dimension
        self.fractal_buf.push(close);
        let fractal_dim_val = compute_fractal_dim(&self.fractal_buf);

        // ── Divergence ───────────────────────────────────────────────
        self.rsi_peak_buf.push(rsi_val);
        self.price_peak_buf.push(close);
        let (rsi_div_bull, rsi_div_bear) =
            compute_rsi_divergence(&self.price_peak_buf, &self.rsi_peak_buf);

        // ── Price action ─────────────────────────────────────────────
        let current_range = high - low;
        let range_ratio_val = if self.prev_range == 0.0 {
            1.0
        } else {
            current_range / self.prev_range
        };
        let gap_val = if self.prev_close == 0.0 {
            0.0
        } else {
            (open - self.prev_close) / self.prev_close
        };
        self.prev_range = current_range;

        // Consecutive runs
        if close > self.prev_close {
            self.consecutive_up_count += 1;
            self.consecutive_down_count = 0;
        } else if close < self.prev_close {
            self.consecutive_down_count += 1;
            self.consecutive_up_count = 0;
        }
        let consecutive_up_val = self.consecutive_up_count as f64;
        let consecutive_down_val = self.consecutive_down_count as f64;

        // ── Timeframe agreement ──────────────────────────────────────
        let five_min_ret = if self.prev_close == 0.0 {
            0.0
        } else {
            (close - self.prev_close) / self.prev_close
        };
        let tf_agreement_val =
            compute_tf_agreement(five_min_ret, self.prev_tf_1h_ret, self.prev_tf_4h_ret);
        self.prev_tf_1h_ret = tf_1h_ret_val;
        self.prev_tf_4h_ret = tf_4h_ret_val;

        // ── Time ─────────────────────────────────────────────────────
        let minute_val = parse_minute(ts);
        let hour_val = parse_hour(ts);
        let dow_val = parse_day_of_week(ts);
        let dom_val = parse_day_of_month(ts);
        let moy_val = parse_month(ts);

        // ── Update bank state ────────────────────────────────────────
        self.prev_close = close;
        self.count += 1;

        // ── Construct Candle ─────────────────────────────────────────
        Candle {
            ts: ts.clone(),
            open,
            high,
            low,
            close,
            volume,
            sma20: sma20_val,
            sma50: sma50_val,
            sma200: sma200_val,
            bb_upper: bb_upper_val,
            bb_lower: bb_lower_val,
            bb_width: bb_width_val,
            bb_pos: bb_pos_val,
            rsi: rsi_val,
            macd: macd_val,
            macd_signal: macd_signal_val,
            macd_hist: macd_hist_val,
            plus_di: plus_di_val,
            minus_di: minus_di_val,
            adx: adx_val,
            atr: atr_val,
            atr_r: atr_r_val,
            stoch_k: stoch_k_val,
            stoch_d: stoch_d_val,
            williams_r: williams_r_val,
            cci: cci_val,
            mfi: mfi_val,
            obv_slope_12: obv_slope_12_val,
            volume_accel: volume_accel_val,
            kelt_upper: kelt_upper_val,
            kelt_lower: kelt_lower_val,
            kelt_pos: kelt_pos_val,
            squeeze: squeeze_val,
            roc_1: roc_1_val,
            roc_3: roc_3_val,
            roc_6: roc_6_val,
            roc_12: roc_12_val,
            atr_roc_6: atr_roc_6_val,
            atr_roc_12: atr_roc_12_val,
            trend_consistency_6: tc_6,
            trend_consistency_12: tc_12,
            trend_consistency_24: tc_24,
            range_pos_12: range_pos_12_val,
            range_pos_24: range_pos_24_val,
            range_pos_48: range_pos_48_val,
            tf_1h_close: tf_1h_close_val,
            tf_1h_high: tf_1h_high_val,
            tf_1h_low: tf_1h_low_val,
            tf_1h_ret: tf_1h_ret_val,
            tf_1h_body: tf_1h_body_val,
            tf_4h_close: tf_4h_close_val,
            tf_4h_high: tf_4h_high_val,
            tf_4h_low: tf_4h_low_val,
            tf_4h_ret: tf_4h_ret_val,
            tf_4h_body: tf_4h_body_val,
            tenkan_sen: tenkan_val,
            kijun_sen: kijun_val,
            senkou_span_a: senkou_a_val,
            senkou_span_b: senkou_b_val,
            cloud_top: cloud_top_val,
            cloud_bottom: cloud_bottom_val,
            hurst: hurst_val,
            autocorrelation: autocorrelation_val,
            vwap_distance: vwap_distance_val,
            kama_er: kama_er_val,
            choppiness: choppiness_val,
            dfa_alpha: dfa_alpha_val,
            variance_ratio: variance_ratio_val,
            entropy_rate: entropy_rate_val,
            aroon_up: aroon_up_val,
            aroon_down: aroon_down_val,
            fractal_dim: fractal_dim_val,
            rsi_divergence_bull: rsi_div_bull,
            rsi_divergence_bear: rsi_div_bear,
            tk_cross_delta: tk_cross_delta_val,
            stoch_cross_delta: stoch_cross_delta_val,
            range_ratio: range_ratio_val,
            gap: gap_val,
            consecutive_up: consecutive_up_val,
            consecutive_down: consecutive_down_val,
            tf_agreement: tf_agreement_val,
            minute: minute_val,
            hour: hour_val,
            day_of_week: dow_val,
            day_of_month: dom_val,
            month_of_year: moy_val,
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raw_candle::Asset;

    // ── RingBuffer ───────────────────────────────────────────────

    #[test]
    fn test_ring_buffer_push_and_len() {
        let mut rb = RingBuffer::new(3);
        assert_eq!(rb.len(), 0);
        assert!(!rb.full());

        rb.push(1.0);
        rb.push(2.0);
        assert_eq!(rb.len(), 2);
        assert!(!rb.full());

        rb.push(3.0);
        assert_eq!(rb.len(), 3);
        assert!(rb.full());
    }

    #[test]
    fn test_ring_buffer_wrap_around() {
        let mut rb = RingBuffer::new(3);
        rb.push(1.0);
        rb.push(2.0);
        rb.push(3.0);
        assert_eq!(rb.oldest(), 1.0);
        assert_eq!(rb.newest(), 3.0);

        // Wrap
        rb.push(4.0);
        assert_eq!(rb.len(), 3);
        assert_eq!(rb.oldest(), 2.0);
        assert_eq!(rb.newest(), 4.0);

        rb.push(5.0);
        assert_eq!(rb.oldest(), 3.0);
        assert_eq!(rb.newest(), 5.0);
    }

    #[test]
    fn test_ring_buffer_get_indexing() {
        let mut rb = RingBuffer::new(4);
        rb.push(10.0);
        rb.push(20.0);
        rb.push(30.0);
        rb.push(40.0);
        // i=0 oldest, i=3 newest
        assert_eq!(rb.get(0), 10.0);
        assert_eq!(rb.get(1), 20.0);
        assert_eq!(rb.get(2), 30.0);
        assert_eq!(rb.get(3), 40.0);

        // After wrap
        rb.push(50.0);
        assert_eq!(rb.get(0), 20.0);
        assert_eq!(rb.get(3), 50.0);
    }

    #[test]
    fn test_ring_buffer_max_min_sum() {
        let mut rb = RingBuffer::new(5);
        rb.push(3.0);
        rb.push(1.0);
        rb.push(4.0);
        rb.push(1.0);
        rb.push(5.0);
        assert_eq!(rb.max(), 5.0);
        assert_eq!(rb.min(), 1.0);
        assert_eq!(rb.sum(), 14.0);
    }

    #[test]
    fn test_ring_buffer_to_vec() {
        let mut rb = RingBuffer::new(3);
        rb.push(1.0);
        rb.push(2.0);
        rb.push(3.0);
        assert_eq!(rb.to_vec(), vec![1.0, 2.0, 3.0]);

        rb.push(4.0);
        assert_eq!(rb.to_vec(), vec![2.0, 3.0, 4.0]);
    }

    // ── EMA / SMA / Wilder ───────────────────────────────────────

    #[test]
    fn test_sma_basic() {
        let mut sma = SmaState::new(3);
        let v1 = sma_step(&mut sma, 10.0);
        assert_eq!(v1, 10.0); // only 1 value
        let v2 = sma_step(&mut sma, 20.0);
        assert_eq!(v2, 15.0); // (10+20)/2
        let v3 = sma_step(&mut sma, 30.0);
        assert_eq!(v3, 20.0); // (10+20+30)/3
        let v4 = sma_step(&mut sma, 40.0);
        assert_eq!(v4, 30.0); // (20+30+40)/3
    }

    #[test]
    fn test_ema_warmup_and_convergence() {
        let mut ema = EmaState::new(3);
        // During warmup (first 3 values), accumulates for SMA seed
        let v1 = ema_step(&mut ema, 10.0);
        assert_eq!(v1, 10.0);
        let v2 = ema_step(&mut ema, 20.0);
        assert_eq!(v2, 20.0);
        // Third value: seed = (10+20+30)/3 = 20
        let v3 = ema_step(&mut ema, 30.0);
        assert!((v3 - 20.0).abs() < 1e-10);
        // After warmup: EMA smoothing kicks in
        let v4 = ema_step(&mut ema, 40.0);
        // smoothing = 2/(3+1) = 0.5
        // new = 0.5*40 + 0.5*20 = 30
        assert!((v4 - 30.0).abs() < 1e-10);
    }

    #[test]
    fn test_wilder_warmup_and_convergence() {
        let mut ws = WilderState::new(3);
        wilder_step(&mut ws, 10.0);
        wilder_step(&mut ws, 20.0);
        // Third: seed = (10+20+30)/3 = 20
        let v3 = wilder_step(&mut ws, 30.0);
        assert!((v3 - 20.0).abs() < 1e-10);
        // After: Wilder = value/period + (period-1)/period * prev
        // = 40/3 + 2/3 * 20 = 13.333 + 13.333 = 26.667
        let v4 = wilder_step(&mut ws, 40.0);
        let expected = 40.0 / 3.0 + 2.0 / 3.0 * 20.0;
        assert!((v4 - expected).abs() < 1e-10);
    }

    // ── RSI ──────────────────────────────────────────────────────

    #[test]
    fn test_rsi_first_value() {
        let mut rsi = RsiState::new(14);
        let v = rsi_step(&mut rsi, 100.0);
        assert_eq!(v, 50.0); // first value always 50
    }

    #[test]
    fn test_rsi_all_up() {
        let mut rsi = RsiState::new(14);
        // Feed monotonically increasing prices
        for i in 0..=30 {
            rsi_step(&mut rsi, 100.0 + i as f64);
        }
        let val = rsi_step(&mut rsi, 132.0);
        // All gains, no losses -> RSI should be 100
        assert_eq!(val, 100.0);
    }

    #[test]
    fn test_rsi_all_down() {
        let mut rsi = RsiState::new(14);
        for i in 0..=30 {
            rsi_step(&mut rsi, 200.0 - i as f64);
        }
        let val = rsi_step(&mut rsi, 168.0);
        // All losses, no gains -> RSI should be 0
        assert!((val - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_rsi_mixed_bounded() {
        let mut rsi = RsiState::new(14);
        // Alternating up/down
        for i in 0..100 {
            let price = 100.0 + if i % 2 == 0 { 5.0 } else { -5.0 };
            rsi_step(&mut rsi, price);
        }
        let val = rsi_step(&mut rsi, 105.0);
        assert!(val > 0.0 && val < 100.0, "RSI should be between 0 and 100, got {}", val);
    }

    // ── ATR ──────────────────────────────────────────────────────

    #[test]
    fn test_atr_known_true_range() {
        let mut atr = AtrState::new(14);
        // First candle: TR = high - low = 10
        let v1 = atr_step(&mut atr, 110.0, 100.0, 105.0);
        assert_eq!(v1, 10.0); // first TR = H-L

        // Second candle: prev_close=105, high=112, low=103
        // TR = max(112-103, |112-105|, |103-105|) = max(9, 7, 2) = 9
        let v2 = atr_step(&mut atr, 112.0, 103.0, 108.0);
        // Wilder warmup: accumulating, count=2 < period=14
        assert!(v2 > 0.0);
    }

    #[test]
    fn test_atr_positive_after_warmup() {
        let mut atr = AtrState::new(14);
        for i in 0..20 {
            let base = 100.0 + (i as f64) * 0.5;
            atr_step(&mut atr, base + 5.0, base - 5.0, base);
        }
        // After 20 candles (past warmup), ATR should be positive
        let val = atr_step(&mut atr, 115.0, 105.0, 110.0);
        assert!(val > 0.0, "ATR should be positive, got {}", val);
    }

    // ── linreg_slope ─────────────────────────────────────────────

    #[test]
    fn test_linreg_slope_uptrend() {
        let mut rb = RingBuffer::new(5);
        for i in 0..5 {
            rb.push(i as f64 * 10.0); // 0, 10, 20, 30, 40
        }
        let slope = linreg_slope(&rb);
        assert!((slope - 10.0).abs() < 1e-10, "Expected slope 10.0, got {}", slope);
    }

    #[test]
    fn test_linreg_slope_flat() {
        let mut rb = RingBuffer::new(5);
        for _ in 0..5 {
            rb.push(42.0);
        }
        let slope = linreg_slope(&rb);
        assert!((slope).abs() < 1e-10, "Expected slope 0.0, got {}", slope);
    }

    #[test]
    fn test_linreg_slope_too_few() {
        let mut rb = RingBuffer::new(5);
        rb.push(1.0);
        assert_eq!(linreg_slope(&rb), 0.0);
    }

    // ── Time parsing ─────────────────────────────────────────────

    #[test]
    fn test_parse_minute() {
        assert_eq!(parse_minute("2025-01-15T14:35:00Z"), 35.0);
        assert_eq!(parse_minute("2025-01-15T00:00:00Z"), 0.0);
        assert_eq!(parse_minute("2025-12-31T23:59:00Z"), 59.0);
    }

    #[test]
    fn test_parse_hour() {
        assert_eq!(parse_hour("2025-01-15T14:35:00Z"), 14.0);
        assert_eq!(parse_hour("2025-01-15T00:00:00Z"), 0.0);
        assert_eq!(parse_hour("2025-12-31T23:59:00Z"), 23.0);
    }

    #[test]
    fn test_parse_day_of_week() {
        // 2025-01-06 is a Monday = 1
        assert_eq!(parse_day_of_week("2025-01-06T00:00:00Z"), 1.0);
        // 2025-01-12 is a Sunday = 7
        assert_eq!(parse_day_of_week("2025-01-12T00:00:00Z"), 7.0);
    }

    #[test]
    fn test_parse_day_of_month() {
        assert_eq!(parse_day_of_month("2025-01-15T14:35:00Z"), 15.0);
        assert_eq!(parse_day_of_month("2025-12-01T00:00:00Z"), 1.0);
    }

    #[test]
    fn test_parse_month() {
        assert_eq!(parse_month("2025-01-15T14:35:00Z"), 1.0);
        assert_eq!(parse_month("2025-12-01T00:00:00Z"), 12.0);
    }

    // ── tick integration ─────────────────────────────────────────

    fn make_raw_candle(ts: &str, open: f64, high: f64, low: f64, close: f64, volume: f64) -> RawCandle {
        RawCandle::new(
            Asset::new("BTC".to_string()),
            Asset::new("USDT".to_string()),
            ts.to_string(),
            open,
            high,
            low,
            close,
            volume,
        )
    }

    #[test]
    fn test_tick_first_candle_populated() {
        let mut bank = IndicatorBank::new();
        let rc = make_raw_candle("2025-01-15T14:35:00Z", 100.0, 110.0, 90.0, 105.0, 5000.0);
        let c = bank.tick(&rc);
        assert_eq!(c.ts, "2025-01-15T14:35:00Z");
        assert_eq!(c.open, 100.0);
        assert_eq!(c.high, 110.0);
        assert_eq!(c.low, 90.0);
        assert_eq!(c.close, 105.0);
        assert_eq!(c.volume, 5000.0);
        // SMA20 on first candle = close itself
        assert_eq!(c.sma20, 105.0);
        // RSI on first candle = 50
        assert_eq!(c.rsi, 50.0);
        // ATR on first candle = high - low = 20
        assert_eq!(c.atr, 20.0);
        // Time
        assert_eq!(c.minute, 35.0);
        assert_eq!(c.hour, 14.0);
        assert_eq!(c.day_of_month, 15.0);
        assert_eq!(c.month_of_year, 1.0);
    }

    #[test]
    fn test_tick_multiple_candles_no_nan() {
        let mut bank = IndicatorBank::new();
        // Feed 60 candles (past all warmup periods)
        for i in 0..60 {
            let base = 100.0 + (i as f64) * 0.5;
            let volume = 1000.0 + (i as f64) * 10.0;
            let rc = make_raw_candle(
                "2025-01-15T14:35:00Z",
                base,
                base + 3.0,
                base - 2.0,
                base + 1.0,
                volume,
            );
            bank.tick(&rc);
        }
        // One more candle — check all fields are finite
        let rc = make_raw_candle("2025-03-15T10:20:00Z", 130.0, 134.0, 128.0, 132.0, 2000.0);
        let c = bank.tick(&rc);

        assert!(c.sma20.is_finite(), "sma20 is not finite");
        assert!(c.sma50.is_finite(), "sma50 is not finite");
        assert!(c.sma200.is_finite(), "sma200 is not finite");
        assert!(c.bb_upper.is_finite(), "bb_upper is not finite");
        assert!(c.bb_lower.is_finite(), "bb_lower is not finite");
        assert!(c.bb_width.is_finite(), "bb_width is not finite");
        assert!(c.bb_pos.is_finite(), "bb_pos is not finite");
        assert!(c.rsi.is_finite(), "rsi is not finite");
        assert!(c.macd.is_finite(), "macd is not finite");
        assert!(c.macd_signal.is_finite(), "macd_signal is not finite");
        assert!(c.macd_hist.is_finite(), "macd_hist is not finite");
        assert!(c.plus_di.is_finite(), "plus_di is not finite");
        assert!(c.minus_di.is_finite(), "minus_di is not finite");
        assert!(c.adx.is_finite(), "adx is not finite");
        assert!(c.atr.is_finite(), "atr is not finite");
        assert!(c.atr_r.is_finite(), "atr_r is not finite");
        assert!(c.stoch_k.is_finite(), "stoch_k is not finite");
        assert!(c.stoch_d.is_finite(), "stoch_d is not finite");
        assert!(c.williams_r.is_finite(), "williams_r is not finite");
        assert!(c.cci.is_finite(), "cci is not finite");
        assert!(c.mfi.is_finite(), "mfi is not finite");
        assert!(c.obv_slope_12.is_finite(), "obv_slope_12 is not finite");
        assert!(c.volume_accel.is_finite(), "volume_accel is not finite");
        assert!(c.kelt_upper.is_finite(), "kelt_upper is not finite");
        assert!(c.kelt_lower.is_finite(), "kelt_lower is not finite");
        assert!(c.kelt_pos.is_finite(), "kelt_pos is not finite");
        assert!(c.squeeze.is_finite(), "squeeze is not finite");
        assert!(c.roc_1.is_finite(), "roc_1 is not finite");
        assert!(c.roc_3.is_finite(), "roc_3 is not finite");
        assert!(c.roc_6.is_finite(), "roc_6 is not finite");
        assert!(c.roc_12.is_finite(), "roc_12 is not finite");
        assert!(c.atr_roc_6.is_finite(), "atr_roc_6 is not finite");
        assert!(c.atr_roc_12.is_finite(), "atr_roc_12 is not finite");
        assert!(c.trend_consistency_6.is_finite(), "tc_6 is not finite");
        assert!(c.trend_consistency_12.is_finite(), "tc_12 is not finite");
        assert!(c.trend_consistency_24.is_finite(), "tc_24 is not finite");
        assert!(c.range_pos_12.is_finite(), "range_pos_12 is not finite");
        assert!(c.range_pos_24.is_finite(), "range_pos_24 is not finite");
        assert!(c.range_pos_48.is_finite(), "range_pos_48 is not finite");
        assert!(c.tf_1h_close.is_finite(), "tf_1h_close is not finite");
        assert!(c.tf_1h_high.is_finite(), "tf_1h_high is not finite");
        assert!(c.tf_1h_low.is_finite(), "tf_1h_low is not finite");
        assert!(c.tf_1h_ret.is_finite(), "tf_1h_ret is not finite");
        assert!(c.tf_1h_body.is_finite(), "tf_1h_body is not finite");
        assert!(c.tf_4h_close.is_finite(), "tf_4h_close is not finite");
        assert!(c.tf_4h_high.is_finite(), "tf_4h_high is not finite");
        assert!(c.tf_4h_low.is_finite(), "tf_4h_low is not finite");
        assert!(c.tf_4h_ret.is_finite(), "tf_4h_ret is not finite");
        assert!(c.tf_4h_body.is_finite(), "tf_4h_body is not finite");
        assert!(c.tenkan_sen.is_finite(), "tenkan_sen is not finite");
        assert!(c.kijun_sen.is_finite(), "kijun_sen is not finite");
        assert!(c.senkou_span_a.is_finite(), "senkou_span_a is not finite");
        assert!(c.senkou_span_b.is_finite(), "senkou_span_b is not finite");
        assert!(c.cloud_top.is_finite(), "cloud_top is not finite");
        assert!(c.cloud_bottom.is_finite(), "cloud_bottom is not finite");
        assert!(c.hurst.is_finite(), "hurst is not finite");
        assert!(c.autocorrelation.is_finite(), "autocorrelation is not finite");
        assert!(c.vwap_distance.is_finite(), "vwap_distance is not finite");
        assert!(c.kama_er.is_finite(), "kama_er is not finite");
        assert!(c.choppiness.is_finite(), "choppiness is not finite");
        assert!(c.dfa_alpha.is_finite(), "dfa_alpha is not finite");
        assert!(c.variance_ratio.is_finite(), "variance_ratio is not finite");
        assert!(c.entropy_rate.is_finite(), "entropy_rate is not finite");
        assert!(c.aroon_up.is_finite(), "aroon_up is not finite");
        assert!(c.aroon_down.is_finite(), "aroon_down is not finite");
        assert!(c.fractal_dim.is_finite(), "fractal_dim is not finite");
        assert!(c.rsi_divergence_bull.is_finite(), "rsi_div_bull is not finite");
        assert!(c.rsi_divergence_bear.is_finite(), "rsi_div_bear is not finite");
        assert!(c.tk_cross_delta.is_finite(), "tk_cross_delta is not finite");
        assert!(c.stoch_cross_delta.is_finite(), "stoch_cross_delta is not finite");
        assert!(c.range_ratio.is_finite(), "range_ratio is not finite");
        assert!(c.gap.is_finite(), "gap is not finite");
        assert!(c.consecutive_up.is_finite(), "consecutive_up is not finite");
        assert!(c.consecutive_down.is_finite(), "consecutive_down is not finite");
        assert!(c.tf_agreement.is_finite(), "tf_agreement is not finite");
    }

    #[test]
    fn test_tick_warmup_values_nonzero() {
        let mut bank = IndicatorBank::new();
        // Feed 250 candles (past SMA200 warmup)
        for i in 0..250 {
            let base = 100.0 + (i as f64) * 0.2;
            let rc = make_raw_candle(
                "2025-06-15T12:00:00Z",
                base,
                base + 4.0,
                base - 3.0,
                base + 1.0,
                1000.0 + (i as f64) * 5.0,
            );
            bank.tick(&rc);
        }
        let rc = make_raw_candle("2025-06-15T12:05:00Z", 150.0, 155.0, 148.0, 152.0, 3000.0);
        let c = bank.tick(&rc);

        // After 250 candles, all SMAs should be non-zero
        assert!(c.sma20 > 0.0, "sma20 should be > 0 after warmup");
        assert!(c.sma50 > 0.0, "sma50 should be > 0 after warmup");
        assert!(c.sma200 > 0.0, "sma200 should be > 0 after warmup");
        assert!(c.atr > 0.0, "atr should be > 0 after warmup");
        assert!(c.adx >= 0.0, "adx should be >= 0 after warmup");
    }

    // ── Stochastic ───────────────────────────────────────────────

    #[test]
    fn test_stoch_at_high() {
        let mut ss = StochState::new(5, 3);
        // Push 5 candles with same range, close at high
        for _ in 0..5 {
            stoch_step(&mut ss, 110.0, 90.0, 110.0);
        }
        let (k, _d) = stoch_step(&mut ss, 110.0, 90.0, 110.0);
        assert!((k - 100.0).abs() < 1e-10, "Stoch K at high should be 100, got {}", k);
    }

    #[test]
    fn test_stoch_at_low() {
        let mut ss = StochState::new(5, 3);
        for _ in 0..5 {
            stoch_step(&mut ss, 110.0, 90.0, 90.0);
        }
        let (k, _d) = stoch_step(&mut ss, 110.0, 90.0, 90.0);
        assert!((k - 0.0).abs() < 1e-10, "Stoch K at low should be 0, got {}", k);
    }

    // ── MACD ─────────────────────────────────────────────────────

    #[test]
    fn test_macd_constant_input() {
        let mut ms = MacdState::new();
        // Constant price -> MACD, signal, hist should all converge to 0
        for _ in 0..100 {
            macd_step(&mut ms, 100.0);
        }
        let (macd_val, signal, hist) = macd_step(&mut ms, 100.0);
        assert!(macd_val.abs() < 1e-6, "MACD should be ~0 for constant, got {}", macd_val);
        assert!(signal.abs() < 1e-6, "Signal should be ~0 for constant, got {}", signal);
        assert!(hist.abs() < 1e-6, "Hist should be ~0 for constant, got {}", hist);
    }

    // ── Rolling stddev ───────────────────────────────────────────

    #[test]
    fn test_rolling_stddev_constant() {
        let mut rs = RollingStddev::new(5);
        for _ in 0..10 {
            rolling_stddev_step(&mut rs, 42.0);
        }
        let sd = rolling_stddev_step(&mut rs, 42.0);
        assert!(sd.abs() < 1e-10, "Stddev of constant should be 0, got {}", sd);
    }

    #[test]
    fn test_rolling_stddev_known() {
        let mut rs = RollingStddev::new(3);
        rolling_stddev_step(&mut rs, 1.0);
        rolling_stddev_step(&mut rs, 2.0);
        let sd = rolling_stddev_step(&mut rs, 3.0);
        // mean=2, variance = ((1-2)^2 + (2-2)^2 + (3-2)^2)/3 = 2/3
        let expected = (2.0_f64 / 3.0).sqrt();
        assert!((sd - expected).abs() < 1e-10, "Expected {}, got {}", expected, sd);
    }

    // ── Helper functions ─────────────────────────────────────────

    #[test]
    fn test_compute_hurst_short() {
        let rb = RingBuffer::new(4);
        assert_eq!(compute_hurst(&rb), 0.5);
    }

    #[test]
    fn test_compute_kama_er_trending() {
        let mut rb = RingBuffer::new(10);
        // Perfect trend: direction = volatility
        for i in 0..10 {
            rb.push(i as f64);
        }
        let er = compute_kama_er(&rb);
        assert!((er - 1.0).abs() < 1e-10, "Perfect trend ER should be 1.0, got {}", er);
    }

    #[test]
    fn test_compute_tf_agreement_all_same() {
        let score = compute_tf_agreement(1.0, 1.0, 1.0);
        assert!((score - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_compute_tf_agreement_partial() {
        // In Rust, (0.0).signum() = 1.0, so (1.0, -1.0, 0.0)
        // means five_dir=1.0, one_dir=-1.0, four_dir=1.0 — one pair matches
        let score = compute_tf_agreement(1.0, -1.0, 0.0);
        assert!((score - 1.0 / 3.0).abs() < 1e-10, "Expected 1/3, got {}", score);
    }

    #[test]
    fn test_compute_tf_agreement_none_agree() {
        // two positive, one negative — two pairs agree
        let score = compute_tf_agreement(1.0, 2.0, -1.0);
        // five_dir=1, one_dir=1, four_dir=-1 — (five,one) agree, others don't = 1/3
        assert!((score - 1.0 / 3.0).abs() < 1e-10, "Expected 1/3, got {}", score);
    }
}
