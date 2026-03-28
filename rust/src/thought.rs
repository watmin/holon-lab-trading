use std::collections::{HashMap, HashSet};

use holon::{
    Accumulator, Primitives, ScalarEncoder, ScalarMode,
    Vector, VectorManager,
};

use crate::db::Candle;

// ─── PELT change-point detection ────────────────────────────────────────────

/// PELT change-point detection on raw scalar values.
/// Returns changepoint indices (boundaries between segments).
fn pelt_changepoints(values: &[f64], penalty: f64) -> Vec<usize> {
    let n = values.len();
    if n < 3 { return vec![]; }

    let mut cum_sum = vec![0.0; n + 1];
    let mut cum_sq = vec![0.0; n + 1];
    for i in 0..n {
        cum_sum[i + 1] = cum_sum[i] + values[i];
        cum_sq[i + 1] = cum_sq[i] + values[i] * values[i];
    }

    let seg_cost = |s: usize, t: usize| -> f64 {
        let len = (t - s) as f64;
        if len < 1.0 { return 0.0; }
        let sm = cum_sum[t] - cum_sum[s];
        let sq = cum_sq[t] - cum_sq[s];
        sq - sm * sm / len
    };

    let mut best_cost = vec![0.0_f64; n + 1];
    let mut last_change = vec![0usize; n + 1];
    let mut candidates: Vec<usize> = vec![0];

    for t in 1..=n {
        let mut best = f64::MAX;
        let mut best_s = 0;
        for &s in &candidates {
            let cost = best_cost[s] + seg_cost(s, t) + penalty;
            if cost < best {
                best = cost;
                best_s = s;
            }
        }
        best_cost[t] = best;
        last_change[t] = best_s;

        candidates.retain(|&s| best_cost[s] + seg_cost(s, t) <= best_cost[t] + penalty);
        candidates.push(t);
    }

    let mut cps = vec![];
    let mut t = n;
    while t > 0 {
        let s = last_change[t];
        if s > 0 { cps.push(s); }
        t = s;
    }
    cps.reverse();
    cps
}

/// BIC-derived penalty: 2 * variance * log(n)
fn bic_penalty(values: &[f64]) -> f64 {
    let n = values.len() as f64;
    if n < 2.0 { return 1e10; }
    let mean = values.iter().sum::<f64>() / n;
    let var = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n;
    if var < 1e-20 { return 1e10; }
    2.0 * var * n.ln()
}

/// Direction of the most recent PELT segment: "up", "down", or None if degenerate.
fn most_recent_segment_dir(values: &[f64]) -> Option<&'static str> {
    if values.len() < 5 { return None; }
    let penalty = bic_penalty(values);
    let cps = pelt_changepoints(values, penalty);
    let start = cps.last().copied().unwrap_or(0);
    let end = values.len();
    if end <= start { return None; }
    let change = values[end - 1] - values[start];
    if change.abs() < 1e-10 { None }
    else if change > 0.0 { Some("up") }
    else { Some("down") }
}

/// Local swing highs: indices where value is strictly greater than all values
/// within `radius` bars on each side. Returns (index, value) pairs, oldest first.
fn swing_highs(values: &[f64], radius: usize) -> Vec<(usize, f64)> {
    let n = values.len();
    let mut out = Vec::new();
    if n < radius * 2 + 1 { return out; }
    for i in radius..n - radius {
        let v = values[i];
        if values[i - radius..i].iter().all(|&x| x < v)
            && values[i + 1..=i + radius].iter().all(|&x| x < v)
        {
            out.push((i, v));
        }
    }
    out
}

/// Local swing lows: indices where value is strictly less than all values
/// within `radius` bars on each side. Returns (index, value) pairs, oldest first.
fn swing_lows(values: &[f64], radius: usize) -> Vec<(usize, f64)> {
    let n = values.len();
    let mut out = Vec::new();
    if n < radius * 2 + 1 { return out; }
    for i in radius..n - radius {
        let v = values[i];
        if values[i - radius..i].iter().all(|&x| x > v)
            && values[i + 1..=i + radius].iter().all(|&x| x > v)
        {
            out.push((i, v));
        }
    }
    out
}

