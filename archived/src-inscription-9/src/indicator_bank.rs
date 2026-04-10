/// Streaming state machine for technical indicators.
/// Advances all indicators by one raw candle. Stateful.
/// One per post (one per asset pair).

use crate::candle::Candle;
use crate::raw_candle::RawCandle;

// ── Ring Buffer ───────────────────────────────────────────────────

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

    /// Get value from `ago` steps back. 0 = most recent.
    pub fn get(&self, ago: usize) -> f64 {
        let idx = (self.head + self.capacity * 2 - 1 - ago) % self.capacity;
        self.data[idx]
    }

    pub fn is_full(&self) -> bool {
        self.len == self.capacity
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
}

// ── EMA state ─────────────────────────────────────────────────────

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
            smoothing: 2.0 / (1.0 + period as f64),
            period,
            count: 0,
            accum: 0.0,
        }
    }

    pub fn update(&mut self, value: f64) {
        self.count += 1;
        self.accum += value;
        if self.count < self.period {
            // Warming up
        } else if self.count == self.period {
            // First valid — SMA seed
            self.value = self.accum / self.period as f64;
        } else {
            // Normal EMA
            self.value = self.smoothing * value + (1.0 - self.smoothing) * self.value;
        }
    }
}

// ── Wilder state ──────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct WilderState {
    pub value: f64,
    pub period: usize,
    pub count: usize,
    pub accum: f64,
}

impl WilderState {
    pub fn new(period: usize) -> Self {
        Self { value: 0.0, period, count: 0, accum: 0.0 }
    }

    pub fn update(&mut self, value: f64) {
        self.count += 1;
        self.accum += value;
        let p = self.period as f64;
        if self.count < self.period {
            // Warming up
        } else if self.count == self.period {
            self.value = self.accum / p;
        } else {
            self.value = value / p + (p - 1.0) / p * self.value;
        }
    }
}

// ── RSI state ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct RsiState {
    pub gain_smoother: WilderState,
    pub loss_smoother: WilderState,
    pub prev_close: f64,
    pub started: bool,
}

impl RsiState {
    pub fn new() -> Self {
        Self {
            gain_smoother: WilderState::new(14),
            loss_smoother: WilderState::new(14),
            prev_close: 0.0,
            started: false,
        }
    }

    pub fn update(&mut self, close: f64) {
        if !self.started {
            self.prev_close = close;
            self.started = true;
            return;
        }
        let change = close - self.prev_close;
        let gain = if change > 0.0 { change } else { 0.0 };
        let loss = if change < 0.0 { change.abs() } else { 0.0 };
        self.gain_smoother.update(gain);
        self.loss_smoother.update(loss);
        self.prev_close = close;
    }

    pub fn value(&self) -> f64 {
        let avg_gain = self.gain_smoother.value;
        let avg_loss = self.loss_smoother.value;
        if avg_loss == 0.0 {
            if avg_gain == 0.0 { 50.0 } else { 100.0 }
        } else {
            let rs = avg_gain / avg_loss;
            100.0 - 100.0 / (1.0 + rs)
        }
    }
}

// ── ATR state ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct AtrState {
    pub wilder: WilderState,
    pub prev_close: f64,
    pub started: bool,
}

impl AtrState {
    pub fn new() -> Self {
        Self {
            wilder: WilderState::new(14),
            prev_close: 0.0,
            started: false,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        if !self.started {
            self.prev_close = close;
            self.started = true;
            self.wilder.update(high - low);
            return;
        }
        let tr = (high - low)
            .max((high - self.prev_close).abs())
            .max((low - self.prev_close).abs());
        self.wilder.update(tr);
        self.prev_close = close;
    }
}

// ── OBV state ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct ObvState {
    pub obv: f64,
    pub prev_close: f64,
    pub history: RingBuffer,
    pub started: bool,
}

impl ObvState {
    pub fn new() -> Self {
        Self {
            obv: 0.0,
            prev_close: 0.0,
            history: RingBuffer::new(12),
            started: false,
        }
    }

    pub fn update(&mut self, close: f64, volume: f64) {
        if !self.started {
            self.prev_close = close;
            self.started = true;
            self.history.push(0.0);
            return;
        }
        if close > self.prev_close {
            self.obv += volume;
        } else if close < self.prev_close {
            self.obv -= volume;
        }
        self.prev_close = close;
        self.history.push(self.obv);
    }
}

// ── SMA state ─────────────────────────────────────────────────────

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
        let old_val = if self.buffer.is_full() {
            self.buffer.get(self.buffer.capacity - 1)
        } else {
            0.0
        };
        self.sum = self.sum - old_val + value;
        self.buffer.push(value);
    }

    pub fn value(&self) -> f64 {
        if self.buffer.len == 0 {
            0.0
        } else {
            self.sum / self.buffer.len as f64
        }
    }
}

