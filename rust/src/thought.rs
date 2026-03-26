use std::collections::{HashMap, HashSet};

use holon::{
    Accumulator, Primitives, ScalarEncoder,
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
];

const DIRECTION_ATOMS: &[&str] = &["up", "down", "flat"];
const ZONE_ATOMS: &[&str] = &[
    "overbought", "oversold", "neutral",
    "strong-trend", "weak-trend", "squeeze", "middle-zone",
    "above-midline", "below-midline", "positive", "negative",
];
const PREDICATE_ATOMS: &[&str] = &[
    "above", "below", "crosses-above", "crosses-below",
    "touches", "bounces-off",
    "at", "since",
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

        Self { vocab, scalar_enc: ScalarEncoder::new(dims), fact_cache }
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
        _streams: &IndicatorStreams,
        _stream_end: usize,
        _max_window: usize,
        vm: &VectorManager,
    ) -> ThoughtResult {
        let mut cached_facts: Vec<&Vector> = Vec::with_capacity(64);
        let mut owned_facts: Vec<Vector> = Vec::with_capacity(96);
        let mut labels: Vec<String> = Vec::with_capacity(96);

        let now = candles.last().unwrap();
        let prev = if candles.len() >= 2 { Some(&candles[candles.len() - 2]) } else { None };

        self.eval_comparisons_cached(now, prev, &mut cached_facts, &mut labels);
        self.eval_segment_narrative(candles, vm, &mut owned_facts, &mut labels);
        self.eval_temporal(candles, vm, &mut owned_facts, &mut labels);
        self.eval_rsi_sma_cached(candles, &mut cached_facts, &mut labels);
        self.eval_calendar(now, &mut cached_facts, &mut labels);

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