fn cosine_f64(a: &[f64], b: &[f64]) -> f64 {
    assert_eq!(a.len(), b.len());
    let mut dot = 0.0_f64;
    let mut na = 0.0_f64;
    let mut nb = 0.0_f64;
    for (&x, &y) in a.iter().zip(b.iter()) {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    let denom = (na * nb).sqrt();
    if denom < 1e-10 { 0.0 } else { dot / denom }
}

fn cosine_f64_vs_vec(proto: &[f64], vec: &Vector) -> f64 {
    let data = vec.data();
    assert_eq!(proto.len(), data.len());
    let mut dot = 0.0_f64;
    let mut norm_p = 0.0_f64;
    let mut norm_v = 0.0_f64;
    for (&p, &v) in proto.iter().zip(data.iter()) {
        let vf = v as f64;
        dot += p * vf;
        norm_p += p * p;
        norm_v += vf * vf;
    }
    let denom = (norm_p * norm_v).sqrt();
    if denom < 1e-10 { 0.0 } else { dot / denom }
}

/// Float-space invert: cosine of continuous f64 proto against bipolar codebook atoms.
/// Threshold is 1/sqrt(D) — the expected absolute cosine of a random bipolar vector
/// against any fixed vector in D dimensions. Atoms above this are statistically present.
fn invert_f64(proto: &[f64], codebook: &[Vector], top_k: usize) -> Vec<(usize, f64)> {
    let norm_p: f64 = proto.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm_p < 1e-10 { return vec![]; }
    let threshold = 1.0 / (proto.len() as f64).sqrt();

    let mut results: Vec<(usize, f64)> = codebook.iter().enumerate()
        .map(|(i, atom)| {
            let dot: f64 = proto.iter().zip(atom.data().iter())
                .map(|(&p, &a)| p * (a as f64)).sum();
            let norm_a = (atom.dimensions() as f64).sqrt();
            (i, dot / (norm_p * norm_a))
        })
        .filter(|(_, sim)| *sim > threshold)
        .collect();
    results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    results.truncate(top_k);
    results
}

/// Cosine between two bipolar vectors using integer dot product.
#[inline]
fn bipolar_cosine(a: &[i8], b: &[i8]) -> f64 {
    let mut dot = 0i64;
    let mut nnz_a = 0i64;
    let mut nnz_b = 0i64;
    for (&x, &y) in a.iter().zip(b.iter()) {
        dot += (x as i64) * (y as i64);
        nnz_a += (x != 0) as i64;
        nnz_b += (y != 0) as i64;
    }
    let denom = ((nnz_a * nnz_b) as f64).sqrt();
    if denom < 1.0 { 0.0 } else { dot as f64 / denom }
}

/// Coverage-based prediction: what fraction of discriminative atom weights are present in the input.
/// Returns (coverage 0.0-1.0, atoms_found, atoms_total).
fn disc_coverage(input: &Vector, atoms: &[DiscAtom], noise_floor: f64) -> (f64, usize, usize) {
    if atoms.is_empty() { return (0.0, 0, 0); }
    let total_weight: f64 = atoms.iter().map(|a| a.weight).sum();
    if total_weight < 1e-10 { return (0.0, 0, atoms.len()); }
    let input_data = input.data();
    let mut found_weight = 0.0_f64;
    let mut found_count = 0usize;
    for a in atoms {
        if bipolar_cosine(input_data, a.atom_vec.data()) > noise_floor {
            found_weight += a.weight;
            found_count += 1;
        }
    }
    (found_weight / total_weight, found_count, atoms.len())
}

// ─── Atoms ──────────────────────────────────────────────────────────────────

const INDICATOR_ATOMS: &[&str] = &[
    "close", "open", "high", "low", "volume",
    "sma20", "sma50", "sma200",
    "bb-upper", "bb-lower", "bb-width",
    "rsi", "rsi-sma",
    "macd-line", "macd-signal", "macd-hist",
    "dmi-plus", "dmi-minus", "adx", "atr",
    // Derived indicators (computed from OHLCV, not DB columns)
    "prev-close", "prev-open", "prev-high", "prev-low",
    "candle-range", "candle-body", "upper-wick", "lower-wick",
    // Segment narrative streams
    "body", "range",
    // Range context
    "range-pos",
    // Ichimoku
    "tenkan-sen", "kijun-sen", "senkou-span-a", "senkou-span-b",
    "chikou-span", "cloud-top", "cloud-bottom",
    // Stochastic
    "stoch-k", "stoch-d",
    // Fibonacci
    "fib-236", "fib-382", "fib-500", "fib-618", "fib-786",
    // Volume analysis
    "obv", "volume-sma",
    // Keltner
    "keltner-upper", "keltner-lower",
    // Momentum
    "roc", "cci",
    // Price action
    "consecutive-up", "consecutive-down",
    // Tier-1 underdogs
    "kama", "kama-er",            // Kaufman adaptive MA + efficiency ratio
    "chop",                       // Choppiness Index
    "dfa-alpha",                  // Detrended Fluctuation Analysis
    "variance-ratio",             // Lo-MacKinlay variance ratio
    "td-count",                   // DeMark TD Sequential count
    "aroon-up", "aroon-down",     // Aroon trend freshness
    // Tier-1 esoteric
    "fractal-dim",                // Fractal dimension (Higuchi)
    "spectral-slope",             // Power spectrum slope
    "entropy-rate",               // Sequential entropy (linguistics)
    "gr-bvalue",                  // Gutenberg-Richter b-value (seismology)
];

const DIRECTION_ATOMS: &[&str] = &["up", "down", "flat"];
const ZONE_ATOMS: &[&str] = &[
    "overbought", "oversold", "neutral",
    "strong-trend", "weak-trend", "squeeze", "middle-zone",
    "above-midline", "below-midline", "positive", "negative",
    // Ichimoku zones
    "above-cloud", "below-cloud", "in-cloud",
    // Stochastic zones
    "stoch-overbought", "stoch-oversold",
    // Volume zones
    "volume-spike", "volume-drought",
    // CCI zones
    "cci-overbought", "cci-oversold",
    // Price action
    "inside-bar", "outside-bar", "gap-up", "gap-down",
    // Regime zones
    "efficient-trend", "inefficient-chop", "moderate-efficiency",
    "chop-trending", "chop-choppy", "chop-extreme", "chop-transition",
    "persistent-dfa", "anti-persistent-dfa", "random-walk-dfa",
    "vr-momentum", "vr-mean-revert", "vr-neutral",
    "td-exhausted", "td-building", "td-mature", "td-inactive",
    "aroon-strong-up", "aroon-strong-down", "aroon-consolidating", "aroon-stale",
    "trending-geometry", "random-walk-geometry", "mean-reverting-geometry",
    "heavy-tails", "light-tails",
    "low-entropy-rate", "high-entropy-rate",
    // Risk / portfolio state
    "drawdown", "drawdown-shallow", "drawdown-moderate", "drawdown-deep", "drawdown-at-peak",
    "streak", "streak-winning", "streak-losing", "streak-long", "streak-short",
    "recent-accuracy", "accuracy-hot", "accuracy-cold", "accuracy-normal",
    "equity-curve", "equity-rising", "equity-falling", "equity-flat",
    "trade-frequency", "overtrading", "undertrading",
];
const PREDICATE_ATOMS: &[&str] = &[
    "above", "below", "crosses-above", "crosses-below",
    "touches", "bounces-off",
    "at", "since",
    "diverging", "confirming", "contradicting",
];
const SEGMENT_ATOMS: &[&str] = &["beginning", "ending"];
const CALENDAR_ATOMS: &[&str] = &[
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "h00", "h04", "h08", "h12", "h16", "h20",
    "asian-session", "european-session", "us-session", "off-hours",
    "at-day", "at-session", "at-hour",
];

const ALL_ATOM_GROUPS: &[&[&str]] = &[
    INDICATOR_ATOMS,
    DIRECTION_ATOMS,
    ZONE_ATOMS,
    PREDICATE_ATOMS,
    SEGMENT_ATOMS,
    CALENDAR_ATOMS,
];

/// Raw value extractors for PELT segmentation — 17 streams
const SEGMENT_STREAMS: &[(&str, fn(&Candle) -> f64)] = &[
    ("close",       |c| c.close.ln()),
    ("sma20",       |c| if c.sma20 > 0.0 { c.sma20.ln() } else { 0.0 }),
    ("sma50",       |c| if c.sma50 > 0.0 { c.sma50.ln() } else { 0.0 }),
    ("sma200",      |c| if c.sma200 > 0.0 { c.sma200.ln() } else { 0.0 }),
    ("bb-upper",    |c| if c.bb_upper > 0.0 { c.bb_upper.ln() } else { 0.0 }),
    ("bb-lower",    |c| if c.bb_lower > 0.0 { c.bb_lower.ln() } else { 0.0 }),
    ("volume",      |c| if c.volume > 0.0 { c.volume.ln() } else { 0.0 }),
    ("rsi",         |c| c.rsi),
    ("rsi-sma",     |_c| 0.0),  // handled separately via rolling computation
    ("macd-line",   |c| c.macd_line),
    ("macd-signal", |c| c.macd_signal),
    ("macd-hist",   |c| c.macd_hist),
    ("dmi-plus",    |c| c.dmi_plus),
    ("dmi-minus",   |c| c.dmi_minus),
    ("adx",         |c| c.adx),
    ("body",        |c| c.close - c.open),
    ("range",       |c| c.high - c.low),
    ("upper-wick",  |c| c.high - c.close.max(c.open)),
    ("lower-wick",  |c| c.close.min(c.open) - c.low),
];

/// Zone checks scoped to their relevant streams.
/// Each entry: (stream_name, zone_label, check_fn).
const STREAM_ZONE_CHECKS: &[(&str, &str, &str, fn(&Candle) -> bool)] = &[
    ("rsi", "rsi", "overbought",    |c| c.rsi > 70.0),
    ("rsi", "rsi", "oversold",      |c| c.rsi < 30.0),
    ("rsi", "rsi", "above-midline", |c| c.rsi > 50.0),
    ("rsi", "rsi", "below-midline", |c| c.rsi <= 50.0),
    ("adx", "adx", "strong-trend",  |c| c.adx > 25.0),
    ("adx", "adx", "weak-trend",    |c| c.adx < 20.0),
    ("dmi-plus",  "dmi-plus",  "strong-trend", |c| c.dmi_plus > 25.0),
    ("dmi-plus",  "dmi-plus",  "weak-trend",   |c| c.dmi_plus < 20.0),
    ("dmi-minus", "dmi-minus", "strong-trend",  |c| c.dmi_minus > 25.0),
    ("dmi-minus", "dmi-minus", "weak-trend",    |c| c.dmi_minus < 20.0),
    ("macd-line", "macd-line", "positive",      |c| c.macd_line > 0.0),
    ("macd-line", "macd-line", "negative",      |c| c.macd_line <= 0.0),
    ("macd-hist", "macd-hist", "positive",      |c| c.macd_hist > 0.0),
    ("macd-hist", "macd-hist", "negative",      |c| c.macd_hist <= 0.0),
];

// ─── ThoughtVocab ───────────────────────────────────────────────────────────

pub struct ThoughtVocab {
    atoms: HashMap<String, Vector>,
    dims: usize,
}

impl ThoughtVocab {
    pub fn new(vm: &VectorManager) -> Self {
        let mut atoms = HashMap::new();
        for group in ALL_ATOM_GROUPS {
            for &name in *group {
                atoms.insert(name.to_string(), vm.get_vector(name));
            }
        }
        Self { atoms, dims: vm.dimensions() }
    }

    pub fn get(&self, name: &str) -> &Vector {
        self.atoms.get(name).unwrap_or_else(|| panic!("unknown atom: {}", name))
    }

    pub fn dims(&self) -> usize {
        self.dims
    }
}

// ─── IndicatorStreams ────────────────────────────────────────────────────────

/// Legacy stream infrastructure — retained for API compatibility with trader.rs.
/// Segment narrative now operates on raw candle values via PELT, not encoded vector streams.
pub struct IndicatorStreams {
    count: usize,
    max_len: usize,
}

impl IndicatorStreams {
    pub fn new(_dims: usize, max_len: usize) -> Self {
        Self { count: 0, max_len }
    }

    pub fn push_candle(&mut self, _candle: &Candle) {
        self.count += 1;
        if self.count > self.max_len {
            self.count = self.max_len;
        }
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn max_len_val(&self) -> usize {
        self.max_len
    }

    pub fn set_max_len(&mut self, new_max: usize) {
        self.max_len = new_max;
    }

    pub fn trim_to_max(&mut self) {
        if self.count > self.max_len {
            self.count = self.max_len;
        }
    }
}

// ─── Fact composition helpers ───────────────────────────────────────────────

/// Binary predicate: (pred a b) → bind(V("pred"), bind(V("a"), V("b")))
fn fact_binary(vocab: &ThoughtVocab, pred: &str, a: &str, b: &str) -> Vector {
    let ab = Primitives::bind(vocab.get(a), vocab.get(b));
    Primitives::bind(vocab.get(pred), &ab)
}

/// Temporal binding: (since fact N) → bind(fact_vec, position_vector(N))
fn fact_since(vm: &VectorManager, fact: &Vector, n: usize) -> Vector {
    let pos = vm.get_position_vector(n as i64);
    Primitives::bind(fact, &pos)
}

// ─── Candle field accessor ──────────────────────────────────────────────────

fn candle_field(candle: &Candle, name: &str) -> f64 {
    match name {
        "close" => candle.close,
        "open" => candle.open,
        "high" => candle.high,
        "low" => candle.low,
        "volume" => candle.volume,
        "sma20" => candle.sma20,
        "sma50" => candle.sma50,
        "sma200" => candle.sma200,
        "bb-upper" => candle.bb_upper,
        "bb-lower" => candle.bb_lower,
        "bb-width" => candle.bb_upper - candle.bb_lower,
        "rsi" => candle.rsi,
        "macd-line" => candle.macd_line,
        "macd-signal" => candle.macd_signal,
        "macd-hist" => candle.macd_hist,
        "dmi-plus" => candle.dmi_plus,
        "dmi-minus" => candle.dmi_minus,
        "adx" => candle.adx,
        "atr" => candle.atr_r,
        "candle-range" => candle.high - candle.low,
        "candle-body" => (candle.close - candle.open).abs(),
        "upper-wick" => candle.high - candle.close.max(candle.open),
        "lower-wick" => candle.close.min(candle.open) - candle.low,
        _ => 0.0,
    }
}

/// Resolve a field value, handling prev-* lookups and derived fields.
/// Returns None when the value is unavailable (missing prev candle, or
/// indicator not yet computed — standard fields that are 0.0).
fn field_value(now: &Candle, prev: Option<&Candle>, name: &str) -> Option<f64> {
    if let Some(base) = name.strip_prefix("prev-") {
        prev.map(|p| candle_field(p, base))
    } else {
        let v = candle_field(now, name);
        if is_derived_field(name) {
            Some(v)
        } else if v == 0.0 {
            None
        } else {
            Some(v)
        }
    }
}

fn is_derived_field(name: &str) -> bool {
    matches!(name, "candle-range" | "candle-body" | "upper-wick" | "lower-wick")
}

// ─── ThoughtEncoder ─────────────────────────────────────────────────────────

pub struct ThoughtResult {
    pub thought: Vector,
    pub coherence: f64,
    pub fact_labels: Vec<String>,
    pub fact_count: usize,
}

/// Indicator pairs to check for comparison predicates (above/below/crosses/touches/bounces).
const COMPARISON_PAIRS: &[(&str, &str)] = &[
    // Original 9 pairs
    ("close", "sma20"), ("close", "sma50"), ("close", "sma200"),
    ("close", "bb-upper"), ("close", "bb-lower"),
    ("sma20", "sma50"), ("sma50", "sma200"),
    ("macd-line", "macd-signal"),
    ("dmi-plus", "dmi-minus"),
    // Cross-candle (5)
    ("high", "prev-high"), ("low", "prev-low"),
    ("open", "prev-close"), ("close", "prev-close"), ("close", "prev-open"),
    // OHLC vs structure (7)
    ("open", "sma20"), ("open", "sma50"), ("open", "sma200"),
    ("open", "bb-upper"), ("open", "bb-lower"),
    ("high", "bb-upper"), ("low", "bb-lower"),
    // Intra-candle structure (5)
    ("close", "open"),
    ("upper-wick", "candle-body"), ("lower-wick", "candle-body"),
    ("upper-wick", "lower-wick"),
    ("candle-range", "atr"),
    // Additional structure (3)
    ("candle-body", "candle-range"),
    ("high", "sma200"), ("low", "sma200"),
    // Ichimoku (7)
    ("close", "tenkan-sen"), ("close", "kijun-sen"),
    ("close", "cloud-top"), ("close", "cloud-bottom"),
    ("tenkan-sen", "kijun-sen"),
    ("close", "senkou-span-a"), ("close", "senkou-span-b"),
    // Stochastic (1)
    ("stoch-k", "stoch-d"),
    // Keltner (3)
    ("close", "keltner-upper"), ("close", "keltner-lower"),
    ("bb-upper", "keltner-upper"),  // squeeze detection
];

pub struct ThoughtEncoder {
    vocab: ThoughtVocab,
    scalar_enc: ScalarEncoder,
    fact_cache: HashMap<String, Vector>,
}

impl ThoughtEncoder {
    pub fn new(vocab: ThoughtVocab) -> Self {
        let dims = vocab.dims();
        let mut fact_cache = HashMap::new();

        // Pre-compute comparison facts
        for &(a, b) in COMPARISON_PAIRS {
            for &pred in &["above", "below", "crosses-above", "crosses-below", "touches", "bounces-off"] {
                let key = format!("({} {} {})", pred, a, b);
                let vec = fact_binary(&vocab, pred, a, b);
                fact_cache.insert(key, vec);
            }
        }

        // Pre-compute zone facts for segment boundaries
        for &(_stream, ind, zone, _check) in STREAM_ZONE_CHECKS {
            let key = format!("(at {} {})", ind, zone);
            if !fact_cache.contains_key(&key) {
                fact_cache.insert(key, fact_binary(&vocab, "at", ind, zone));
            }
        }

        // Pre-compute RSI SMA facts
        for &pred in &["above", "below", "crosses-above", "crosses-below"] {
            let key = format!("({} rsi rsi-sma)", pred);
            fact_cache.insert(key, fact_binary(&vocab, pred, "rsi", "rsi-sma"));
        }

        // Pre-compute calendar facts
        for &day in &["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] {
            let key = format!("(at-day {})", day);
            fact_cache.insert(key, fact_binary(&vocab, "at-day", day, day));
        }
        for &hour in &["h00", "h04", "h08", "h12", "h16", "h20"] {
            let key = format!("(at-hour {})", hour);
            fact_cache.insert(key, fact_binary(&vocab, "at-hour", hour, hour));
        }
        for &session in &["asian-session", "european-session", "us-session", "off-hours"] {
            let key = format!("(at-session {})", session);
            fact_cache.insert(key, fact_binary(&vocab, "at-session", session, session));
        }

        // Pre-compute new zone facts
        for &(ind, zone) in &[
            ("close", "above-cloud"), ("close", "below-cloud"), ("close", "in-cloud"),
            ("stoch-k", "stoch-overbought"), ("stoch-k", "stoch-oversold"),
            ("volume", "volume-spike"), ("volume", "volume-drought"),
            ("cci", "cci-overbought"), ("cci", "cci-oversold"),
            ("close", "inside-bar"), ("close", "outside-bar"),
            ("close", "gap-up"), ("close", "gap-down"),
            ("close", "consecutive-up"), ("close", "consecutive-down"),
            // Regime zones
            ("kama-er", "efficient-trend"), ("kama-er", "inefficient-chop"),
            ("chop", "chop-trending"), ("chop", "chop-choppy"), ("chop", "chop-extreme"), ("chop", "chop-transition"),
            ("dfa-alpha", "persistent-dfa"), ("dfa-alpha", "anti-persistent-dfa"), ("dfa-alpha", "random-walk-dfa"),
            ("variance-ratio", "vr-momentum"), ("variance-ratio", "vr-mean-revert"), ("variance-ratio", "vr-neutral"),
            ("td-count", "td-exhausted"), ("td-count", "td-mature"), ("td-count", "td-building"), ("td-count", "td-inactive"),
            ("aroon-up", "aroon-strong-up"), ("aroon-up", "aroon-strong-down"), ("aroon-up", "aroon-consolidating"), ("aroon-up", "aroon-stale"),
            ("fractal-dim", "trending-geometry"), ("fractal-dim", "random-walk-geometry"), ("fractal-dim", "mean-reverting-geometry"),
            ("gr-bvalue", "heavy-tails"), ("gr-bvalue", "light-tails"),
            ("entropy-rate", "low-entropy-rate"), ("entropy-rate", "high-entropy-rate"),
        ] {
            let key = format!("(at {} {})", ind, zone);
            if !fact_cache.contains_key(&key) {
                fact_cache.insert(key, fact_binary(&vocab, "at", ind, zone));
            }
        }

        Self { vocab, scalar_enc: ScalarEncoder::new(dims), fact_cache }
    }

    pub fn vocab(&self) -> &ThoughtVocab {
        &self.vocab
    }

    /// Return the pre-computed fact codebook: (label, vector) pairs for all
    /// cached comparison, zone, calendar, and RSI-SMA facts. Use for
    /// discriminant decoding.
    pub fn fact_codebook(&self) -> (Vec<String>, Vec<Vector>) {
        let mut labels = Vec::with_capacity(self.fact_cache.len());
        let mut vecs   = Vec::with_capacity(self.fact_cache.len());
        for (label, vec) in &self.fact_cache {
            labels.push(label.clone());
            vecs.push(vec.clone());
        }
        (labels, vecs)
    }

    pub fn encode(
        &self,
        candles: &[Candle],
        streams: &IndicatorStreams,
        vm: &VectorManager,
    ) -> ThoughtResult {
        self.encode_view(candles, streams, usize::MAX, streams.max_len_val(), vm, None, None, "full")
    }

    /// Weighted bundle: each fact scaled by |cosine(fact, discriminant)|.
    /// Facts the discriminant ignores get near-zero weight. Facts it relies
    /// on get amplified. Result is thresholded to bipolar.
    fn weighted_bundle(facts: &[&Vector], disc: &[f64], dims: usize) -> Vector {
        let disc_norm: f64 = disc.iter().map(|x| x * x).sum::<f64>().sqrt();
        if disc_norm < 1e-10 { return Primitives::bundle(facts); }

        let inv_disc_norm = 1.0 / disc_norm;
        let mut sum = vec![0.0f64; dims];
        for fact in facts {
            // |cosine(fact, disc)| — bipolar fact means norm = sqrt(D)
            let dot: f64 = fact.data().iter().zip(disc.iter())
                .map(|(&v, &d)| v as f64 * d)
                .sum();
            let norm_v = (fact.dimensions() as f64).sqrt();
            let w = (dot * inv_disc_norm / norm_v).abs();
            for (s, &v) in sum.iter_mut().zip(fact.data().iter()) {
                *s += w * v as f64;
            }
        }
        Vector::from_data(sum.iter()
            .map(|&v| if v > 0.0 { 1 } else if v < 0.0 { -1 } else { 0 })
            .collect())
    }

    /// Expert profiles: which eval methods to run.
    /// "full" = all methods (generalist). Named profiles select subsets.
    pub const EXPERT_PROFILES: &'static [&'static str] = &[
        "full",       // all thoughts — the generalist
        "momentum",   // RSI, Stochastic, MACD, divergence, CCI
        "structure",  // Ichimoku, SMA, Fibonacci, BB/Keltner, range position
        "volume",     // volume analysis, volume confirmation, price action
        "narrative",  // PELT segments, temporal lookback, calendar
        "regime",     // Choppiness, DFA, Hurst, Variance Ratio, Fractal Dim, Entropy, GR b-value
    ];

    /// Encode with a windowed view of the streams.
    /// `expert` selects which thought vocabulary to activate:
    ///   "full" = all, "momentum"/"structure"/"volume"/"narrative" = subsets.
    pub fn encode_view(
        &self,
        candles: &[Candle],
        _streams: &IndicatorStreams,
        _stream_end: usize,
        _max_window: usize,
        vm: &VectorManager,
        attention: Option<&[f64]>,
        suppressed: Option<&HashSet<String>>,
        expert: &str,
    ) -> ThoughtResult {
        let mut cached_facts: Vec<&Vector> = Vec::with_capacity(64);
        let mut owned_facts: Vec<Vector> = Vec::with_capacity(96);
        let mut labels: Vec<String> = Vec::with_capacity(96);

        let now = candles.last().unwrap();
        let prev = if candles.len() >= 2 { Some(&candles[candles.len() - 2]) } else { None };

        let is = |profiles: &[&str]| -> bool {
            expert == "full" || profiles.contains(&expert)
        };

        // Comparisons: shared across most experts (core TA relationships)
        if is(&["momentum", "structure"]) {
            self.eval_comparisons_cached(now, prev, &mut cached_facts, &mut labels);
        }
        // PELT segment narrative
        if is(&["narrative", "structure"]) {
            self.eval_segment_narrative(candles, vm, &mut owned_facts, &mut labels);
        }
        // Temporal lookback (crosses)
        if is(&["narrative", "momentum"]) {
            self.eval_temporal(candles, vm, &mut owned_facts, &mut labels);
        }
        // RSI-SMA
        if is(&["momentum"]) {
            self.eval_rsi_sma_cached(candles, &mut cached_facts, &mut labels);
        }
        // Calendar
        if is(&["narrative"]) {
            self.eval_calendar(now, &mut cached_facts, &mut labels);
        }
        // RSI divergence
        if is(&["momentum"]) {
            self.eval_divergence(candles, vm, &mut owned_facts, &mut labels);
        }
        // Volume confirmation
        if is(&["volume"]) {
            self.eval_volume_confirmation(candles, &mut owned_facts, &mut labels);
        }
        // Range position
        if is(&["structure"]) {
            self.eval_range_position(candles, &mut owned_facts, &mut labels);
        }
        // Ichimoku
        if is(&["structure"]) {
            self.eval_ichimoku(candles, &mut cached_facts, &mut labels);
        }
        // Stochastic
        if is(&["momentum"]) {
            self.eval_stochastic(candles, &mut cached_facts, &mut labels);
        }
        // Fibonacci
        if is(&["structure"]) {
            self.eval_fibonacci(candles, &mut owned_facts, &mut labels);
        }
        // Volume analysis
        if is(&["volume"]) {
            self.eval_volume_analysis(candles, &mut cached_facts, &mut labels);
        }
        // Keltner + squeeze
        if is(&["structure"]) {
            self.eval_keltner(candles, &mut cached_facts, &mut labels);
        }
        // CCI
        if is(&["momentum"]) {
            self.eval_momentum(candles, &mut cached_facts, &mut labels);
        }
        // Price action
        if is(&["volume"]) {
            self.eval_price_action(candles, &mut cached_facts, &mut labels);
        }
        // Advanced indicators: regime detection, seismology, info theory
        if is(&["regime", "momentum", "structure"]) {
            self.eval_advanced(candles, &mut cached_facts, &mut owned_facts, &mut labels);
        }

        // Unify all facts, then filter suppressed (high fire-rate constants).
        let mut all_refs: Vec<&Vector> = Vec::with_capacity(cached_facts.len() + owned_facts.len());
        all_refs.extend(cached_facts.iter().copied());
        all_refs.extend(owned_facts.iter());

        if let Some(sup) = suppressed {
            let mut kept_refs: Vec<&Vector> = Vec::with_capacity(all_refs.len());
            let mut kept_labels: Vec<String> = Vec::with_capacity(labels.len());
            for (vec, label) in all_refs.iter().zip(labels.iter()) {
                if !sup.contains(label) {
                    kept_refs.push(vec);
                    kept_labels.push(label.clone());
                }
            }
            all_refs = kept_refs;
            labels = kept_labels;
        }

        let fact_count = all_refs.len();
        let thought = if fact_count == 0 {
            Vector::zeros(self.vocab.dims())
        } else {
            Primitives::bundle(&all_refs)
        };

        let coherence = 0.0;

        ThoughtResult { thought, coherence, fact_labels: labels, fact_count }
    }

    // ─── Comparison predicates (cached) ──────────────────────────────────

    fn eval_comparisons_cached<'a>(
        &'a self,
        now: &Candle,
        prev: Option<&Candle>,
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let has_prev_field = |name: &str| name.starts_with("prev-");

        for &(a, b) in COMPARISON_PAIRS {
            let a_val = match field_value(now, prev, a) { Some(v) => v, None => continue };
            let b_val = match field_value(now, prev, b) { Some(v) => v, None => continue };

            if a_val > b_val {
                let key = format!("(above {} {})", a, b);
                if let Some(v) = self.fact_cache.get(&key) {
                    facts.push(v);
                    labels.push(key);
                }
            } else {
                let key = format!("(below {} {})", a, b);
                if let Some(v) = self.fact_cache.get(&key) {
                    facts.push(v);
                    labels.push(key);
                }
            }

            // crosses/touches/bounces need prev values of both fields;
            // skip for pairs involving prev-* fields (would need prev-prev candle)
            if has_prev_field(a) || has_prev_field(b) { continue; }

            if let Some(p) = prev {
                let pa = match field_value(p, None, a) { Some(v) => v, None => continue };
                let pb = match field_value(p, None, b) { Some(v) => v, None => continue };

                if pa < pb && a_val >= b_val {
                    let key = format!("(crosses-above {} {})", a, b);
                    if let Some(v) = self.fact_cache.get(&key) {
                        facts.push(v);
                        labels.push(key);
                    }
                } else if pa > pb && a_val <= b_val {
                    let key = format!("(crosses-below {} {})", a, b);
                    if let Some(v) = self.fact_cache.get(&key) {
                        facts.push(v);
                        labels.push(key);
                    }
                }
            }

            let atr = now.atr_r.max(0.001);
            let epsilon = atr * 0.1;
            if (a_val - b_val).abs() < epsilon {
                let key = format!("(touches {} {})", a, b);
                if let Some(v) = self.fact_cache.get(&key) {
                    facts.push(v);
                    labels.push(key);
                }

                if let Some(p) = prev {
                    let pa = match field_value(p, None, a) { Some(v) => v, None => continue };
                    let pb = match field_value(p, None, b) { Some(v) => v, None => continue };
                    let prev_dist = (pa - pb).abs();
                    let now_dist = (a_val - b_val).abs();
                    if prev_dist < epsilon && now_dist > prev_dist {
                        let key = format!("(bounces-off {} {})", a, b);
                        if let Some(v) = self.fact_cache.get(&key) {
                            facts.push(v);
                            labels.push(key);
                        }
                    }
                }
            }
        }
    }

    // ─── Segment narrative (PELT-based) ────────────────────────────────

    fn eval_segment_narrative(
        &self,
        candles: &[Candle],
        vm: &VectorManager,
        facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        let n_candles = candles.len();
        if n_candles < 5 { return; }

        let beginning_atom = self.vocab.get("beginning");
        let ending_atom = self.vocab.get("ending");

        for &(stream_name, extractor) in SEGMENT_STREAMS {
            let values: Vec<f64> = if stream_name == "rsi-sma" {
                // Rolling RSI SMA (14-period)
                (0..n_candles).map(|i| {
                    let start = i.saturating_sub(13);
                    let window = &candles[start..=i];
                    window.iter().map(|c| c.rsi).sum::<f64>() / window.len() as f64
                }).collect()
            } else {
                candles.iter().map(extractor).collect()
            };

            if values.len() < 5 { continue; }

            // Skip streams with degenerate data (all zeros or NaN)
            let finite_count = values.iter().filter(|v| v.is_finite() && **v != 0.0).count();
            if finite_count < 5 { continue; }

            let penalty = bic_penalty(&values);
            let changepoints = pelt_changepoints(&values, penalty);

            let mut boundaries = vec![0];
            boundaries.extend_from_slice(&changepoints);
            boundaries.push(values.len());

            let n_segments = boundaries.len() - 1;
            let ind_atom = self.vocab.get(stream_name);

            // Collect zone checks relevant to this stream
            let zone_checks: Vec<_> = STREAM_ZONE_CHECKS.iter()
                .filter(|&&(s, _, _, _)| s == stream_name)
                .collect();

            // Walk segments from newest (position 0) to oldest
            for pos in 0..n_segments {
                let seg_idx = n_segments - 1 - pos;
                let start = boundaries[seg_idx];
                let end = boundaries[seg_idx + 1];
                let duration = end - start;
                let candles_ago_end = n_candles - end;

                // Skip degenerate segments: dur=1 at the window edge is a boundary
                // artifact, not a market signal.
                if duration <= 1 && (start == 0 || end >= n_candles) { continue; }

                let seg_start_val = values[start];
                let seg_end_val = values[end - 1];
                let change = seg_end_val - seg_start_val;

                let dir = if change.abs() < 1e-10 { "flat" }
                          else if change > 0.0 { "up" }
                          else { "down" };

                // bind(direction, encode_log(|change|))
                let mag_vec = self.scalar_enc.encode_log(change.abs().max(1e-10));
                let dir_atom = self.vocab.get(dir);
                let signed_mag = Primitives::bind(dir_atom, &mag_vec);

                let duration_vec = self.scalar_enc.encode_log(duration as f64);

                // segment_desc = bind(indicator, bind(signed_magnitude, duration))
                let desc = Primitives::bind(ind_atom,
                           &Primitives::bind(&signed_mag, &duration_vec));

                // Three-layer temporal: position (orthogonal) × chrono anchor (log)
                let pos_vec = vm.get_position_vector(pos as i64);
                let chrono_vec = self.scalar_enc.encode_log((candles_ago_end + 1) as f64);
                let temporal = Primitives::bind(&pos_vec, &chrono_vec);

                let segment_fact = Primitives::bind(&desc, &temporal);
                facts.push(segment_fact);
                labels.push(format!("(seg {} {} {:.4} dur={} @{} ago={})",
                                   stream_name, dir, change, duration, pos, candles_ago_end));

                // Zone states at segment boundaries (only for streams with zone checks)
                if !zone_checks.is_empty() {
                    let begin_candle = &candles[start.min(n_candles - 1)];
                    let end_candle = &candles[(end - 1).min(n_candles - 1)];

                    for &&(_stream, ind, zone, check) in &zone_checks {
                        let zone_key = format!("(at {} {})", ind, zone);
                        if let Some(zone_vec) = self.fact_cache.get(&zone_key) {
                            if check(begin_candle) {
                                let bound = Primitives::bind(
                                    &Primitives::bind(zone_vec, beginning_atom),
                                    &pos_vec);
                                facts.push(bound);
                                labels.push(format!("(zone {} {} beginning @{})", ind, zone, pos));
                            }
                            if check(end_candle) {
                                let bound = Primitives::bind(
                                    &Primitives::bind(zone_vec, ending_atom),
                                    &pos_vec);
                                facts.push(bound);
                                labels.push(format!("(zone {} {} ending @{})", ind, zone, pos));
                            }
                        }
                    }
                }
            }
        }
    }

    // ─── Calendar facts (viewport right-edge) ───────────────────────────

    fn eval_calendar<'a>(
        &'a self,
        now: &Candle,
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        // Day of week from timestamp (format: "YYYY-MM-DD HH:MM:SS" or similar)
        if let Some(day) = Self::day_of_week_from_ts(&now.ts) {
            let key = format!("(at-day {})", day);
            if let Some(v) = self.fact_cache.get(&key) {
                facts.push(v);
                labels.push(key);
            }
        }

        // Hour block (4-hour buckets)
        if let Some(hour_block) = Self::hour_block_from_ts(&now.ts) {
            let key = format!("(at-hour {})", hour_block);
            if let Some(v) = self.fact_cache.get(&key) {
                facts.push(v);
                labels.push(key);
            }
        }

        // Trading session
        if let Some(session) = Self::session_from_ts(&now.ts) {
            let key = format!("(at-session {})", session);
            if let Some(v) = self.fact_cache.get(&key) {
                facts.push(v);
                labels.push(key);
            }
        }
    }

    fn day_of_week_from_ts(ts: &str) -> Option<&'static str> {
        // Parse "YYYY-MM-DD ..." and compute day of week via Tomohiko Sakamoto's algorithm
        if ts.len() < 10 { return None; }
        let y: i32 = ts[0..4].parse().ok()?;
        let m: u32 = ts[5..7].parse().ok()?;
        let d: u32 = ts[8..10].parse().ok()?;
        let days = &["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
        let t = [0_i32, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
        let y = if m < 3 { y - 1 } else { y };
        let dow = ((y + y / 4 - y / 100 + y / 400 + t[(m - 1) as usize] + d as i32) % 7) as usize;
        Some(days[dow])
    }

    fn hour_block_from_ts(ts: &str) -> Option<&'static str> {
        if ts.len() < 13 { return None; }
        let h: u32 = ts[11..13].parse().ok()?;
        match h {
            0..=3   => Some("h00"),
            4..=7   => Some("h04"),
            8..=11  => Some("h08"),
            12..=15 => Some("h12"),
            16..=19 => Some("h16"),
            20..=23 => Some("h20"),
            _ => None,
        }
    }

    fn session_from_ts(ts: &str) -> Option<&'static str> {
        if ts.len() < 13 { return None; }
        let h: u32 = ts[11..13].parse().ok()?;
        match h {
            0..=7   => Some("asian-session"),
            8..=13  => Some("european-session"),
            14..=20 => Some("us-session"),
            21..=23 => Some("off-hours"),
            _ => None,
        }
    }

    // ─── Temporal (since) ────────────────────────────────────────────────

    fn eval_temporal(
        &self,
        candles: &[Candle],
        vm: &VectorManager,
        facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        if candles.len() < 3 { return; }

        // Build close PELT segment map for structural lookback.
        // segment_of[i] = segment index (0 = oldest) for candle i.
        let close_vals: Vec<f64> = candles.iter().map(|c| c.close.ln()).collect();
        let penalty = bic_penalty(&close_vals);
        let cps = pelt_changepoints(&close_vals, penalty);
        let n = candles.len();
        let mut boundaries = vec![0usize];
        boundaries.extend_from_slice(&cps);
        boundaries.push(n);
        let n_segs = boundaries.len() - 1;
        let mut segment_of = vec![0usize; n];
        for seg in 0..n_segs {
            for j in boundaries[seg]..boundaries[seg + 1] {
                segment_of[j] = seg;
            }
        }
        let current_seg = segment_of[n - 1];

        let max_lookback = 12.min(n - 2);

        for back in 1..=max_lookback {
            let idx = n - 1 - back;
            let c = &candles[idx];
            let p = &candles[idx.saturating_sub(1)];

            // Segment distance: how many segment boundaries between this candle and now.
            // Events in the same segment as the current candle get distance 1 (very recent).
            let seg_dist = (current_seg - segment_of[idx]).max(1);

            // Golden/death cross
            if p.sma50 > 0.0 && p.sma200 > 0.0 && c.sma50 > 0.0 && c.sma200 > 0.0 {
                if p.sma50 < p.sma200 && c.sma50 >= c.sma200 {
                    let base = fact_binary(&self.vocab, "crosses-above", "sma50", "sma200");
                    facts.push(fact_since(vm, &base, seg_dist));
                    labels.push(format!("(since (crosses-above sma50 sma200) {}seg)", seg_dist));
                }
                if p.sma50 > p.sma200 && c.sma50 <= c.sma200 {
                    let base = fact_binary(&self.vocab, "crosses-below", "sma50", "sma200");
                    facts.push(fact_since(vm, &base, seg_dist));
                    labels.push(format!("(since (crosses-below sma50 sma200) {}seg)", seg_dist));
                }
            }

            // MACD cross
            if p.macd_line != 0.0 && c.macd_line != 0.0 {
                if p.macd_line < p.macd_signal && c.macd_line >= c.macd_signal {
                    let base = fact_binary(&self.vocab, "crosses-above", "macd-line", "macd-signal");
                    facts.push(fact_since(vm, &base, seg_dist));
                    labels.push(format!("(since (crosses-above macd-line macd-signal) {}seg)", seg_dist));
                }
                if p.macd_line > p.macd_signal && c.macd_line <= c.macd_signal {
                    let base = fact_binary(&self.vocab, "crosses-below", "macd-line", "macd-signal");
                    facts.push(fact_since(vm, &base, seg_dist));
                    labels.push(format!("(since (crosses-below macd-line macd-signal) {}seg)", seg_dist));
                }
            }
        }
    }

    // ─── RSI divergence (PELT-structural) ──────────────────────────────

    fn eval_divergence(
        &self,
        candles: &[Candle],
        vm: &VectorManager,
        facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        if candles.len() < 10 { return; }

        // PELT on ln(close) to find structural segments — same basis as segment narrative.
        let close_ln: Vec<f64> = candles.iter().map(|c| c.close.ln()).collect();
        let penalty = bic_penalty(&close_ln);
        let cps = pelt_changepoints(&close_ln, penalty);

        let n = close_ln.len();
        let mut boundaries = vec![0usize];
        boundaries.extend_from_slice(&cps);
        boundaries.push(n);
        let n_segs = boundaries.len() - 1;
        if n_segs < 3 { return; }

        // Segment directions: +1 up, -1 down, 0 flat.
        let seg_dirs: Vec<i8> = (0..n_segs)
            .map(|i| {
                let change = close_ln[boundaries[i + 1] - 1] - close_ln[boundaries[i]];
                if change > 1e-10 { 1 } else if change < -1e-10 { -1 } else { 0 }
            })
            .collect();

        // Peaks: up→down boundary. Peak candle = last candle of the up-segment.
        // Troughs: down→up boundary. Trough candle = last candle of the down-segment.
        let mut peaks:   Vec<usize> = Vec::new();
        let mut troughs: Vec<usize> = Vec::new();
        for i in 0..n_segs - 1 {
            if seg_dirs[i] == 1 && seg_dirs[i + 1] == -1 {
                peaks.push(boundaries[i + 1] - 1);
            } else if seg_dirs[i] == -1 && seg_dirs[i + 1] == 1 {
                troughs.push(boundaries[i + 1] - 1);
            }
        }

        // Bearish divergence: every consecutive peak pair where price made higher
        // high but RSI made lower high. Temporal binding = how recent the newer peak is.
        for pair in peaks.windows(2) {
            let (i_prev, i_curr) = (pair[0], pair[1]);
            if candles[i_curr].close > candles[i_prev].close
                && candles[i_curr].rsi < candles[i_prev].rsi
            {
                let close_up  = Primitives::bind(self.vocab.get("close"), self.vocab.get("up"));
                let rsi_down  = Primitives::bind(self.vocab.get("rsi"),   self.vocab.get("down"));
                let div_fact = Primitives::bind(
                    self.vocab.get("diverging"),
                    &Primitives::bind(&close_up, &rsi_down),
                );
                let ago = n - 1 - i_curr;
                let pos = vm.get_position_vector(ago as i64);
                facts.push(Primitives::bind(&div_fact, &pos));
                labels.push(format!("(diverging close up rsi down @{})", ago));
            }
        }

        // Bullish divergence: every consecutive trough pair where price made lower
        // low but RSI made higher low.
        for pair in troughs.windows(2) {
            let (i_prev, i_curr) = (pair[0], pair[1]);
            if candles[i_curr].close < candles[i_prev].close
                && candles[i_curr].rsi > candles[i_prev].rsi
            {
                let close_down = Primitives::bind(self.vocab.get("close"), self.vocab.get("down"));
                let rsi_up     = Primitives::bind(self.vocab.get("rsi"),   self.vocab.get("up"));
                let div_fact = Primitives::bind(
                    self.vocab.get("diverging"),
                    &Primitives::bind(&close_down, &rsi_up),
                );
                let ago = n - 1 - i_curr;
                let pos = vm.get_position_vector(ago as i64);
                facts.push(Primitives::bind(&div_fact, &pos));
                labels.push(format!("(diverging close down rsi up @{})", ago));
            }
        }
    }

    // ─── Volume confirmation ─────────────────────────────────────────────

    fn eval_volume_confirmation(
        &self,
        candles: &[Candle],
        facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        if candles.len() < 5 { return; }

        let close_vals: Vec<f64> = candles.iter().map(|c| c.close.ln()).collect();
        let vol_vals: Vec<f64> = candles.iter()
            .map(|c| if c.volume > 0.0 { c.volume.ln() } else { 0.0 })
            .collect();

        let close_dir = most_recent_segment_dir(&close_vals);
        let vol_dir   = most_recent_segment_dir(&vol_vals);

        if let (Some(cd), Some(vd)) = (close_dir, vol_dir) {
            let predicate = if cd == vd { "confirming" } else { "contradicting" };
            let fact = Primitives::bind(
                self.vocab.get(predicate),
                &Primitives::bind(self.vocab.get("volume"), self.vocab.get("close")),
            );
            facts.push(fact);
            labels.push(format!("({} volume close)", predicate));
        }
    }

    // ─── Range position scalar ───────────────────────────────────────────

    fn eval_range_position(
        &self,
        candles: &[Candle],
        facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        if candles.is_empty() { return; }

        let range_high = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let range_low  = candles.iter().map(|c| c.low ).fold(f64::INFINITY,     f64::min);
        let span = range_high - range_low;
        if span < 1e-10 { return; }

        let current  = candles.last().unwrap().close;
        let position = (current - range_low) / span; // 0.0 = range low, 1.0 = range high

        // Linear encoding with scale=2.0: position 0.0 and 1.0 are anti-correlated,
        // position 0.5 is orthogonal to both. Equal absolute differences → equal similarity.
        let pos_vec = self.scalar_enc.encode(position, ScalarMode::Linear { scale: 2.0 });
        let fact = Primitives::bind(self.vocab.get("range-pos"), &pos_vec);
        facts.push(fact);
        labels.push(format!("(range-pos {:.3})", position));
    }

    // ─── Ichimoku Cloud ─────────────────────────────────────────────────

    fn eval_ichimoku<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let n = candles.len();
        if n < 26 { return; }

        let now = candles.last().unwrap();

        // Tenkan-sen: (highest_high + lowest_low) / 2 over 9 periods
        let tenkan = {
            let w = &candles[n.saturating_sub(9)..];
            let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            (hi + lo) / 2.0
        };

        // Kijun-sen: (highest_high + lowest_low) / 2 over 26 periods
        let kijun = {
            let w = &candles[n.saturating_sub(26)..];
            let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            (hi + lo) / 2.0
        };

        // Senkou Span A: (tenkan + kijun) / 2
        let span_a = (tenkan + kijun) / 2.0;

        // Senkou Span B: (highest + lowest) / 2 over 52 periods (use available)
        let span_b = {
            let hi = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let lo = candles.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            (hi + lo) / 2.0
        };

        let cloud_top = span_a.max(span_b);
        let cloud_bottom = span_a.min(span_b);
        let close = now.close;

        // Compute comparisons using cached fact vectors
        let pairs: &[(&str, &str, f64, f64)] = &[
            ("close", "tenkan-sen", close, tenkan),
            ("close", "kijun-sen", close, kijun),
            ("close", "cloud-top", close, cloud_top),
            ("close", "cloud-bottom", close, cloud_bottom),
            ("tenkan-sen", "kijun-sen", tenkan, kijun),
            ("close", "senkou-span-a", close, span_a),
            ("close", "senkou-span-b", close, span_b),
        ];

        for &(a_name, b_name, a_val, b_val) in pairs {
            let pred = if a_val > b_val { "above" } else { "below" };
            let key = format!("({} {} {})", pred, a_name, b_name);
            if let Some(v) = self.fact_cache.get(&key) {
                facts.push(v);
                labels.push(key);
            }
        }

        // Cloud zone
        let zone = if close > cloud_top { "above-cloud" }
                   else if close < cloud_bottom { "below-cloud" }
                   else { "in-cloud" };
        let key = format!("(at close {})", zone);
        if let Some(v) = self.fact_cache.get(&key) {
            facts.push(v);
            labels.push(key);
        }

        // Tenkan-kijun cross (check prev candle)
        if n >= 27 {
            let prev_tenkan = {
                let w = &candles[n.saturating_sub(10)..n-1];
                let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
                let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
                (hi + lo) / 2.0
            };
            let prev_kijun = {
                let w = &candles[n.saturating_sub(27)..n-1];
                let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
                let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
                (hi + lo) / 2.0
            };
            if prev_tenkan < prev_kijun && tenkan >= kijun {
                if let Some(v) = self.fact_cache.get("(crosses-above tenkan-sen kijun-sen)") {
                    facts.push(v); labels.push("(crosses-above tenkan-sen kijun-sen)".into());
                }
            } else if prev_tenkan > prev_kijun && tenkan <= kijun {
                if let Some(v) = self.fact_cache.get("(crosses-below tenkan-sen kijun-sen)") {
                    facts.push(v); labels.push("(crosses-below tenkan-sen kijun-sen)".into());
                }
            }
        }
    }

    // ─── Stochastic Oscillator ───────────────────────────────────────────

    fn eval_stochastic<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let n = candles.len();
        if n < 14 { return; }

        let w = &candles[n.saturating_sub(14)..];
        let hh = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let ll = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        let range = hh - ll;
        if range < 1e-10 { return; }

        let stoch_k = (candles.last().unwrap().close - ll) / range * 100.0;

        // %D = 3-period SMA of %K (approximate from last 3 candles)
        let stoch_d = if n >= 16 {
            let mut sum = stoch_k;
            for offset in 1..=2 {
                let idx = n - 1 - offset;
                let w2 = &candles[idx.saturating_sub(13)..=idx];
                let h2 = w2.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
                let l2 = w2.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
                let r2 = h2 - l2;
                if r2 > 1e-10 { sum += (candles[idx].close - l2) / r2 * 100.0; }
                else { sum += 50.0; }
            }
            sum / 3.0
        } else { stoch_k };

        // Stoch K vs D comparison
        let pred = if stoch_k > stoch_d { "above" } else { "below" };
        let key = format!("({} stoch-k stoch-d)", pred);
        if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }

        // Cross detection
        if n >= 16 {
            // Previous K and D
            let idx = n - 2;
            let w2 = &candles[idx.saturating_sub(13)..=idx];
            let h2 = w2.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let l2 = w2.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            let r2 = h2 - l2;
            let prev_k = if r2 > 1e-10 { (candles[idx].close - l2) / r2 * 100.0 } else { 50.0 };
            // Approximate prev_d
            let prev_d = stoch_d; // rough approximation
            if prev_k < prev_d && stoch_k >= stoch_d {
                if let Some(v) = self.fact_cache.get("(crosses-above stoch-k stoch-d)") {
                    facts.push(v); labels.push("(crosses-above stoch-k stoch-d)".into());
                }
            } else if prev_k > prev_d && stoch_k <= stoch_d {
                if let Some(v) = self.fact_cache.get("(crosses-below stoch-k stoch-d)") {
                    facts.push(v); labels.push("(crosses-below stoch-k stoch-d)".into());
                }
            }
        }

        // Zones
        if stoch_k > 80.0 {
            if let Some(v) = self.fact_cache.get("(at stoch-k stoch-overbought)") {
                facts.push(v); labels.push("(at stoch-k stoch-overbought)".into());
            }
        } else if stoch_k < 20.0 {
            if let Some(v) = self.fact_cache.get("(at stoch-k stoch-oversold)") {
                facts.push(v); labels.push("(at stoch-k stoch-oversold)".into());
            }
        }
    }

    // ─── Fibonacci Retracement ───────────────────────────────────────────

    fn eval_fibonacci(
        &self,
        candles: &[Candle],
        facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        if candles.len() < 10 { return; }

        // Use the viewport range high/low as swing points
        let swing_high = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let swing_low = candles.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        let range = swing_high - swing_low;
        if range < 1e-10 { return; }

        let close = candles.last().unwrap().close;
        let atr = candles.last().unwrap().atr_r * close;

        // Fib levels from swing low to swing high
        let fibs: &[(&str, f64)] = &[
            ("fib-236", 0.236), ("fib-382", 0.382), ("fib-500", 0.500),
            ("fib-618", 0.618), ("fib-786", 0.786),
        ];

        for &(name, ratio) in fibs {
            let level = swing_low + range * ratio;
            // Is close near this fib level? (within 0.5 ATR)
            if (close - level).abs() < atr * 0.5 {
                let fact = Primitives::bind(
                    self.vocab.get("touches"),
                    &Primitives::bind(self.vocab.get("close"), self.vocab.get(name)),
                );
                facts.push(fact);
                labels.push(format!("(touches close {})", name));
            }
            // Above or below
            let pred = if close > level { "above" } else { "below" };
            let fact = Primitives::bind(
                self.vocab.get(pred),
                &Primitives::bind(self.vocab.get("close"), self.vocab.get(name)),
            );
            facts.push(fact);
            labels.push(format!("({} close {})", pred, name));
        }
    }

    // ─── Volume Analysis ─────────────────────────────────────────────────

    fn eval_volume_analysis<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let n = candles.len();
        if n < 20 { return; }

        // Volume SMA (20-period)
        let vol_sma: f64 = candles[n.saturating_sub(20)..].iter()
            .map(|c| c.volume).sum::<f64>() / 20.0;
        let vol = candles.last().unwrap().volume;

        if vol_sma > 0.0 {
            let ratio = vol / vol_sma;
            if ratio > 2.0 {
                if let Some(v) = self.fact_cache.get("(at volume volume-spike)") {
                    facts.push(v); labels.push("(at volume volume-spike)".into());
                }
            } else if ratio < 0.5 {
                if let Some(v) = self.fact_cache.get("(at volume volume-drought)") {
                    facts.push(v); labels.push("(at volume volume-drought)".into());
                }
            }
        }
    }

    // ─── Keltner Channels + Squeeze ──────────────────────────────────────

    fn eval_keltner<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let now = candles.last().unwrap();
        if now.sma20 <= 0.0 || now.atr_r <= 0.0 { return; }

        let atr_abs = now.atr_r * now.close;
        let keltner_upper = now.sma20 + 2.0 * atr_abs;
        let keltner_lower = now.sma20 - 2.0 * atr_abs;
        let close = now.close;

        // Close vs Keltner
        let pred_u = if close > keltner_upper { "above" } else { "below" };
        let key_u = format!("({} close keltner-upper)", pred_u);
        if let Some(v) = self.fact_cache.get(&key_u) { facts.push(v); labels.push(key_u); }

        let pred_l = if close > keltner_lower { "above" } else { "below" };
        let key_l = format!("({} close keltner-lower)", pred_l);
        if let Some(v) = self.fact_cache.get(&key_l) { facts.push(v); labels.push(key_l); }

        // Squeeze: BB inside Keltner (low volatility)
        if now.bb_upper > 0.0 && now.bb_upper < keltner_upper && now.bb_lower > keltner_lower {
            let key = "(at bb-upper keltner-upper)".to_string();
            // BB upper below keltner upper = squeeze
            if let Some(v) = self.fact_cache.get("(below bb-upper keltner-upper)") {
                facts.push(v); labels.push("(below bb-upper keltner-upper)".into());
            }
        }
    }

    // ─── Momentum / ROC / CCI ────────────────────────────────────────────

    fn eval_momentum<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let n = candles.len();
        if n < 20 { return; }

        let now = candles.last().unwrap();

        // CCI: (typical - SMA(typical, 20)) / (0.015 × mean_deviation)
        let typicals: Vec<f64> = candles[n.saturating_sub(20)..].iter()
            .map(|c| (c.high + c.low + c.close) / 3.0).collect();
        let typical_mean = typicals.iter().sum::<f64>() / typicals.len() as f64;
        let mean_dev = typicals.iter().map(|t| (t - typical_mean).abs()).sum::<f64>()
            / typicals.len() as f64;
        if mean_dev > 1e-10 {
            let typical_now = (now.high + now.low + now.close) / 3.0;
            let cci = (typical_now - typical_mean) / (0.015 * mean_dev);
            if cci > 100.0 {
                if let Some(v) = self.fact_cache.get("(at cci cci-overbought)") {
                    facts.push(v); labels.push("(at cci cci-overbought)".into());
                }
            } else if cci < -100.0 {
                if let Some(v) = self.fact_cache.get("(at cci cci-oversold)") {
                    facts.push(v); labels.push("(at cci cci-oversold)".into());
                }
            }
        }
    }

    // ─── Price Action Patterns ───────────────────────────────────────────

    fn eval_price_action<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let n = candles.len();
        if n < 3 { return; }

        let now = &candles[n - 1];
        let prev = &candles[n - 2];

        // Inside bar: current range within previous range
        if now.high <= prev.high && now.low >= prev.low {
            if let Some(v) = self.fact_cache.get("(at close inside-bar)") {
                facts.push(v); labels.push("(at close inside-bar)".into());
            }
        }
        // Outside bar: current range engulfs previous
        if now.high > prev.high && now.low < prev.low {
            if let Some(v) = self.fact_cache.get("(at close outside-bar)") {
                facts.push(v); labels.push("(at close outside-bar)".into());
            }
        }
        // Gap up/down
        let gap = (now.open - prev.close) / prev.close;
        if gap > 0.001 {
            if let Some(v) = self.fact_cache.get("(at close gap-up)") {
                facts.push(v); labels.push("(at close gap-up)".into());
            }
        } else if gap < -0.001 {
            if let Some(v) = self.fact_cache.get("(at close gap-down)") {
                facts.push(v); labels.push("(at close gap-down)".into());
            }
        }

        // Consecutive same-direction candles
        let mut up_count = 0usize;
        let mut down_count = 0usize;
        for i in (0..n).rev() {
            if candles[i].close > candles[i].open { up_count += 1; } else { break; }
        }
        for i in (0..n).rev() {
            if candles[i].close < candles[i].open { down_count += 1; } else { break; }
        }
        if up_count >= 3 {
            if let Some(v) = self.fact_cache.get("(at close consecutive-up)") {
                facts.push(v); labels.push(format!("(at close consecutive-up {})", up_count));
            }
        }
        if down_count >= 3 {
            if let Some(v) = self.fact_cache.get("(at close consecutive-down)") {
                facts.push(v); labels.push(format!("(at close consecutive-down {})", down_count));
            }
        }
    }

    // ─── Advanced indicators (tier-1 underdogs + esoteric) ─────────────

    fn eval_advanced<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        let n = candles.len();
        if n < 20 { return; }

        let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
        let now = candles.last().unwrap();

        // ── KAMA Efficiency Ratio ─────────────────────────────────────
        // ER = |net movement| / sum(|step movements|) over 10 periods
        let er_period = 10.min(n - 1);
        let net_move = (closes[n - 1] - closes[n - 1 - er_period]).abs();
        let step_sum: f64 = (n - er_period..n).map(|i| (closes[i] - closes[i - 1]).abs()).sum();
        let er = if step_sum > 1e-10 { net_move / step_sum } else { 0.0 };

        let zone = if er > 0.6 { "efficient-trend" } else if er < 0.3 { "inefficient-chop" } else { "moderate-efficiency" };
        let key = format!("(at kama-er {})", zone);
        if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }

        // ── Choppiness Index (14-period) ──────────────────────────────
        let chop_period = 14.min(n - 1);
        let chop_slice = &candles[n - chop_period..];
        let chop_atr_sum: f64 = (1..chop_period).map(|i| {
            let hl = chop_slice[i].high - chop_slice[i].low;
            let hc = (chop_slice[i].high - chop_slice[i - 1].close).abs();
            let lc = (chop_slice[i].low - chop_slice[i - 1].close).abs();
            hl.max(hc).max(lc)
        }).sum();
        let chop_hi = chop_slice.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let chop_lo = chop_slice.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        let chop_range = chop_hi - chop_lo;
        let chop = if chop_range > 1e-10 {
            100.0 * (chop_atr_sum / chop_range).log10() / (chop_period as f64).log10()
        } else { 100.0 };

        let chop_zone = if chop < 38.2 { "chop-trending" } else if chop > 75.0 { "chop-extreme" } else if chop > 61.8 { "chop-choppy" } else { "chop-transition" };
        let key = format!("(at chop {})", chop_zone);
        if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }

        // ── DFA Alpha (detrended fluctuation analysis) ────────────────
        let returns: Vec<f64> = (1..n).map(|i| (closes[i] / closes[i - 1]).ln()).collect();
        if returns.len() >= 16 {
            let ret_mean = returns.iter().sum::<f64>() / returns.len() as f64;
            let integrated: Vec<f64> = returns.iter().scan(0.0, |acc, &r| { *acc += r - ret_mean; Some(*acc) }).collect();
            let scales: Vec<usize> = vec![4, 6, 8, 12, 16].into_iter().filter(|&s| s <= integrated.len()).collect();
            if scales.len() >= 3 {
                let mut log_f = Vec::new();
                let mut log_s = Vec::new();
                for &s in &scales {
                    let num_segs = integrated.len() / s;
                    if num_segs == 0 { continue; }
                    let mut f2_sum = 0.0;
                    for seg in 0..num_segs {
                        let start = seg * s;
                        let seg_data = &integrated[start..start + s];
                        // Linear detrend
                        let sx: f64 = (0..s).map(|i| i as f64).sum();
                        let sy: f64 = seg_data.iter().sum();
                        let sxx: f64 = (0..s).map(|i| (i * i) as f64).sum();
                        let sxy: f64 = (0..s).map(|i| i as f64 * seg_data[i]).sum();
                        let sn = s as f64;
                        let denom = sn * sxx - sx * sx;
                        let (a, b) = if denom.abs() > 1e-10 {
                            let b = (sn * sxy - sx * sy) / denom;
                            let a = (sy - b * sx) / sn;
                            (a, b)
                        } else { (0.0, 0.0) };
                        let rms: f64 = seg_data.iter().enumerate()
                            .map(|(i, &y)| { let trend = a + b * i as f64; (y - trend).powi(2) })
                            .sum::<f64>() / sn;
                        f2_sum += rms;
                    }
                    let f = (f2_sum / num_segs as f64).sqrt();
                    if f > 1e-10 {
                        log_f.push(f.ln());
                        log_s.push((s as f64).ln());
                    }
                }
                if log_f.len() >= 3 {
                    let nf = log_f.len() as f64;
                    let sx: f64 = log_s.iter().sum();
                    let sy: f64 = log_f.iter().sum();
                    let sxx: f64 = log_s.iter().map(|x| x * x).sum();
                    let sxy: f64 = log_s.iter().zip(log_f.iter()).map(|(x, y)| x * y).sum();
                    let denom = nf * sxx - sx * sx;
                    if denom.abs() > 1e-10 {
                        let alpha = (nf * sxy - sx * sy) / denom;
                        let alpha = alpha.clamp(0.0, 1.5);
                        let dfa_zone = if alpha > 0.6 { "persistent-dfa" }
                            else if alpha < 0.4 { "anti-persistent-dfa" }
                            else { "random-walk-dfa" };
                        let key = format!("(at dfa-alpha {})", dfa_zone);
                        if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
                    }
                }
            }
        }

        // ── Variance Ratio (k=5) ─────────────────────────────────────
        if returns.len() >= 10 {
            let var1: f64 = returns.iter().map(|r| r * r).sum::<f64>() / returns.len() as f64;
            let k = 5usize;
            let k_returns: Vec<f64> = (0..returns.len() - k + 1)
                .map(|i| returns[i..i + k].iter().sum::<f64>()).collect();
            if !k_returns.is_empty() && var1 > 1e-20 {
                let var_k: f64 = k_returns.iter().map(|r| r * r).sum::<f64>() / k_returns.len() as f64 / k as f64;
                let vr = var_k / var1;
                let vr_zone = if vr > 1.3 { "vr-momentum" } else if vr < 0.7 { "vr-mean-revert" } else { "vr-neutral" };
                let key = format!("(at variance-ratio {})", vr_zone);
                if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
            }
        }

        // ── DeMark TD Sequential ─────────────────────────────────────
        if n >= 5 {
            let mut count: i32 = 0;
            for i in 4..n {
                if closes[i] > closes[i - 4] {
                    count = if count > 0 { count + 1 } else { 1 };
                } else if closes[i] < closes[i - 4] {
                    count = if count < 0 { count - 1 } else { -1 };
                } else { count = 0; }
            }
            let abs_count = count.unsigned_abs();
            let td_zone = if abs_count >= 9 { "td-exhausted" }
                else if abs_count >= 7 { "td-mature" }
                else if abs_count >= 4 { "td-building" }
                else { "td-inactive" };
            let key = format!("(at td-count {})", td_zone);
            if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
        }

        // ── Aroon (25-period) ────────────────────────────────────────
        let aroon_period = 25.min(n - 1);
        if n > aroon_period {
            let slice = &candles[n - aroon_period - 1..];
            let mut hi_idx = 0;
            let mut lo_idx = 0;
            for i in 0..=aroon_period {
                if slice[i].high >= slice[hi_idx].high { hi_idx = i; }
                if slice[i].low <= slice[lo_idx].low { lo_idx = i; }
            }
            let aroon_up = 100.0 * hi_idx as f64 / aroon_period as f64;
            let aroon_down = 100.0 * lo_idx as f64 / aroon_period as f64;
            let aroon_zone = if aroon_up > 80.0 && aroon_down < 30.0 { "aroon-strong-up" }
                else if aroon_down > 80.0 && aroon_up < 30.0 { "aroon-strong-down" }
                else if aroon_up < 20.0 && aroon_down < 20.0 { "aroon-stale" }
                else { "aroon-consolidating" };
            let key = format!("(at aroon-up {})", aroon_zone);
            if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
        }

        // ── Fractal Dimension (Katz) ─────────────────────────────────
        {
            let path_len: f64 = (1..n).map(|i| ((closes[i] - closes[i-1]).powi(2) + 1.0).sqrt()).sum();
            let max_dist = closes.iter().map(|&c| (c - closes[0]).abs()).fold(0.0_f64, f64::max);
            if path_len > 1e-10 && max_dist > 1e-10 {
                let nf = n as f64;
                let fd = nf.ln() / (nf.ln() + (max_dist / path_len).ln());
                let fd = fd.clamp(1.0, 2.0);
                let fd_zone = if fd < 1.3 { "trending-geometry" }
                    else if fd > 1.7 { "mean-reverting-geometry" }
                    else { "random-walk-geometry" };
                let key = format!("(at fractal-dim {})", fd_zone);
                if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
            }
        }

        // ── Spectral Slope ───────────────────────────────────────────
        if returns.len() >= 16 {
            // Simple periodogram: compute power at each frequency
            let nr = returns.len();
            let mut log_p = Vec::new();
            let mut log_f = Vec::new();
            for k in 1..nr / 2 {
                let freq = k as f64 / nr as f64;
                let mut re = 0.0_f64;
                let mut im = 0.0_f64;
                for (t, &r) in returns.iter().enumerate() {
                    let angle = 2.0 * std::f64::consts::PI * k as f64 * t as f64 / nr as f64;
                    re += r * angle.cos();
                    im += r * angle.sin();
                }
                let power = (re * re + im * im) / nr as f64;
                if power > 1e-20 {
                    log_p.push(power.ln());
                    log_f.push(freq.ln());
                }
            }
            if log_p.len() >= 4 {
                let nf = log_p.len() as f64;
                let sx: f64 = log_f.iter().sum();
                let sy: f64 = log_p.iter().sum();
                let sxx: f64 = log_f.iter().map(|x| x * x).sum();
                let sxy: f64 = log_f.iter().zip(log_p.iter()).map(|(x, y)| x * y).sum();
                let denom = nf * sxx - sx * sx;
                if denom.abs() > 1e-10 {
                    let _beta = (nf * sxy - sx * sy) / denom;
                    // beta near 0 = white noise, near -2 = Brownian
                    // Stored as atom but not yet zoned — curve will judge
                }
            }
        }

        // ── Entropy Rate (bigram conditional entropy) ────────────────
        if returns.len() >= 20 {
            // Classify each return as up/flat/down
            let classes: Vec<u8> = returns.iter().map(|&r| {
                if r > 0.0001 { 2 } else if r < -0.0001 { 0 } else { 1 }
            }).collect();
            // Count bigram frequencies
            let mut bigrams = [[0u32; 3]; 3];
            let mut unigrams = [0u32; 3];
            for w in classes.windows(2) {
                bigrams[w[0] as usize][w[1] as usize] += 1;
                unigrams[w[0] as usize] += 1;
            }
            // Conditional entropy H(X_t | X_{t-1})
            let total = (classes.len() - 1) as f64;
            let mut h_cond = 0.0_f64;
            for i in 0..3 {
                if unigrams[i] == 0 { continue; }
                let p_i = unigrams[i] as f64 / total;
                for j in 0..3 {
                    if bigrams[i][j] == 0 { continue; }
                    let p_j_given_i = bigrams[i][j] as f64 / unigrams[i] as f64;
                    h_cond -= p_i * p_j_given_i * p_j_given_i.ln();
                }
            }
            // Normalize by max entropy (ln(3))
            let h_norm = h_cond / 3.0_f64.ln();
            let ent_zone = if h_norm < 0.7 { "low-entropy-rate" } else { "high-entropy-rate" };
            let key = format!("(at entropy-rate {})", ent_zone);
            if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
        }

        // ── Gutenberg-Richter b-value (seismology) ───────────────────
        if returns.len() >= 20 {
            // b-value = slope of log(frequency) vs log(magnitude)
            let mut abs_returns: Vec<f64> = returns.iter().map(|r| r.abs()).collect();
            abs_returns.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let nr = abs_returns.len();
            // Compute complementary CDF at a few magnitude thresholds
            let thresholds: Vec<f64> = (1..5).map(|i| {
                abs_returns[nr * i / 5]
            }).collect();
            let mut log_n = Vec::new();
            let mut log_m = Vec::new();
            for &t in &thresholds {
                if t < 1e-10 { continue; }
                let count = abs_returns.iter().filter(|&&r| r >= t).count();
                if count > 0 {
                    log_n.push((count as f64).ln());
                    log_m.push(t.ln());
                }
            }
            if log_n.len() >= 3 {
                let nf = log_n.len() as f64;
                let sx: f64 = log_m.iter().sum();
                let sy: f64 = log_n.iter().sum();
                let sxx: f64 = log_m.iter().map(|x| x * x).sum();
                let sxy: f64 = log_m.iter().zip(log_n.iter()).map(|(x, y)| x * y).sum();
                let denom = nf * sxx - sx * sx;
                if denom.abs() > 1e-10 {
                    let b = -(nf * sxy - sx * sy) / denom; // negative slope
                    let gr_zone = if b < 1.0 { "heavy-tails" } else { "light-tails" };
                    let key = format!("(at gr-bvalue {})", gr_zone);
                    if let Some(v) = self.fact_cache.get(&key) { facts.push(v); labels.push(key); }
                }
            }
        }
    }

    // ─── RSI SMA (cached) ───────────────────────────────────────────────

    fn eval_rsi_sma_cached<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        if candles.len() < 15 { return; }

        let rsi_window = &candles[candles.len().saturating_sub(14)..];
        let rsi_sum: f64 = rsi_window.iter().map(|c| c.rsi).sum();
        let rsi_sma = rsi_sum / rsi_window.len() as f64;

        let now = candles.last().unwrap();

        let key = if now.rsi > rsi_sma { "(above rsi rsi-sma)" } else { "(below rsi rsi-sma)" };
        if let Some(v) = self.fact_cache.get(key) { facts.push(v); labels.push(key.into()); }

        if candles.len() >= 16 {
            let prev_window = &candles[candles.len().saturating_sub(15)..candles.len() - 1];
            let prev_rsi_sum: f64 = prev_window.iter().map(|c| c.rsi).sum();
            let prev_rsi_sma = prev_rsi_sum / prev_window.len() as f64;
            let prev = &candles[candles.len() - 2];

            if prev.rsi < prev_rsi_sma && now.rsi >= rsi_sma {
                if let Some(v) = self.fact_cache.get("(crosses-above rsi rsi-sma)") { facts.push(v); labels.push("(crosses-above rsi rsi-sma)".into()); }
            } else if prev.rsi > prev_rsi_sma && now.rsi <= rsi_sma {
                if let Some(v) = self.fact_cache.get("(crosses-below rsi rsi-sma)") { facts.push(v); labels.push("(crosses-below rsi rsi-sma)".into()); }
            }
        }
    }
}