// ── Rolling stddev ────────────────────────────────────────────────

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
        let old_val = if self.buffer.is_full() {
            self.buffer.get(self.buffer.capacity - 1)
        } else {
            0.0
        };
        self.sum = self.sum - old_val + value;
        self.sum_sq = self.sum_sq - old_val * old_val + value * value;
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
}

// ── Stochastic state ──────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct StochState {
    pub high_buf: RingBuffer,
    pub low_buf: RingBuffer,
    pub k_buf: RingBuffer,
}

impl StochState {
    pub fn new() -> Self {
        Self {
            high_buf: RingBuffer::new(14),
            low_buf: RingBuffer::new(14),
            k_buf: RingBuffer::new(3),
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        self.high_buf.push(high);
        self.low_buf.push(low);
        let highest = self.high_buf.max();
        let lowest = self.low_buf.min();
        let k_raw = if highest == lowest {
            50.0
        } else {
            100.0 * (close - lowest) / (highest - lowest)
        };
        self.k_buf.push(k_raw);
    }
}

// ── CCI state ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct CciState {
    pub tp_buf: RingBuffer,
    pub tp_sma: SmaState,
}

impl CciState {
    pub fn new() -> Self {
        Self {
            tp_buf: RingBuffer::new(20),
            tp_sma: SmaState::new(20),
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        let tp = (high + low + close) / 3.0;
        self.tp_buf.push(tp);
        self.tp_sma.update(tp);
    }

    pub fn value(&self) -> f64 {
        let tp_mean = self.tp_sma.value();
        let n = self.tp_buf.len;
        if n == 0 {
            return 0.0;
        }
        let mut mean_dev = 0.0;
        for i in 0..n {
            mean_dev += (self.tp_buf.get(i) - tp_mean).abs();
        }
        mean_dev /= n as f64;
        if mean_dev == 0.0 {
            0.0
        } else {
            (self.tp_buf.get(0) - tp_mean) / (0.015 * mean_dev)
        }
    }
}

// ── MFI state ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct MfiState {
    pub pos_flow_buf: RingBuffer,
    pub neg_flow_buf: RingBuffer,
    pub prev_tp: f64,
    pub started: bool,
}

impl MfiState {
    pub fn new() -> Self {
        Self {
            pos_flow_buf: RingBuffer::new(14),
            neg_flow_buf: RingBuffer::new(14),
            prev_tp: 0.0,
            started: false,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64, volume: f64) {
        let tp = (high + low + close) / 3.0;
        let money_flow = tp * volume;
        if !self.started {
            self.prev_tp = tp;
            self.started = true;
            self.pos_flow_buf.push(0.0);
            self.neg_flow_buf.push(0.0);
            return;
        }
        if tp > self.prev_tp {
            self.pos_flow_buf.push(money_flow);
            self.neg_flow_buf.push(0.0);
        } else {
            self.pos_flow_buf.push(0.0);
            self.neg_flow_buf.push(money_flow);
        }
        self.prev_tp = tp;
    }

    pub fn value(&self) -> f64 {
        let pos_sum = self.pos_flow_buf.sum();
        let neg_sum = self.neg_flow_buf.sum();
        if neg_sum == 0.0 {
            100.0
        } else {
            let ratio = pos_sum / neg_sum;
            100.0 - 100.0 / (1.0 + ratio)
        }
    }
}

// ── Ichimoku state ────────────────────────────────────────────────

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
}

// ── MACD state ────────────────────────────────────────────────────

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
        let macd_line = self.fast_ema.value - self.slow_ema.value;
        self.signal_ema.update(macd_line);
    }
}

// ── DMI state ─────────────────────────────────────────────────────

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
    pub fn new() -> Self {
        Self {
            plus_smoother: WilderState::new(14),
            minus_smoother: WilderState::new(14),
            tr_smoother: WilderState::new(14),
            adx_smoother: WilderState::new(14),
            prev_high: 0.0,
            prev_low: 0.0,
            prev_close: 0.0,
            started: false,
            count: 0,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) {
        if !self.started {
            self.prev_high = high;
            self.prev_low = low;
            self.prev_close = close;
            self.started = true;
            self.count = 1;
            return;
        }
        let up_move = high - self.prev_high;
        let down_move = self.prev_low - low;
        let plus_dm = if up_move > down_move && up_move > 0.0 { up_move } else { 0.0 };
        let minus_dm = if down_move > up_move && down_move > 0.0 { down_move } else { 0.0 };
        let tr = (high - low)
            .max((high - self.prev_close).abs())
            .max((low - self.prev_close).abs());

        self.plus_smoother.update(plus_dm);
        self.minus_smoother.update(minus_dm);
        self.tr_smoother.update(tr);

        let atr_val = self.tr_smoother.value;
        let plus_di = if atr_val == 0.0 { 0.0 } else { 100.0 * self.plus_smoother.value / atr_val };
        let minus_di = if atr_val == 0.0 { 0.0 } else { 100.0 * self.minus_smoother.value / atr_val };
        let di_sum = plus_di + minus_di;
        let dx = if di_sum == 0.0 { 0.0 } else { 100.0 * (plus_di - minus_di).abs() / di_sum };
        self.adx_smoother.update(dx);

        self.prev_high = high;
        self.prev_low = low;
        self.prev_close = close;
        self.count += 1;
    }
}

