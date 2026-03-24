use std::collections::HashMap;

use holon::{
    Accumulator, Primitives, ScalarEncoder, ScalarMode, SegmentMethod,
    Similarity, Vector, VectorManager,
};

use crate::db::Candle;

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
];

const DIRECTION_ATOMS: &[&str] = &["up", "down", "flat"];
const SCALE_ATOMS: &[&str] = &["micro", "short", "major"];
const INTENSITY_ATOMS: &[&str] = &["low", "medium", "high"];
const ZONE_ATOMS: &[&str] = &[
    "overbought", "oversold", "neutral",
    "strong-trend", "weak-trend", "squeeze", "middle-zone",
    "above-midline", "below-midline", "positive", "negative",
];
const PREDICATE_ATOMS: &[&str] = &[
    "above", "below", "crosses-above", "crosses-below",
    "touches", "bounces-off",
    "trending", "at", "reversal", "continuation", "diverging", "since",
];

const ALL_ATOM_GROUPS: &[&[&str]] = &[
    INDICATOR_ATOMS,
    DIRECTION_ATOMS,
    SCALE_ATOMS,
    INTENSITY_ATOMS,
    ZONE_ATOMS,
    PREDICATE_ATOMS,
];

// Indicators used for stream-based trend/reversal detection
const STREAM_INDICATORS: &[&str] = &["close", "rsi", "macd-hist", "bb-width", "adx"];