// ─── ThoughtJournaler ───────────────────────────────────────────────────────

pub struct ThoughtPrediction {
    pub outcome: Option<Outcome>,
    pub coherence: f64,
    pub buy_coverage: f64,
    pub sell_coverage: f64,
    pub buy_atoms_found: usize,
    pub buy_atoms_total: usize,
    pub sell_atoms_found: usize,
    pub sell_atoms_total: usize,
    pub buy_sim: f64,
    pub sell_sim: f64,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Outcome {
    Buy,
    Sell,
    Noise,
}

impl std::fmt::Display for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Outcome::Buy => write!(f, "BUY"),
            Outcome::Sell => write!(f, "SELL"),
            Outcome::Noise => write!(f, "NOISE"),
        }
    }
}

pub struct DiscAtom {
    pub atom_vec: Vector,
    pub weight: f64,
    pub label: String,
}

pub struct ThoughtJournaler {
    pub buy_good: Accumulator,
    pub sell_good: Accumulator,
    updates: usize,
    recalib_interval: usize,
    pub dims: usize,
    pub noise_floor: f64,
    codebook_vecs: Vec<Vector>,
    codebook_labels: Vec<String>,
    pub disc_buy_atoms: Vec<DiscAtom>,
    pub disc_sell_atoms: Vec<DiscAtom>,
    pub disc_proj_atoms: Vec<DiscAtom>,
    pub proj_used: usize,
    pub proj_skipped: usize,
}