// ── Linear regression slope ───────────────────────────────────────

pub fn linreg_slope(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 2 {
        return 0.0;
    }
    let nf = n as f64;
    let sum_x = nf * (nf - 1.0) / 2.0;
    let sum_x2 = nf * (nf - 1.0) * (2.0 * nf - 1.0) / 6.0;
    let mut sum_y = 0.0;
    let mut sum_xy = 0.0;
    for i in 0..n {
        let x = i as f64;
        let y = buf.get(n - 1 - i); // oldest to newest
        sum_y += y;
        sum_xy += x * y;
    }
    let denom = nf * sum_x2 - sum_x * sum_x;
    if denom == 0.0 {
        0.0
    } else {
        (nf * sum_xy - sum_x * sum_y) / denom
    }
}

// ── OBV slope (above linreg_slope) ───────────────────────────────

fn obv_slope_12(st: &ObvState) -> f64 {
    linreg_slope(&st.history)
}

// ── Hurst exponent (R/S analysis) ─────────────────────────────────

fn hurst_exponent(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 8 {
        return 0.5;
    }
    let values = buf.to_vec();
    let m: f64 = values.iter().sum::<f64>() / n as f64;
    let deviations: Vec<f64> = values.iter().map(|v| v - m).collect();
    let mut cum_dev = Vec::with_capacity(n);
    let mut running = 0.0;
    for d in &deviations {
        running += d;
        cum_dev.push(running);
    }
    let r = cum_dev.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
        - cum_dev.iter().cloned().fold(f64::INFINITY, f64::min);
    let s = (deviations.iter().map(|d| d * d).sum::<f64>() / n as f64).sqrt();
    if s == 0.0 {
        0.5
    } else {
        (r / s).ln() / (n as f64).ln()
    }
}

// ── Autocorrelation (lag-1) ───────────────────────────────────────

fn autocorrelation_lag1(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 3 {
        return 0.0;
    }
    let values = buf.to_vec();
    let m: f64 = values.iter().sum::<f64>() / n as f64;
    let var: f64 = values.iter().map(|v| (v - m) * (v - m)).sum::<f64>() / n as f64;
    if var == 0.0 {
        return 0.0;
    }
    let mut cov = 0.0;
    for i in 0..(n - 1) {
        cov += (values[i] - m) * (values[i + 1] - m);
    }
    (cov / (n - 1) as f64) / var
}

// ── DFA alpha ─────────────────────────────────────────────────────

fn dfa_alpha(buf: &RingBuffer) -> f64 {
    if buf.len < 16 {
        0.5
    } else {
        hurst_exponent(buf)
    }
}

// ── Variance ratio ────────────────────────────────────────────────

fn variance(vals: &[f64]) -> f64 {
    if vals.len() < 2 {
        return 0.0;
    }
    let m: f64 = vals.iter().sum::<f64>() / vals.len() as f64;
    vals.iter().map(|v| (v - m) * (v - m)).sum::<f64>() / vals.len() as f64
}

fn variance_ratio(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 4 {
        return 1.0;
    }
    let values = buf.to_vec();
    // Scale 1 returns
    let returns_1: Vec<f64> = (0..n - 1).map(|i| values[i + 1] - values[i]).collect();
    let var_1 = variance(&returns_1);
    // Scale 2 returns
    let returns_2: Vec<f64> = (0..n - 2).map(|i| values[i + 2] - values[i]).collect();
    let var_2 = variance(&returns_2);
    if var_1 == 0.0 {
        1.0
    } else {
        var_2 / (2.0 * var_1)
    }
}

// ── Entropy rate ──────────────────────────────────────────────────

fn entropy_rate(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 4 {
        return 0.0;
    }
    let values = buf.to_vec();
    let mut pos_count = 0.0f64;
    let mut neg_count = 0.0f64;
    let mut zero_count = 0.0f64;
    for i in 0..(n - 1) {
        let r = values[i + 1] - values[i];
        if r > 0.0 {
            pos_count += 1.0;
        } else if r < 0.0 {
            neg_count += 1.0;
        } else {
            zero_count += 1.0;
        }
    }
    let total = pos_count + neg_count + zero_count;
    let p_pos = pos_count / total;
    let p_neg = neg_count / total;
    let p_zero = zero_count / total;
    let h = |p: f64| -> f64 {
        if p == 0.0 { 0.0 } else { -p * p.ln() }
    };
    h(p_pos) + h(p_neg) + h(p_zero)
}