// Scale parameters: (name, segment window size)
const SCALES: &[(&str, usize)] = &[
    ("micro", 5),
    ("short", 10),
    ("major", 30),
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

/// Maintains rolling vector streams for each indicator to feed segment()/drift_rate().
pub struct IndicatorStreams {
    streams: HashMap<String, Vec<Vector>>,
    scalar_enc: ScalarEncoder,
    max_len: usize,
}

impl IndicatorStreams {
    pub fn new(dims: usize, max_len: usize) -> Self {
        let mut streams = HashMap::new();
        for &ind in STREAM_INDICATORS {
            streams.insert(ind.to_string(), Vec::with_capacity(max_len));
        }
        Self {
            streams,
            scalar_enc: ScalarEncoder::new(dims),
            max_len,
        }
    }

    pub fn push_candle(&mut self, candle: &Candle) {
        let pairs: [(&str, f64); 5] = [
            ("close", candle.close),
            ("rsi", candle.rsi),
            ("macd-hist", candle.macd_hist),
            ("bb-width", candle.bb_upper - candle.bb_lower),
            ("adx", candle.adx),
        ];

        for (name, value) in &pairs {
            let vec = if *name == "close" {
                self.scalar_enc.encode_log(value.max(1.0))
            } else {
                self.scalar_enc.encode(*value, ScalarMode::Linear { scale: 100.0 })
            };

            let stream = self.streams.get_mut(*name).unwrap();
            stream.push(vec);
            if stream.len() > self.max_len {
                stream.remove(0);
            }
        }
    }

    pub fn get_stream(&self, indicator: &str) -> &[Vector] {
        self.streams.get(indicator).map(|v| v.as_slice()).unwrap_or(&[])
    }

    /// Returns a windowed view of a stream: the last `max_window` entries ending at position `end`.
    pub fn get_stream_view(&self, indicator: &str, end: usize, max_window: usize) -> &[Vector] {
        let full = self.streams.get(indicator).map(|v| v.as_slice()).unwrap_or(&[]);
        let actual_end = end.min(full.len());
        let start = actual_end.saturating_sub(max_window);
        &full[start..actual_end]
    }

    pub fn len(&self) -> usize {
        self.streams.get("close").map(|v| v.len()).unwrap_or(0)
    }

    pub fn max_len_val(&self) -> usize {
        self.max_len
    }

    /// Temporarily raise the cap so batch pushes don't discard old entries.
    pub fn set_max_len(&mut self, new_max: usize) {
        self.max_len = new_max;
    }

    /// Remove excess entries from the front of each stream to fit max_len.
    pub fn trim_to_max(&mut self) {
        for stream in self.streams.values_mut() {
            let excess = stream.len().saturating_sub(self.max_len);
            if excess > 0 {
                stream.drain(..excess);
            }
        }
    }
}

// ─── Fact composition helpers ───────────────────────────────────────────────

/// Binary predicate: (pred a b) → bind(V("pred"), bind(V("a"), V("b")))
fn fact_binary(vocab: &ThoughtVocab, pred: &str, a: &str, b: &str) -> Vector {
    let ab = Primitives::bind(vocab.get(a), vocab.get(b));
    Primitives::bind(vocab.get(pred), &ab)
}

/// Ternary: (pred a b c) → bind(V("pred"), bind(V("a"), bind(V("b"), V("c"))))
fn fact_ternary(vocab: &ThoughtVocab, pred: &str, a: &str, b: &str, c: &str) -> Vector {
    let bc = Primitives::bind(vocab.get(b), vocab.get(c));
    let abc = Primitives::bind(vocab.get(a), &bc);
    Primitives::bind(vocab.get(pred), &abc)
}

/// Quaternary: (pred a b c d) → bind(V("pred"), bind(V("a"), bind(V("b"), bind(V("c"), V("d")))))
fn fact_quaternary(vocab: &ThoughtVocab, pred: &str, a: &str, b: &str, c: &str, d: &str) -> Vector {
    let cd = Primitives::bind(vocab.get(c), vocab.get(d));
    let bcd = Primitives::bind(vocab.get(b), &cd);
    let abcd = Primitives::bind(vocab.get(a), &bcd);
    Primitives::bind(vocab.get(pred), &abcd)
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
];

pub struct ThoughtEncoder {
    vocab: ThoughtVocab,
    fact_cache: HashMap<String, Vector>,
}

impl ThoughtEncoder {
    pub fn new(vocab: ThoughtVocab) -> Self {
        let mut fact_cache = HashMap::new();

        // Pre-compute comparison facts
        for &(a, b) in COMPARISON_PAIRS {
            for &pred in &["above", "below", "crosses-above", "crosses-below", "touches", "bounces-off"] {
                let key = format!("({} {} {})", pred, a, b);
                let vec = fact_binary(&vocab, pred, a, b);
                fact_cache.insert(key, vec);
            }
        }

        // Pre-compute zone facts
        let zone_checks: &[(&str, &str)] = &[
            ("rsi", "overbought"), ("rsi", "oversold"), ("rsi", "neutral"),
            ("adx", "strong-trend"), ("adx", "weak-trend"),
            ("bb-width", "squeeze"), ("close", "middle-zone"),
            ("rsi", "above-midline"), ("rsi", "below-midline"),
            ("macd-line", "positive"), ("macd-line", "negative"),
            ("macd-hist", "positive"), ("macd-hist", "negative"),
        ];
        for &(ind, zone) in zone_checks {
            let key = format!("(at {} {})", ind, zone);
            fact_cache.insert(key, fact_binary(&vocab, "at", ind, zone));
        }

        // Pre-compute trending facts
        for &ind in STREAM_INDICATORS {
            for &dir in &["up", "down", "flat"] {
                for &scale in &["micro", "short", "major"] {
                    for &intensity in &["low", "medium", "high"] {
                        let key = format!("(trending {} {} {} {})", ind, dir, scale, intensity);
                        fact_cache.insert(key, fact_quaternary(&vocab, "trending", ind, dir, scale, intensity));
                    }
                }
            }
        }

        // Pre-compute reversal/continuation facts
        for &ind in STREAM_INDICATORS {
            for &dir in &["up", "down"] {
                for &scale in &["micro", "short", "major"] {
                    let rkey = format!("(reversal {} {} {})", ind, dir, scale);
                    fact_cache.insert(rkey, fact_ternary(&vocab, "reversal", ind, dir, scale));
                    let ckey = format!("(continuation {} {} {})", ind, dir, scale);
                    fact_cache.insert(ckey, fact_ternary(&vocab, "continuation", ind, dir, scale));
                }
            }
        }

        // Pre-compute divergence facts
        for &close_dir in &["up", "down"] {
            for &(indicator, _) in &[("rsi", 10), ("macd-hist", 10), ("adx", 10)] {
                for &ind_dir in &["up", "down"] {
                    if ind_dir != close_dir {
                        let key = format!("(diverging close {} {} {})", close_dir, indicator, ind_dir);
                        fact_cache.insert(key, fact_quaternary(&vocab, "diverging", "close", close_dir, indicator, ind_dir));
                    }
                }
            }
        }

        // Pre-compute RSI SMA facts
        for &pred in &["above", "below", "crosses-above", "crosses-below"] {
            let key = format!("({} rsi rsi-sma)", pred);
            fact_cache.insert(key, fact_binary(&vocab, pred, "rsi", "rsi-sma"));
        }

        Self { vocab, fact_cache }
    }

    pub fn vocab(&self) -> &ThoughtVocab {
        &self.vocab
    }

    pub fn encode(
        &self,
        candles: &[Candle],
        streams: &IndicatorStreams,
        vm: &VectorManager,
    ) -> ThoughtResult {
        self.encode_view(candles, streams, usize::MAX, streams.max_len_val(), vm)
    }

    /// Encode with a windowed view of the streams — enables batch-parallel encoding
    /// where each candle sees only the stream entries up to its position.
    pub fn encode_view(
        &self,
        candles: &[Candle],
        streams: &IndicatorStreams,
        stream_end: usize,
        max_window: usize,
        vm: &VectorManager,
    ) -> ThoughtResult {
        let mut cached_facts: Vec<&Vector> = Vec::with_capacity(64);
        let mut owned_facts: Vec<Vector> = Vec::new();
        let mut labels: Vec<String> = Vec::with_capacity(64);

        let now = candles.last().unwrap();
        let prev = if candles.len() >= 2 { Some(&candles[candles.len() - 2]) } else { None };

        // Pre-compute segments once for both trends and reversals
        let mut segment_cache: HashMap<(&str, &str), Vec<usize>> = HashMap::new();
        for &indicator in STREAM_INDICATORS {
            let stream = streams.get_stream_view(indicator, stream_end, max_window);
            if stream.len() < 5 { continue; }
            for &(scale_name, window) in SCALES {
                if stream.len() < window + 2 { continue; }
                let segments = Primitives::segment(stream, window, 0.3, SegmentMethod::Diff);
                segment_cache.insert((indicator, scale_name), segments);
            }
        }

        self.eval_comparisons_cached(now, prev, &mut cached_facts, &mut labels);
        self.eval_zones_cached(now, &mut cached_facts, &mut labels);
        self.eval_trends_view(streams, stream_end, max_window, &segment_cache, &mut cached_facts, &mut labels);
        self.eval_reversals_view(streams, stream_end, max_window, &segment_cache, &mut cached_facts, &mut labels);
        self.eval_divergence_view(streams, stream_end, max_window, &mut cached_facts, &mut labels);
        self.eval_temporal(candles, vm, &mut owned_facts, &mut labels);
        self.eval_rsi_sma_cached(candles, &mut cached_facts, &mut labels);

        let fact_count = cached_facts.len() + owned_facts.len();
        let thought = if fact_count == 0 {
            Vector::zeros(self.vocab.dims())
        } else {
            let mut all_refs: Vec<&Vector> = cached_facts.iter().copied().collect();
            all_refs.extend(owned_facts.iter());
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

    // ─── Zone predicates (cached) ────────────────────────────────────────

    fn eval_zones_cached<'a>(
        &'a self,
        now: &Candle,
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let zone = if now.rsi > 70.0 { Some("(at rsi overbought)") }
            else if now.rsi < 30.0 { Some("(at rsi oversold)") }
            else { Some("(at rsi neutral)") };
        if let Some(key) = zone {
            if let Some(v) = self.fact_cache.get(key) { facts.push(v); labels.push(key.into()); }
        }

        if now.adx > 25.0 {
            if let Some(v) = self.fact_cache.get("(at adx strong-trend)") { facts.push(v); labels.push("(at adx strong-trend)".into()); }
        } else if now.adx < 20.0 {
            if let Some(v) = self.fact_cache.get("(at adx weak-trend)") { facts.push(v); labels.push("(at adx weak-trend)".into()); }
        }

        let bb_width = now.bb_upper - now.bb_lower;
        if bb_width > 0.0 && bb_width < now.close * 0.01 {
            if let Some(v) = self.fact_cache.get("(at bb-width squeeze)") { facts.push(v); labels.push("(at bb-width squeeze)".into()); }
        }

        if now.close > now.bb_lower && now.close < now.bb_upper && now.bb_upper > 0.0 {
            if let Some(v) = self.fact_cache.get("(at close middle-zone)") { facts.push(v); labels.push("(at close middle-zone)".into()); }
        }

        if now.rsi > 50.0 {
            if let Some(v) = self.fact_cache.get("(at rsi above-midline)") { facts.push(v); labels.push("(at rsi above-midline)".into()); }
        } else if now.rsi > 0.0 {
            if let Some(v) = self.fact_cache.get("(at rsi below-midline)") { facts.push(v); labels.push("(at rsi below-midline)".into()); }
        }

        if now.macd_line > 0.0 {
            if let Some(v) = self.fact_cache.get("(at macd-line positive)") { facts.push(v); labels.push("(at macd-line positive)".into()); }
        } else if now.macd_line < 0.0 {
            if let Some(v) = self.fact_cache.get("(at macd-line negative)") { facts.push(v); labels.push("(at macd-line negative)".into()); }
        }

        if now.macd_hist > 0.0 {
            if let Some(v) = self.fact_cache.get("(at macd-hist positive)") { facts.push(v); labels.push("(at macd-hist positive)".into()); }
        } else if now.macd_hist < 0.0 {
            if let Some(v) = self.fact_cache.get("(at macd-hist negative)") { facts.push(v); labels.push("(at macd-hist negative)".into()); }
        }
    }

    // ─── Trend detection (view-aware) ───────────────────────────────────

    fn eval_trends_view<'a>(
        &'a self,
        streams: &IndicatorStreams,
        stream_end: usize,
        max_window: usize,
        _segment_cache: &HashMap<(&str, &str), Vec<usize>>,
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        for &indicator in STREAM_INDICATORS {
            let stream = streams.get_stream_view(indicator, stream_end, max_window);
            if stream.len() < 5 { continue; }

            for &(scale_name, window) in SCALES {
                if stream.len() < window + 2 { continue; }

                let drifts = Primitives::drift_rate(stream, window);
                let avg_drift = if drifts.is_empty() {
                    0.0
                } else {
                    let recent = &drifts[drifts.len().saturating_sub(3)..];
                    recent.iter().sum::<f64>() / recent.len() as f64
                };

                let n = stream.len();
                let recent_sim = if n >= 2 {
                    Similarity::cosine(&stream[n - 2], &stream[n - 1])
                } else {
                    0.0
                };

                let dir = if avg_drift < 0.01 { "flat" }
                    else if recent_sim > 0.5 { "up" }
                    else { "down" };

                let intensity = if avg_drift < 0.05 { "low" }
                    else if avg_drift < 0.15 { "medium" }
                    else { "high" };

                let key = format!("(trending {} {} {} {})", indicator, dir, scale_name, intensity);
                if let Some(v) = self.fact_cache.get(&key) {
                    facts.push(v);
                    labels.push(key);
                }
            }
        }
    }

    // ─── Reversal / Continuation (view-aware) ───────────────────────────

    fn eval_reversals_view<'a>(
        &'a self,
        streams: &IndicatorStreams,
        stream_end: usize,
        max_window: usize,
        segment_cache: &HashMap<(&str, &str), Vec<usize>>,
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        for &indicator in STREAM_INDICATORS {
            let stream = streams.get_stream_view(indicator, stream_end, max_window);
            if stream.len() < 5 { continue; }

            for &(scale_name, window) in SCALES {
                if stream.len() < window + 2 { continue; }

                let segments = match segment_cache.get(&(indicator, scale_name)) {
                    Some(s) => s,
                    None => continue,
                };

                if segments.len() >= 2 {
                    let last_boundary = segments[segments.len() - 1];
                    let recency = stream.len() - 1 - last_boundary;

                    if recency <= window {
                        let n = stream.len();
                        let seg_start_val = &stream[last_boundary.min(n - 1)];
                        let current_val = &stream[n - 1];
                        let sim = Similarity::cosine(seg_start_val, current_val);

                        let dir = if sim > 0.5 { "up" } else { "down" };
                        let key = format!("(reversal {} {} {})", indicator, dir, scale_name);
                        if let Some(v) = self.fact_cache.get(&key) {
                            facts.push(v);
                            labels.push(key);
                        }
                    } else {
                        let n = stream.len();
                        let early = &stream[n.saturating_sub(window)];
                        let current = &stream[n - 1];
                        let sim = Similarity::cosine(early, current);

                        let dir = if sim > 0.5 { "up" } else { "down" };
                        let key = format!("(continuation {} {} {})", indicator, dir, scale_name);
                        if let Some(v) = self.fact_cache.get(&key) {
                            facts.push(v);
                            labels.push(key);
                        }
                    }
                }
            }
        }
    }

    // ─── Divergence (view-aware) ──────────────────────────────────────────

    fn eval_divergence_view<'a>(
        &'a self,
        streams: &IndicatorStreams,
        stream_end: usize,
        max_window: usize,
        facts: &mut Vec<&'a Vector>,
        labels: &mut Vec<String>,
    ) {
        let close_dir = self.stream_direction_view(streams, stream_end, max_window, "close", 10);
        if close_dir == "flat" { return; }

        let opposites = [("rsi", 10), ("macd-hist", 10), ("adx", 10)];
        for &(indicator, window) in &opposites {
            let ind_dir = self.stream_direction_view(streams, stream_end, max_window, indicator, window);
            if ind_dir != "flat" && ind_dir != close_dir {
                let key = format!("(diverging close {} {} {})", close_dir, indicator, ind_dir);
                if let Some(v) = self.fact_cache.get(&key) {
                    facts.push(v);
                    labels.push(key);
                }
            }
        }
    }

    fn stream_direction_view(&self, streams: &IndicatorStreams, stream_end: usize, max_window: usize, indicator: &str, window: usize) -> &'static str {
        let stream = streams.get_stream_view(indicator, stream_end, max_window);
        if stream.len() < window + 2 { return "flat"; }

        let drifts = Primitives::drift_rate(stream, window);
        if drifts.is_empty() { return "flat"; }

        let recent = &drifts[drifts.len().saturating_sub(3)..];
        let avg = recent.iter().sum::<f64>() / recent.len() as f64;

        let n = stream.len();
        let sim = if n >= 2 {
            Similarity::cosine(&stream[n - 2], &stream[n - 1])
        } else {
            return "flat";
        };

        if avg < 0.01 {
            "flat"
        } else if sim > 0.5 {
            "up"
        } else {
            "down"
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

        let max_lookback = 12.min(candles.len() - 2);

        // Check for crosses in the recent past
        for n in 1..=max_lookback {
            let idx = candles.len() - 1 - n;
            let c = &candles[idx];
            let p = &candles[idx.saturating_sub(1)];

            // Golden/death cross lookback
            if p.sma50 > 0.0 && p.sma200 > 0.0 && c.sma50 > 0.0 && c.sma200 > 0.0 {
                if p.sma50 < p.sma200 && c.sma50 >= c.sma200 {
                    let base = fact_binary(&self.vocab, "crosses-above", "sma50", "sma200");
                    facts.push(fact_since(vm, &base, n));
                    labels.push(format!("(since (crosses-above sma50 sma200) {})", n));
                }
                if p.sma50 > p.sma200 && c.sma50 <= c.sma200 {
                    let base = fact_binary(&self.vocab, "crosses-below", "sma50", "sma200");
                    facts.push(fact_since(vm, &base, n));
                    labels.push(format!("(since (crosses-below sma50 sma200) {})", n));
                }
            }

            // MACD cross lookback
            if p.macd_line != 0.0 && c.macd_line != 0.0 {
                if p.macd_line < p.macd_signal && c.macd_line >= c.macd_signal {
                    let base = fact_binary(&self.vocab, "crosses-above", "macd-line", "macd-signal");
                    facts.push(fact_since(vm, &base, n));
                    labels.push(format!("(since (crosses-above macd-line macd-signal) {})", n));
                }
                if p.macd_line > p.macd_signal && c.macd_line <= c.macd_signal {
                    let base = fact_binary(&self.vocab, "crosses-below", "macd-line", "macd-signal");
                    facts.push(fact_since(vm, &base, n));
                    labels.push(format!("(since (crosses-below macd-line macd-signal) {})", n));
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
    pub conviction: f64,
    pub coherence: f64,
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

pub struct ThoughtJournaler {
    pub buy_good: Accumulator,
    pub sell_good: Accumulator,
    pub buy_confuser: Accumulator,
    pub sell_confuser: Accumulator,
    pub noise_accum: Accumulator,
    updates: usize,
    recalib_interval: usize,
    pub dims: usize,
    pub noise_floor: f64,
}

impl ThoughtJournaler {
    pub fn new(dims: usize, recalib_interval: usize) -> Self {
        let noise_floor = 1.0 / (dims as f64).sqrt();
        Self {
            buy_good: Accumulator::new(dims),
            sell_good: Accumulator::new(dims),
            buy_confuser: Accumulator::new(dims),
            sell_confuser: Accumulator::new(dims),
            noise_accum: Accumulator::new(dims),
            updates: 0,
            recalib_interval,
            dims,
            noise_floor,
        }
    }

    pub fn is_ready(&self) -> bool {
        self.buy_good.count() > 0 && self.sell_good.count() > 0
    }

    pub fn predict(&self, thought: &ThoughtResult) -> ThoughtPrediction {
        let coherence = thought.coherence;

        if !self.is_ready() {
            return ThoughtPrediction { outcome: None, conviction: 0.0, coherence };
        }

        let vec = &thought.thought;

        // Raw cosine prediction — prototypes already clean from learning
        let buy_f64 = self.buy_good.normalize_f64();
        let sell_f64 = self.sell_good.normalize_f64();

        let bs = cosine_f64_vs_vec(&buy_f64, vec);
        let ss = cosine_f64_vs_vec(&sell_f64, vec);
        let (is_buy, conviction) = (bs > ss, (bs - ss).abs());

        let outcome = if is_buy { Some(Outcome::Buy) } else { Some(Outcome::Sell) };
        ThoughtPrediction { outcome, conviction, coherence }
    }

    pub fn observe(
        &mut self,
        thought: &Vector,
        outcome: Outcome,
        prediction: Option<Outcome>,
        _conviction: f64,
        decay: f64,
        reward_weight: f64,
        correction_weight: f64,
        signal_weight: f64,
    ) {
        if outcome == Outcome::Noise {
            self.noise_accum.decay(decay);
            self.noise_accum.add_weighted(thought, signal_weight);
            return;
        }

        // Always count non-noise observations and recalibrate on schedule,
        // even if the sample is rejected by the recognition gate below.
        // This breaks the deadlock where frozen prototypes prevent recalibration.
        self.updates += 1;
        if self.updates % self.recalib_interval == 0 {
            self.recalibrate();
        }

        // Adaptive recognition gate: exploration rate scales with prototype convergence
        let cos_buy_sell = if self.is_ready() {
            let buy_f64 = self.buy_good.normalize_f64();
            let sell_f64 = self.sell_good.normalize_f64();
            let cos_bs = cosine_f64(&buy_f64, &sell_f64);

            let buy_sim = cosine_f64_vs_vec(&buy_f64, thought);
            let sell_sim = cosine_f64_vs_vec(&sell_f64, thought);
            if buy_sim.max(sell_sim) < self.noise_floor {
                let explore_interval = (1.0 / cos_bs.clamp(0.01, 1.0)) as usize;
                if self.updates % explore_interval.max(1) != 0 {
                    return;
                }
            }
            cos_bs
        } else {
            0.0
        };

        // Adaptive decay + separation gate
        let separation = 1.0 - cos_buy_sell;
        let effective_decay = 1.0 - (1.0 - decay) * separation;
        let sep_gate = separation.clamp(0.05, 1.0);

        // L1: Strip noise/background before accumulating.
        let noise_stripped = if self.noise_accum.count() > 0 {
            let noise_proto = self.noise_accum.threshold();
            Some(Primitives::negate(thought, &noise_proto))
        } else {
            None
        };
        let base_thought = noise_stripped.as_ref().unwrap_or(thought);

        // L2: Proportional contrastive stripping — strip rate equals cosine
        let strip_rate = cos_buy_sell.clamp(0.0, 1.0);
        let strip_interval = if strip_rate > 0.01 {
            (1.0 / strip_rate) as usize
        } else {
            usize::MAX
        };
        let do_contrastive = self.is_ready()
            && self.updates % strip_interval.max(1) == 0;
        match outcome {
            Outcome::Buy => {
                let add_thought = if do_contrastive {
                    let sell_proto = self.sell_good.threshold();
                    Primitives::negate(base_thought, &sell_proto)
                } else {
                    base_thought.clone()
                };
                self.buy_good.decay(effective_decay);
                self.sell_good.decay(effective_decay);
                self.buy_good.add_weighted(&add_thought, sep_gate * signal_weight);
            }
            Outcome::Sell => {
                let add_thought = if do_contrastive {
                    let buy_proto = self.buy_good.threshold();
                    Primitives::negate(base_thought, &buy_proto)
                } else {
                    base_thought.clone()
                };
                self.buy_good.decay(effective_decay);
                self.sell_good.decay(effective_decay);
                self.sell_good.add_weighted(&add_thought, sep_gate * signal_weight);
            }
            _ => {}
        }

        // Feed confuser if wrong
        if let Some(pred) = prediction {
            if pred != outcome && pred != Outcome::Noise {
                match pred {
                    Outcome::Buy => {
                        self.buy_confuser.decay(effective_decay);
                        self.buy_confuser.add_weighted(thought, signal_weight);
                    }
                    Outcome::Sell => {
                        self.sell_confuser.decay(effective_decay);
                        self.sell_confuser.add_weighted(thought, signal_weight);
                    }
                    _ => {}
                }
            }
        }

        // #3 Separation-gated algebraic correction (load-bearing path)
        if let Some(pred) = prediction {
            if pred != Outcome::Noise && self.is_ready() {
                let buy_proto = self.buy_good.threshold();
                let sell_proto = self.sell_good.threshold();

                let reward_weight = reward_weight * sep_gate;
                let correction_weight = correction_weight * sep_gate;

                let pred_matches = (pred == Outcome::Buy && outcome == Outcome::Buy)
                    || (pred == Outcome::Sell && outcome == Outcome::Sell);

                if pred_matches {
                    let (correct_proto, opposing_proto) = match outcome {
                        Outcome::Buy => (&buy_proto, &sell_proto),
                        _ => (&sell_proto, &buy_proto),
                    };
                    let aligned = Primitives::resonance(thought, correct_proto);
                    let reinforced = Primitives::amplify(&aligned, opposing_proto, 1.0);
                    let novelty = 1.0 - Similarity::cosine(&reinforced, thought).abs();
                    match outcome {
                        Outcome::Buy => self.buy_good.add_weighted(&reinforced, reward_weight * novelty * signal_weight),
                        _ => self.sell_good.add_weighted(&reinforced, reward_weight * novelty * signal_weight),
                    }
                } else {
                    let wrong_proto = match outcome {
                        Outcome::Buy => &sell_proto,
                        _ => &buy_proto,
                    };
                    let misleading = Primitives::resonance(thought, wrong_proto);
                    let unique = Primitives::negate(thought, &misleading);
                    let amplified = Primitives::grover_amplify(&unique, &misleading, 1);
                    let novelty = 1.0 - Similarity::cosine(&amplified, thought).abs();
                    match outcome {
                        Outcome::Buy => self.buy_good.add_weighted(&amplified, correction_weight * novelty * signal_weight),
                        _ => self.sell_good.add_weighted(&amplified, correction_weight * novelty * signal_weight),
                    }
                }
            }
        }

    }

    fn recalibrate(&mut self) {
        if !self.is_ready() { return; }
        let buy_proto = self.buy_good.threshold();
        let sell_proto = self.sell_good.threshold();

        // Derive recognition gate from prototype entropy
        let buy_entropy = Primitives::entropy(&buy_proto);
        let sell_entropy = Primitives::entropy(&sell_proto);
        let min_entropy = buy_entropy.min(sell_entropy).max(0.01);
        let d_eff = self.dims as f64 * min_entropy;
        let new_floor = 1.0 / d_eff.sqrt();
        self.noise_floor = self.noise_floor.max(new_floor);
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

        // Zone facts
        let zone_checks: &[(&str, &str)] = &[
            ("rsi", "overbought"), ("rsi", "oversold"), ("rsi", "neutral"),
            ("adx", "strong-trend"), ("adx", "weak-trend"),
            ("bb-width", "squeeze"), ("close", "middle-zone"),
            ("rsi", "above-midline"), ("rsi", "below-midline"),
            ("macd-line", "positive"), ("macd-line", "negative"),
            ("macd-hist", "positive"), ("macd-hist", "negative"),
        ];
        for &(ind, zone) in zone_checks {
            vectors.push(fact_binary(vocab, "at", ind, zone));
            labels.push(format!("(at {} {})", ind, zone));
        }

        // Trending facts (subset of common combinations)
        for &ind in STREAM_INDICATORS {
            for &dir in &["up", "down"] {
                for &scale in &["micro", "short", "major"] {
                    for &intensity in &["low", "medium", "high"] {
                        vectors.push(fact_quaternary(vocab, "trending", ind, dir, scale, intensity));
                        labels.push(format!("(trending {} {} {} {})", ind, dir, scale, intensity));
                    }
                }
            }
        }

        // Reversal / continuation facts
        for &ind in STREAM_INDICATORS {
            for &dir in &["up", "down"] {
                for &scale in &["micro", "short", "major"] {
                    vectors.push(fact_ternary(vocab, "reversal", ind, dir, scale));
                    labels.push(format!("(reversal {} {} {})", ind, dir, scale));
                    vectors.push(fact_ternary(vocab, "continuation", ind, dir, scale));
                    labels.push(format!("(continuation {} {} {})", ind, dir, scale));
                }
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