impl ThoughtJournaler {
    pub fn new(dims: usize, recalib_interval: usize) -> Self {
        let noise_floor = 1.0 / (dims as f64).sqrt();
        Self {
            buy_good: Accumulator::new(dims),
            sell_good: Accumulator::new(dims),
            updates: 0,
            recalib_interval,
            dims,
            noise_floor,
            codebook_vecs: Vec::new(),
            codebook_labels: Vec::new(),
            disc_buy_atoms: Vec::new(),
            disc_sell_atoms: Vec::new(),
            disc_proj_atoms: Vec::new(),
            proj_used: 0,
            proj_skipped: 0,
        }
    }

    pub fn set_codebook(&mut self, codebook: &FactCodebook) {
        self.codebook_vecs = codebook.vectors.clone();
        self.codebook_labels = codebook.labels.clone();
    }

    pub fn is_ready(&self) -> bool {
        self.buy_good.count() > 0 && self.sell_good.count() > 0
    }

    pub fn predict(&self, thought: &ThoughtResult) -> ThoughtPrediction {
        let coherence = thought.coherence;
        let no_pred = ThoughtPrediction {
            outcome: None, coherence,
            buy_coverage: 0.0, sell_coverage: 0.0,
            buy_atoms_found: 0, buy_atoms_total: 0,
            sell_atoms_found: 0, sell_atoms_total: 0,
            buy_sim: 0.0, sell_sim: 0.0,
        };

        if !self.is_ready() { return no_pred; }

        let has_buy = !self.disc_buy_atoms.is_empty();
        let has_sell = !self.disc_sell_atoms.is_empty();
        if !has_buy && !has_sell { return no_pred; }

        let (buy_cov, buy_found, buy_total) = disc_coverage(&thought.thought, &self.disc_buy_atoms, self.noise_floor);
        let (sell_cov, sell_found, sell_total) = disc_coverage(&thought.thought, &self.disc_sell_atoms, self.noise_floor);

        let outcome = if has_buy && has_sell {
            if buy_cov > sell_cov { Some(Outcome::Buy) } else { Some(Outcome::Sell) }
        } else if has_buy && buy_cov > 0.0 {
            Some(Outcome::Buy)
        } else if has_sell && sell_cov > 0.0 {
            Some(Outcome::Sell)
        } else {
            None
        };

        ThoughtPrediction {
            outcome, coherence,
            buy_coverage: buy_cov, sell_coverage: sell_cov,
            buy_atoms_found: buy_found, buy_atoms_total: buy_total,
            sell_atoms_found: sell_found, sell_atoms_total: sell_total,
            buy_sim: buy_cov, sell_sim: sell_cov,
        }
    }