// ── Fractal dimension ─────────────────────────────────────────────

fn fractal_dimension(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 4 {
        return 1.5;
    }
    let values = buf.to_vec();
    // k=1
    let mut l1 = 0.0;
    for i in 0..(n - 1) {
        l1 += (values[i + 1] - values[i]).abs();
    }
    l1 /= (n - 1) as f64;
    // k=2
    let mut l2 = 0.0;
    for i in 0..(n - 2) {
        l2 += (values[i + 2] - values[i]).abs();
    }
    l2 /= (n - 2) as f64;
    if l1 == 0.0 || l2 == 0.0 {
        1.5
    } else {
        1.0 + (l1 / l2).ln() / 2.0f64.ln()
    }
}

// ── KAMA Efficiency Ratio ─────────────────────────────────────────

fn kama_efficiency_ratio(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n < 2 {
        return 0.0;
    }
    let values = buf.to_vec();
    let direction = (values[n - 1] - values[0]).abs();
    let mut volatility = 0.0;
    for i in 0..(n - 1) {
        volatility += (values[i + 1] - values[i]).abs();
    }
    if volatility == 0.0 {
        0.0
    } else {
        direction / volatility
    }
}

// ── Choppiness Index ──────────────────────────────────────────────

fn choppiness_index(atr_sum: f64, high_buf: &RingBuffer, low_buf: &RingBuffer) -> f64 {
    let highest = high_buf.max();
    let lowest = low_buf.min();
    let range_val = highest - lowest;
    let period = high_buf.len as f64;
    if range_val == 0.0 || period == 0.0 {
        50.0
    } else {
        100.0 * (atr_sum / range_val).ln() / period.ln()
    }
}

// ── Aroon ─────────────────────────────────────────────────────────

fn aroon_up(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n == 0 {
        return 50.0;
    }
    let mut max_idx = 0;
    for i in 1..n {
        if buf.get(i) >= buf.get(max_idx) {
            max_idx = i;
        }
    }
    100.0 * (n - 1 - max_idx) as f64 / (n - 1).max(1) as f64
}

fn aroon_down(buf: &RingBuffer) -> f64 {
    let n = buf.len;
    if n == 0 {
        return 50.0;
    }
    let mut min_idx = 0;
    for i in 1..n {
        if buf.get(i) <= buf.get(min_idx) {
            min_idx = i;
        }
    }
    100.0 * (n - 1 - min_idx) as f64 / (n - 1).max(1) as f64
}

// ── Time parsing ──────────────────────────────────────────────────

fn parse_minute(ts: &str) -> f64 {
    ts[14..16].parse::<f64>().unwrap_or(0.0)
}

fn parse_hour(ts: &str) -> f64 {
    ts[11..13].parse::<f64>().unwrap_or(0.0)
}