    pub fn decay_all(&mut self, decay: f64) {
        self.buy_good.decay(decay);
        self.sell_good.decay(decay);
    }

    pub fn observe(
        &mut self,
        thought: &Vector,
        outcome: Outcome,
        signal_weight: f64,
    ) {
        if outcome == Outcome::Noise { return; }

        self.updates += 1;
        if self.updates % self.recalib_interval == 0 {
            self.recalibrate();
        }

        let learn_vec = self.project_contrastive(thought, outcome);
        let target = learn_vec.as_ref().unwrap_or(thought);
        if learn_vec.is_some() { self.proj_used += 1; } else { self.proj_skipped += 1; }

        match outcome {
            Outcome::Buy => self.buy_good.add_weighted(target, signal_weight),
            Outcome::Sell => self.sell_good.add_weighted(target, signal_weight),
            _ => {}
        }
    }

    fn project_contrastive(&self, input: &Vector, outcome: Outcome) -> Option<Vector> {
        if !self.is_ready() { return None; }
        let opposing = match outcome {
            Outcome::Buy => self.sell_good.threshold(),
            Outcome::Sell => self.buy_good.threshold(),
            _ => return None,
        };
        let data: Vec<i8> = input.data().iter().zip(opposing.data().iter())
            .map(|(&v, &p)| if v != p { v } else { 0 })
            .collect();
        Some(Vector::from_data(data))
    }

    fn recalibrate(&mut self) {
        if !self.is_ready() { return; }
        let buy_proto = self.buy_good.threshold();
        let sell_proto = self.sell_good.threshold();

        let buy_entropy = Primitives::entropy(&buy_proto);
        let sell_entropy = Primitives::entropy(&sell_proto);
        let min_entropy = buy_entropy.min(sell_entropy).max(0.01);
        let d_eff = self.dims as f64 * min_entropy;
        let new_floor = 1.0 / d_eff.sqrt();
        self.noise_floor = self.noise_floor.max(new_floor);

        let source_buy_f64 = self.buy_good.normalize_f64();
        let source_sell_f64 = self.sell_good.normalize_f64();

        if self.codebook_vecs.is_empty() { return; }

        let buy_atoms = invert_f64(&source_buy_f64, &self.codebook_vecs, 20);
        let sell_atoms = invert_f64(&source_sell_f64, &self.codebook_vecs, 20);

        let atom_buy_sims: HashMap<usize, f64> = buy_atoms.into_iter().collect();
        let atom_sell_sims: HashMap<usize, f64> = sell_atoms.into_iter().collect();

        let all_atoms: HashSet<usize> = atom_buy_sims.keys()
            .chain(atom_sell_sims.keys()).copied().collect();

        let mut new_buy_atoms: Vec<DiscAtom> = Vec::new();
        let mut new_sell_atoms: Vec<DiscAtom> = Vec::new();

        for idx in all_atoms {
            let bs = atom_buy_sims.get(&idx).copied().unwrap_or(0.0);
            let ss = atom_sell_sims.get(&idx).copied().unwrap_or(0.0);
            let diff = bs - ss;
            let label = if idx < self.codebook_labels.len() {
                self.codebook_labels[idx].clone()
            } else {
                format!("atom-{}", idx)
            };
            if diff > 0.0 {
                new_buy_atoms.push(DiscAtom {
                    atom_vec: self.codebook_vecs[idx].clone(),
                    weight: diff,
                    label,
                });
            } else if diff < 0.0 {
                new_sell_atoms.push(DiscAtom {
                    atom_vec: self.codebook_vecs[idx].clone(),
                    weight: diff.abs(),
                    label,
                });
            }
        }

        self.disc_buy_atoms = new_buy_atoms;
        self.disc_sell_atoms = new_sell_atoms;

        // Build capped projection list: top atoms covering 90% of total weight
        let mut all_proj: Vec<(&Vector, f64)> = self.disc_buy_atoms.iter()
            .chain(self.disc_sell_atoms.iter())
            .map(|a| (&a.atom_vec, a.weight))
            .collect();
        all_proj.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let total_w: f64 = all_proj.iter().map(|(_, w)| w).sum();
        let target_w = total_w * 0.90;
        let mut cum_w = 0.0;
        let mut kept = 0usize;
        self.disc_proj_atoms = Vec::new();
        for (vec, w) in &all_proj {
            if cum_w >= target_w { break; }
            self.disc_proj_atoms.push(DiscAtom {
                atom_vec: (*vec).clone(),
                weight: *w,
                label: String::new(),
            });
            cum_w += w;
            kept += 1;
        }

        eprintln!("      tht weight dist: total={:.4} | proj={} of {} atoms",
            total_w, kept, all_proj.len());
    }
}