fn parse_day_of_week(ts: &str) -> f64 {
    // Zeller's congruence simplified
    let y: i64 = ts[0..4].parse().unwrap_or(2024);
    let m: i64 = ts[5..7].parse().unwrap_or(1);
    let d: i64 = ts[8..10].parse().unwrap_or(1);
    // Adjust for Zeller's: January and February are months 13, 14 of previous year
    let (y_adj, m_adj) = if m <= 2 { (y - 1, m + 12) } else { (y, m) };
    let q = d;
    let k = y_adj % 100;
    let j = y_adj / 100;
    let h = (q + (13 * (m_adj + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7;
    // h: 0=Sat,1=Sun,2=Mon,...,6=Fri -> convert to 0=Mon,...,6=Sun
    let dow = ((h + 5) % 7) as f64;
    dow
}

fn parse_day_of_month(ts: &str) -> f64 {
    ts[8..10].parse::<f64>().unwrap_or(1.0)
}

fn parse_month_of_year(ts: &str) -> f64 {
    ts[5..7].parse::<f64>().unwrap_or(1.0)
}

// ── Divergence detection ──────────────────────────────────────────

fn detect_divergence(price_buf: &RingBuffer, rsi_buf: &RingBuffer) -> (f64, f64) {
    let n = price_buf.len.min(rsi_buf.len);
    if n < 4 {
        return (0.0, 0.0);
    }
    let mid = n / 2;
    // Recent = indices 0..mid (most recent), Older = indices mid..n
    let mut recent_price_low = f64::INFINITY;
    let mut older_price_low = f64::INFINITY;
    let mut recent_rsi_low = f64::INFINITY;
    let mut older_rsi_low = f64::INFINITY;
    let mut recent_price_high = f64::NEG_INFINITY;
    let mut older_price_high = f64::NEG_INFINITY;
    let mut recent_rsi_high = f64::NEG_INFINITY;
    let mut older_rsi_high = f64::NEG_INFINITY;

    for i in 0..mid {
        let p = price_buf.get(i);
        let r = rsi_buf.get(i);
        recent_price_low = recent_price_low.min(p);
        recent_price_high = recent_price_high.max(p);
        recent_rsi_low = recent_rsi_low.min(r);
        recent_rsi_high = recent_rsi_high.max(r);
    }
    for i in mid..n {
        let p = price_buf.get(i);
        let r = rsi_buf.get(i);
        older_price_low = older_price_low.min(p);
        older_price_high = older_price_high.max(p);
        older_rsi_low = older_rsi_low.min(r);
        older_rsi_high = older_rsi_high.max(r);
    }

    // Bull: price lower low, RSI higher low
    let bull = if recent_price_low < older_price_low && recent_rsi_low > older_rsi_low {
        (recent_rsi_low - older_rsi_low).abs()
    } else {
        0.0
    };
    // Bear: price higher high, RSI lower high
    let bear = if recent_price_high > older_price_high && recent_rsi_high < older_rsi_high {
        (older_rsi_high - recent_rsi_high).abs()
    } else {
        0.0
    };
    (bull, bear)
}

// ── ROC helper ────────────────────────────────────────────────────

fn compute_roc(buf: &RingBuffer, ago: usize, current_close: f64) -> f64 {
    if buf.len <= ago {
        return 0.0;
    }
    let old_c = buf.get(ago);
    if old_c == 0.0 { 0.0 } else { (current_close - old_c) / old_c }
}

// ── The IndicatorBank ─────────────────────────────────────────────

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
    // Counter
    pub count: usize,
}

impl IndicatorBank {
    pub fn new() -> Self {
        Self {
            sma20: SmaState::new(20),
            sma50: SmaState::new(50),
            sma200: SmaState::new(200),
            ema20: EmaState::new(20),
            bb_stddev: RollingStddev::new(20),
            rsi: RsiState::new(),
            macd: MacdState::new(),
            dmi: DmiState::new(),
            atr: AtrState::new(),
            stoch: StochState::new(),
            cci: CciState::new(),
            mfi: MfiState::new(),
            obv: ObvState::new(),
            volume_sma20: SmaState::new(20),
            roc_buf: RingBuffer::new(12),
            range_high_12: RingBuffer::new(12),
            range_low_12: RingBuffer::new(12),
            range_high_24: RingBuffer::new(24),
            range_low_24: RingBuffer::new(24),
            range_high_48: RingBuffer::new(48),
            range_low_48: RingBuffer::new(48),
            trend_buf_24: RingBuffer::new(24),
            atr_history: RingBuffer::new(14),
            tf_1h_buf: RingBuffer::new(12),
            tf_1h_high: RingBuffer::new(12),
            tf_1h_low: RingBuffer::new(12),
            tf_4h_buf: RingBuffer::new(48),
            tf_4h_high: RingBuffer::new(48),
            tf_4h_low: RingBuffer::new(48),
            ichimoku: IchimokuState::new(),
            close_buf_48: RingBuffer::new(48),
            vwap_cum_vol: 0.0,
            vwap_cum_pv: 0.0,
            kama_er_buf: RingBuffer::new(10),
            chop_atr_sum: 0.0,
            chop_buf: RingBuffer::new(14),
            dfa_buf: RingBuffer::new(48),
            var_ratio_buf: RingBuffer::new(30),
            entropy_buf: RingBuffer::new(30),
            aroon_high_buf: RingBuffer::new(25),
            aroon_low_buf: RingBuffer::new(25),
            fractal_buf: RingBuffer::new(30),
            rsi_peak_buf: RingBuffer::new(20),
            price_peak_buf: RingBuffer::new(20),
            prev_tk_spread: 0.0,
            prev_stoch_kd: 0.0,
            prev_range: 0.0,
            consecutive_up_count: 0,
            consecutive_down_count: 0,
            prev_tf_1h_ret: 0.0,
            prev_tf_4h_ret: 0.0,
            prev_close: 0.0,
            count: 0,
        }
    }

    /// One raw candle in, one enriched Candle out.
    pub fn tick(&mut self, rc: &RawCandle) -> Candle {
        let o = rc.open;
        let h = rc.high;
        let l = rc.low;
        let c = rc.close;
        let v = rc.volume;
        let ts = &rc.ts;

        // Update all streaming state
        self.sma20.update(c);
        self.sma50.update(c);
        self.sma200.update(c);
        self.ema20.update(c);
        self.bb_stddev.update(c);
        self.rsi.update(c);
        self.macd.update(c);
        self.dmi.update(h, l, c);
        self.atr.update(h, l, c);
        self.stoch.update(h, l, c);
        self.cci.update(h, l, c);
        self.mfi.update(h, l, c, v);
        self.obv.update(c, v);
        self.volume_sma20.update(v);
        self.roc_buf.push(c);
        self.range_high_12.push(h);
        self.range_low_12.push(l);
        self.range_high_24.push(h);
        self.range_low_24.push(l);
        self.range_high_48.push(h);
        self.range_low_48.push(l);
        self.trend_buf_24.push(if c > self.prev_close { 1.0 } else { 0.0 });
        let atr_val = self.atr.wilder.value;
        self.atr_history.push(atr_val);
        self.tf_1h_buf.push(c);
        self.tf_1h_high.push(h);
        self.tf_1h_low.push(l);
        self.tf_4h_buf.push(c);
        self.tf_4h_high.push(h);
        self.tf_4h_low.push(l);
        self.ichimoku.update(h, l);
        self.close_buf_48.push(c);
        self.vwap_cum_vol += v;
        self.vwap_cum_pv += c * v;
        self.kama_er_buf.push(c);
        self.chop_buf.push(atr_val);
        let chop_sum = self.chop_buf.sum();
        self.chop_atr_sum = chop_sum;
        self.dfa_buf.push(c);
        self.var_ratio_buf.push(c);
        self.entropy_buf.push(c);
        self.aroon_high_buf.push(h);
        self.aroon_low_buf.push(l);
        self.fractal_buf.push(c);
        let rsi_val = self.rsi.value() / 100.0;
        self.rsi_peak_buf.push(rsi_val);
        self.price_peak_buf.push(c);
        self.count += 1;

        // ── Compute derived values ──
        let sma20_val = self.sma20.value();
        let sma50_val = self.sma50.value();
        let sma200_val = self.sma200.value();

        // Bollinger
        let bb_std = self.bb_stddev.value();
        let bb_upper_val = sma20_val + 2.0 * bb_std;
        let bb_lower_val = sma20_val - 2.0 * bb_std;
        let bb_width_val = if c == 0.0 { 0.0 } else { (bb_upper_val - bb_lower_val) / c };
        let bb_range = bb_upper_val - bb_lower_val;
        let bb_pos_val = if bb_range == 0.0 { 0.5 } else { (c - bb_lower_val) / bb_range };

        // MACD
        let macd_val = self.macd.fast_ema.value - self.macd.slow_ema.value;
        let macd_sig = self.macd.signal_ema.value;
        let macd_hist_val = macd_val - macd_sig;

        // DMI
        let tr_val = self.dmi.tr_smoother.value;
        let plus_di_val = if tr_val == 0.0 { 0.0 } else { 100.0 * self.dmi.plus_smoother.value / tr_val };
        let minus_di_val = if tr_val == 0.0 { 0.0 } else { 100.0 * self.dmi.minus_smoother.value / tr_val };
        let adx_val = self.dmi.adx_smoother.value;
        let atr_r_val = if c == 0.0 { 0.0 } else { atr_val / c };

        // Stochastic
        let stoch_k_val = if self.stoch.k_buf.len == 0 { 50.0 } else { self.stoch.k_buf.get(0) };
        let stoch_d_val = self.stoch.k_buf.sum() / self.stoch.k_buf.len.max(1) as f64;

        // Williams %R
        let high14_val = self.stoch.high_buf.max();
        let low14_val = self.stoch.low_buf.min();
        let williams_val = if high14_val == low14_val {
            -50.0
        } else {
            -100.0 * (high14_val - c) / (high14_val - low14_val)
        };

        // CCI, MFI
        let cci_val = self.cci.value();
        let mfi_val = self.mfi.value() / 100.0;

        // OBV
        let obv_slope = obv_slope_12(&self.obv);

        // Volume accel
        let vol_sma_val = self.volume_sma20.value();
        let vol_accel = if vol_sma_val == 0.0 { 1.0 } else { v / vol_sma_val };

        // Keltner
        let ema20_val = self.ema20.value;
        let kelt_upper_val = ema20_val + 1.5 * atr_val;
        let kelt_lower_val = ema20_val - 1.5 * atr_val;
        let kelt_width = kelt_upper_val - kelt_lower_val;
        let kelt_pos_val = if kelt_width == 0.0 { 0.5 } else { (c - kelt_lower_val) / kelt_width };
        let squeeze_val = if kelt_width == 0.0 { 1.0 } else { (bb_upper_val - bb_lower_val) / kelt_width };

        // ROC
        let roc_1_val = compute_roc(&self.roc_buf, 1, c);
        let roc_3_val = compute_roc(&self.roc_buf, 3, c);
        let roc_6_val = compute_roc(&self.roc_buf, 6, c);
        let roc_12_val = compute_roc(&self.roc_buf, 11, c);

        // ATR ROC
        let atr_roc_6_val = compute_roc(&self.atr_history, 6, atr_val);
        let atr_roc_12_val = compute_roc(&self.atr_history, 12, atr_val);

        // Trend consistency
        let tc_fn = |period: usize| -> f64 {
            let n = period.min(self.trend_buf_24.len);
            if n == 0 {
                return 0.5;
            }
            let mut s = 0.0;
            for i in 0..n {
                s += self.trend_buf_24.get(i);
            }
            s / n as f64
        };
        let tc_6 = tc_fn(6);
        let tc_12 = tc_fn(12);
        let tc_24 = tc_fn(24);

        // Range position
        let rp_fn = |h_buf: &RingBuffer, l_buf: &RingBuffer| -> f64 {
            let highest = h_buf.max();
            let lowest = l_buf.min();
            let rng = highest - lowest;
            if rng == 0.0 { 0.5 } else { (c - lowest) / rng }
        };
        let rp_12 = rp_fn(&self.range_high_12, &self.range_low_12);
        let rp_24 = rp_fn(&self.range_high_24, &self.range_low_24);
        let rp_48 = rp_fn(&self.range_high_48, &self.range_low_48);

        // Multi-timeframe helpers
        let tf_close = |buf: &RingBuffer| -> f64 {
            if buf.len == 0 { c } else { buf.get(0) }
        };
        let tf_ret = |buf: &RingBuffer| -> f64 {
            if buf.len < 2 { return 0.0; }
            let oldest = buf.get(buf.len - 1);
            if oldest == 0.0 { 0.0 } else { (buf.get(0) - oldest) / oldest }
        };
        let tf_body = |buf: &RingBuffer| -> f64 {
            if buf.len < 2 { return 0.0; }
            let open_v = buf.get(buf.len - 1);
            let close_v = buf.get(0);
            let range_v = buf.max() - buf.min();
            if range_v == 0.0 { 0.0 } else { (close_v - open_v).abs() / range_v }
        };

        let tf_1h_close_val = tf_close(&self.tf_1h_buf);
        let tf_1h_high_val = self.tf_1h_high.max();
        let tf_1h_low_val = self.tf_1h_low.min();
        let tf_1h_ret_val = tf_ret(&self.tf_1h_buf);
        let tf_1h_body_val = tf_body(&self.tf_1h_buf);
        let tf_4h_close_val = tf_close(&self.tf_4h_buf);
        let tf_4h_high_val = self.tf_4h_high.max();
        let tf_4h_low_val = self.tf_4h_low.min();
        let tf_4h_ret_val = tf_ret(&self.tf_4h_buf);
        let tf_4h_body_val = tf_body(&self.tf_4h_buf);

        // Ichimoku
        let tenkan = (self.ichimoku.high_9.max() + self.ichimoku.low_9.min()) / 2.0;
        let kijun = (self.ichimoku.high_26.max() + self.ichimoku.low_26.min()) / 2.0;
        let span_a = (tenkan + kijun) / 2.0;
        let span_b = (self.ichimoku.high_52.max() + self.ichimoku.low_52.min()) / 2.0;
        let cloud_top_val = span_a.max(span_b);
        let cloud_bottom_val = span_a.min(span_b);

        // Persistence
        let hurst_val = hurst_exponent(&self.close_buf_48);
        let autocorr_val = autocorrelation_lag1(&self.close_buf_48);
        let vwap_val = if self.vwap_cum_vol == 0.0 {
            0.0
        } else {
            let vwap_price = self.vwap_cum_pv / self.vwap_cum_vol;
            if c == 0.0 { 0.0 } else { (c - vwap_price) / c }
        };

        // Regime
        let kama_er_val = kama_efficiency_ratio(&self.kama_er_buf);
        let chop_val = choppiness_index(chop_sum, &self.range_high_12, &self.range_low_12);
        let dfa_val = dfa_alpha(&self.dfa_buf);
        let var_ratio_val = variance_ratio(&self.var_ratio_buf);
        let entropy_val = entropy_rate(&self.entropy_buf);
        let aroon_up_val = aroon_up(&self.aroon_high_buf);
        let aroon_down_val = aroon_down(&self.aroon_low_buf);
        let fractal_val = fractal_dimension(&self.fractal_buf);

        // Divergence
        let (div_bull, div_bear) = detect_divergence(&self.price_peak_buf, &self.rsi_peak_buf);

        // Cross deltas
        let tk_spread = tenkan - kijun;
        let tk_delta = tk_spread - self.prev_tk_spread;
        let stoch_kd = stoch_k_val - stoch_d_val;
        let stoch_delta = stoch_kd - self.prev_stoch_kd;

        // Price action
        let current_range = h - l;
        let range_ratio_val = if self.prev_range == 0.0 { 1.0 } else { current_range / self.prev_range };
        let gap_val = if self.prev_close == 0.0 { 0.0 } else { (o - self.prev_close) / self.prev_close };
        let new_cons_up = if c > self.prev_close { self.consecutive_up_count + 1 } else { 0 };
        let new_cons_down = if c < self.prev_close { self.consecutive_down_count + 1 } else { 0 };

        // Timeframe agreement
        let signum = |x: f64| -> f64 { if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 } };
        let five_min_dir = signum(roc_1_val);
        let one_h_dir = signum(tf_1h_ret_val);
        let four_h_dir = signum(tf_4h_ret_val);
        let agreement = (if five_min_dir == one_h_dir { 1.0 } else { 0.0 }
            + if five_min_dir == four_h_dir { 1.0 } else { 0.0 }
            + if one_h_dir == four_h_dir { 1.0 } else { 0.0 })
            / 3.0;

        // Time
        let minute_val = parse_minute(ts);
        let hour_val = parse_hour(ts);
        let dow_val = parse_day_of_week(ts);
        let dom_val = parse_day_of_month(ts);
        let moy_val = parse_month_of_year(ts);

        // Update trailing state
        self.prev_tk_spread = tk_spread;
        self.prev_stoch_kd = stoch_kd;
        self.prev_range = current_range;
        self.consecutive_up_count = new_cons_up;
        self.consecutive_down_count = new_cons_down;
        self.prev_tf_1h_ret = tf_1h_ret_val;
        self.prev_tf_4h_ret = tf_4h_ret_val;
        self.prev_close = c;

        // Build enriched Candle
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
            bb_upper: bb_upper_val,
            bb_lower: bb_lower_val,
            bb_width: bb_width_val,
            bb_pos: bb_pos_val,
            rsi: rsi_val,
            macd: macd_val,
            macd_signal: macd_sig,
            macd_hist: macd_hist_val,
            plus_di: plus_di_val,
            minus_di: minus_di_val,
            adx: adx_val,
            atr: atr_val,
            atr_r: atr_r_val,
            stoch_k: stoch_k_val / 100.0,
            stoch_d: stoch_d_val / 100.0,
            williams_r: williams_val / -100.0,
            cci: cci_val,
            mfi: mfi_val,
            obv_slope_12: obv_slope,
            volume_accel: vol_accel,
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
            range_pos_12: rp_12,
            range_pos_24: rp_24,
            range_pos_48: rp_48,
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
            tenkan_sen: tenkan,
            kijun_sen: kijun,
            senkou_span_a: span_a,
            senkou_span_b: span_b,
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
            consecutive_up: new_cons_up as f64,
            consecutive_down: new_cons_down as f64,
            tf_agreement: agreement,
            minute: minute_val,
            hour: hour_val,
            day_of_week: dow_val,
            day_of_month: dom_val,
            month_of_year: moy_val,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raw_candle::Asset;

    fn make_raw_candle(ts: &str, open: f64, high: f64, low: f64, close: f64, volume: f64) -> RawCandle {
        RawCandle::new(
            Asset::new("BTC"),
            Asset::new("USD"),
            ts,
            open, high, low, close, volume,
        )
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
        assert_eq!(rb.get(2), 2.0); // 1.0 is gone
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

    // ── RSI tests ──

    #[test]
    fn test_rsi_boundaries() {
        let mut rsi = RsiState::new();
        // Feed purely ascending prices
        for i in 0..30 {
            rsi.update(100.0 + i as f64);
        }
        let val = rsi.value();
        assert!(val > 50.0 && val <= 100.0, "RSI for ascending should be >50, got {}", val);

        // Feed purely descending prices
        let mut rsi2 = RsiState::new();
        for i in 0..30 {
            rsi2.update(200.0 - i as f64);
        }
        let val2 = rsi2.value();
        assert!(val2 < 50.0 && val2 >= 0.0, "RSI for descending should be <50, got {}", val2);
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

    // ── Linreg slope ──

    #[test]
    fn test_linreg_slope_ascending() {
        let mut rb = RingBuffer::new(5);
        for i in 0..5 {
            rb.push(i as f64 * 10.0);
        }
        let slope = linreg_slope(&rb);
        assert!((slope - 10.0).abs() < 1e-6, "Slope of 0,10,20,30,40 should be 10, got {}", slope);
    }

    // ── Tick test ──

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
        assert!(candle.macd.is_finite());
        assert!(candle.atr.is_finite());
        assert!(candle.adx.is_finite());
        assert!(candle.bb_width.is_finite());
        assert!(candle.cci.is_finite());
        assert!(candle.mfi.is_finite());
        assert!(candle.hurst.is_finite());
        assert!(candle.kama_er.is_finite());
        assert!(candle.choppiness.is_finite());
        assert!(candle.fractal_dim.is_finite());
        assert!(candle.entropy_rate.is_finite());
        assert!(candle.variance_ratio.is_finite());
        assert!(candle.stoch_k.is_finite());
        assert!(candle.stoch_d.is_finite());
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
    fn test_indicator_bank_new() {
        let bank = IndicatorBank::new();
        assert_eq!(bank.count, 0);
        assert_eq!(bank.prev_close, 0.0);
        assert_eq!(bank.sma20.buffer.capacity, 20);
        assert_eq!(bank.sma50.buffer.capacity, 50);
        assert_eq!(bank.sma200.buffer.capacity, 200);
    }
}