// ─── Fact Codebook (for debug interface) ─────────────────────────────────────

pub struct FactCodebook {
    pub vectors: Vec<Vector>,
    pub labels: Vec<String>,
}

impl FactCodebook {
    /// Build a codebook of common fact vectors for debug decoding.
    pub fn build(vocab: &ThoughtVocab) -> Self {
        let mut vectors = Vec::new();
        let mut labels = Vec::new();

        // Comparison facts
        for &(a, b) in COMPARISON_PAIRS {
            for &pred in &["above", "below"] {
                vectors.push(fact_binary(vocab, pred, a, b));
                labels.push(format!("({} {} {})", pred, a, b));
            }
        }

        // Zone facts (from segment boundary checks)
        let mut seen_zones = std::collections::HashSet::new();
        for &(_stream, ind, zone, _check) in STREAM_ZONE_CHECKS {
            let key = format!("(at {} {})", ind, zone);
            if seen_zones.insert(key.clone()) {
                vectors.push(fact_binary(vocab, "at", ind, zone));
                labels.push(key);
            }
        }

        // RSI SMA
        vectors.push(fact_binary(vocab, "above", "rsi", "rsi-sma"));
        labels.push("(above rsi rsi-sma)".into());
        vectors.push(fact_binary(vocab, "below", "rsi", "rsi-sma"));
        labels.push("(below rsi rsi-sma)".into());

        FactCodebook { vectors, labels }
    }

    pub fn decode(&self, thought: &Vector, top_k: usize, threshold: f64) -> Vec<(String, f64)> {
        let results = Primitives::invert(thought, &self.vectors, top_k, threshold);
        results.into_iter()
            .map(|(idx, sim)| (self.labels[idx].clone(), sim))
            .collect()
    }
}
