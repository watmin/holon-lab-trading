pub mod pelt;

use std::collections::HashMap;

use holon::{
    Primitives, ScalarEncoder, ScalarMode,
    Vector, VectorManager,
};

use crate::candle::Candle;
use pelt::{pelt_changepoints, bic_penalty, most_recent_segment_dir};


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
    "entropy-rate",               // Sequential entropy (linguistics)
    "gr-bvalue",                  // Gutenberg-Richter b-value (seismology)
    // vocab/oscillators module
    "williams-r",                 // Williams %R
    "stoch-rsi",                  // Stochastic RSI
    "ult-osc",                    // Ultimate Oscillator
    "roc-5", "roc-10", "roc-20", // Multi-timeframe ROC
    "roc-accelerating", "roc-decelerating",
    // vocab/flow module
    "vwap",                       // Volume Weighted Average Price
    "mfi",                        // Money Flow Index
    "buy-pressure", "sell-pressure", "body-ratio",
    "divergence",                 // generic divergence atom (used with OBV)
    // vocab/persistence module
    "hurst",                      // Hurst exponent
    "autocorr",                   // lag-1 autocorrelation
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
    // vocab/oscillators zones
    "williams-overbought", "williams-oversold",
    "stoch-rsi-overbought", "stoch-rsi-oversold",
    "ult-osc-overbought", "ult-osc-oversold",
    // vocab/flow zones
    "mfi-overbought", "mfi-oversold",
    // vocab/persistence zones
    "hurst-trending", "hurst-reverting",
    "autocorr-positive", "autocorr-negative",
    "moderate-trend",
    // Risk / portfolio state
    "drawdown", "drawdown-shallow", "drawdown-moderate", "drawdown-deep", "drawdown-at-peak",
    "streak", "streak-winning", "streak-losing", "streak-long", "streak-short",
    "recent-accuracy", "accuracy-hot", "accuracy-cold", "accuracy-normal",
    "equity-curve", "equity-rising", "equity-falling", "equity-flat",
    "trade-frequency", "overtrading", "undertrading",
    // Expert-state atoms
    "expert-confident", "expert-uncertain",
    "expert-agreement", "experts-agree", "experts-disagree",
    "market-conviction", "conviction-extreme", "conviction-moderate", "conviction-weak",
    "trade-density", "density-high", "density-low", "density-normal",
    // Drawdown dynamics (Category 1)
    "dd-trivial", "dd-serious", "dd-extreme",
    "dd-velocity", "dd-accelerating", "dd-decelerating", "dd-stable-dd", "dd-recovering",
    "dd-duration", "dd-brief", "dd-medium-dur", "dd-extended", "dd-chronic",
    "dd-historical", "dd-normal-range", "dd-worst-quartile", "dd-unprecedented",
    // Win rate dynamics (Category 3)
    "acc-10", "acc-50", "acc-200",
    "acc-hot", "acc-warm", "acc-normal-acc", "acc-cool", "acc-cold",
    "acc-trajectory", "acc-improving", "acc-declining", "acc-stable-acc",
    "acc-divergence", "short-hot-long-cold", "short-cold-long-hot", "acc-aligned",
    // Return volatility (Category 4)
    "pnl-vol", "pnl-vol-low", "pnl-vol-medium", "pnl-vol-high", "pnl-vol-extreme",
    "trade-sharpe", "sharpe-excellent", "sharpe-good", "sharpe-mediocre", "sharpe-negative",
    "worst-trade", "worst-mild", "worst-moderate-wt", "worst-severe", "worst-catastrophic",
    // Loss correlation (Category 9)
    "loss-pattern", "losses-clustered", "losses-random", "losses-alternating",
    "loss-density", "ld-sparse", "ld-normal", "ld-dense", "ld-overwhelming",
    "consec-loss", "cl-none", "cl-short", "cl-medium", "cl-long",
    // Recovery dynamics (Category 7)
    "recovery-progress", "no-recovery", "early-recovery", "half-recovered", "nearly-recovered",
    "recovery-quality", "recovery-solid", "recovery-fragile", "recovery-volatile",
];
const PREDICATE_ATOMS: &[&str] = &[
    "above", "below", "crosses-above", "crosses-below",
    "touches", "bounces-off",
    "at", "since",
    "diverging", "confirming", "contradicting",
];
const SEGMENT_ATOMS: &[&str] = &["beginning", "ending"];
const CALENDAR_ATOMS: &[&str] = &[
    "hour-of-day", "day-of-week",
    "asian-session", "european-session", "us-session", "off-hours",
    "at-session",
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
    pub fact_labels: Vec<String>,
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

        // Pre-compute fibonacci comparison facts (touches/above/below close vs fib levels)
        for &fib in &["fib-236", "fib-382", "fib-500", "fib-618", "fib-786"] {
            for &pred in &["above", "below", "touches"] {
                let key = format!("({} close {})", pred, fib);
                let vec = fact_binary(&vocab, pred, "close", fib);
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

        // Pre-compute session facts (categorical — sessions have discrete character)
        for &session in &["asian-session", "european-session", "us-session", "off-hours"] {
            let key = format!("(at-session {})", session);
            fact_cache.insert(key, fact_binary(&vocab, "at-session", session, session));
        }
        // Hour and day use circular encoding now — computed live in eval_calendar,
        // not pre-cached. The discriminant learns proximity: hour 23 is near hour 0.

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
            // vocab/oscillators zones
            ("williams-r", "williams-overbought"), ("williams-r", "williams-oversold"),
            ("stoch-rsi", "stoch-rsi-overbought"), ("stoch-rsi", "stoch-rsi-oversold"),
            ("ult-osc", "ult-osc-overbought"), ("ult-osc", "ult-osc-oversold"),
            // vocab/flow zones
            ("mfi", "mfi-overbought"), ("mfi", "mfi-oversold"),
            // vocab/persistence zones
            ("hurst", "hurst-trending"), ("hurst", "hurst-reverting"),
            ("autocorr", "autocorr-positive"), ("autocorr", "autocorr-negative"),
            ("adx", "moderate-trend"),
            ("kama-er", "moderate-efficiency"),
        ] {
            let key = format!("(at {} {})", ind, zone);
            if !fact_cache.contains_key(&key) {
                fact_cache.insert(key, fact_binary(&vocab, "at", ind, zone));
            }
        }

        Self { vocab, scalar_enc: ScalarEncoder::new(dims), fact_cache }
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

    /// Render vocab module facts into vectors. The ONE method that turns
    /// any module's output into geometry. Modules return data. This renders it.
    pub fn encode_facts<'a>(
        &'a self,
        module_facts: &[crate::vocab::Fact],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        for fact in module_facts {
            match fact {
                crate::vocab::Fact::Zone { indicator, zone } => {
                    let key = format!("(at {} {})", indicator, zone);
                    if let Some(v) = self.fact_cache.get(&key) {
                        facts.push(v);
                        labels.push(key);
                    }
                }
                crate::vocab::Fact::Comparison { predicate, a, b } => {
                    let key = format!("({} {} {})", predicate, a, b);
                    if let Some(v) = self.fact_cache.get(&key) {
                        facts.push(v);
                        labels.push(key);
                    }
                }
                crate::vocab::Fact::Scalar { indicator, value, scale } => {
                    let v = self.scalar_enc.encode(*value, ScalarMode::Linear { scale: *scale });
                    let bound = Primitives::bind(self.vocab.get(indicator), &v);
                    labels.push(format!("({} {:.3})", indicator, value));
                    owned_facts.push(bound);
                }
                crate::vocab::Fact::Bare { label } => {
                    if let Some(v) = self.fact_cache.get(*label) {
                        facts.push(v);
                        labels.push(label.to_string());
                    } else {
                        // Try as a raw atom
                        let atom = self.vocab.get(label);
                        owned_facts.push(atom.clone());
                        labels.push(label.to_string());
                    }
                }
            }
        }
    }



    /// Expert profiles: which eval methods to run.
    /// "full" = all methods (generalist). Named profiles select subsets.
    /// Encode with a windowed view of the streams.
    /// `expert` selects which thought vocabulary to activate:
    ///   "full" = all, "momentum"/"structure"/"volume"/"narrative" = subsets.
    pub fn encode_view(
        &self,
        candles: &[Candle],
        vm: &VectorManager,
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

        // ── SHARED: comparisons (baseline for all experts) ────────────
        // Every expert needs price vs indicator relationships as context.
        if is(&["momentum", "structure", "volume", "narrative", "regime"]) {
            self.eval_comparisons_cached(now, prev, &mut cached_facts, &mut labels);
        }

        // ── EXCLUSIVE: momentum ─────────────────────────────────────
        // Oscillators, crosses, divergence. Speed and direction of change.
        if is(&["momentum"]) {
            self.eval_rsi_sma_cached(candles, &mut cached_facts, &mut labels);
            self.eval_stochastic(candles, &mut cached_facts, &mut owned_facts, &mut labels);
            self.eval_momentum(candles, &mut cached_facts, &mut owned_facts, &mut labels); // CCI, ROC
            self.eval_divergence(candles, vm, &mut owned_facts, &mut labels);
            // vocab/oscillators: Williams %R, Stochastic RSI, Ultimate Oscillator, multi-ROC
            self.eval_oscillators_module(candles, &mut cached_facts, &mut owned_facts, &mut labels);
        }

        // ── EXCLUSIVE: structure ────────────────────────────────────
        // Geometric shape: segments, levels, channels, cloud, fibs.
        if is(&["structure"]) {
            self.eval_segment_narrative(candles, vm, &mut owned_facts, &mut labels);
            self.eval_range_position(candles, &mut owned_facts, &mut labels);
            self.eval_ichimoku(candles, &mut cached_facts, &mut owned_facts, &mut labels);
            self.eval_fibonacci(candles, &mut cached_facts, &mut owned_facts, &mut labels);
            self.eval_keltner(candles, &mut cached_facts, &mut owned_facts, &mut labels);
        }

        // ── EXCLUSIVE: volume ───────────────────────────────────────
        // Participation: is the market backing the move?
        if is(&["volume"]) {
            self.eval_volume_confirmation(candles, &mut owned_facts, &mut labels);
            self.eval_volume_analysis(candles, &mut cached_facts, &mut labels);
            self.eval_price_action(candles, &mut cached_facts, &mut owned_facts, &mut labels);
            // vocab/flow: OBV, VWAP, MFI, buying/selling pressure
            self.eval_flow_module(candles, &mut cached_facts, &mut owned_facts, &mut labels);
        }

        // ── EXCLUSIVE: narrative ────────────────────────────────────
        // The story: what happened when. Calendar + temporal lookback.
        if is(&["narrative"]) {
            self.eval_temporal(candles, vm, &mut owned_facts, &mut labels);
            self.eval_calendar(now, &mut cached_facts, &mut owned_facts, &mut labels);
        }

        // ── EXCLUSIVE: regime ───────────────────────────────────────
        // Market character: trending/chaotic/persistent/mean-reverting.
        // Abstract properties that survive window noise.
        if is(&["regime"]) {
            self.eval_advanced(candles, &mut cached_facts, &mut owned_facts, &mut labels);
            // vocab/persistence: Hurst, autocorrelation, ADX zones
            self.eval_persistence_module(candles, &mut cached_facts, &mut owned_facts, &mut labels);
        }

        // Unify all facts into a single reference list for bundling.
        let mut all_refs: Vec<&Vector> = Vec::with_capacity(cached_facts.len() + owned_facts.len());
        all_refs.extend(cached_facts.iter().copied());
        all_refs.extend(owned_facts.iter());

        let thought = if all_refs.is_empty() {
            Vector::zeros(self.vocab.dims())
        } else {
            Primitives::bundle(&all_refs)
        };

        ThoughtResult { thought, fact_labels: labels }
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
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::market::{parse_candle_hour, parse_candle_day};

        // Hour and day: circular encoding. Hour 23 is near hour 0. Sunday near Monday.
        // The manager and observer agree on time — same functions, same encoding.
        let hour = parse_candle_hour(&now.ts);
        let day = parse_candle_day(&now.ts);

        let hour_vec = self.scalar_enc.encode(hour, ScalarMode::Circular { period: 24.0 });
        owned_facts.push(Primitives::bind(self.vocab.get("hour-of-day"), &hour_vec));
        labels.push(format!("(hour-of-day {:.0})", hour));

        let day_vec = self.scalar_enc.encode(day, ScalarMode::Circular { period: 7.0 });
        owned_facts.push(Primitives::bind(self.vocab.get("day-of-week"), &day_vec));
        labels.push(format!("(day-of-week {:.0})", day));

        // Trading session: categorical. Sessions have discrete character, not circular position.
        let session = Self::session_from_ts(&now.ts);
        if let Some(session) = session {
            let key = format!("(at-session {})", session);
            if let Some(v) = self.fact_cache.get(&key) {
                facts.push(v);
                labels.push(key);
            }
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
        use crate::vocab::divergence::eval_divergence;
        for div in eval_divergence(candles) {
            // bind(diverging, bind(bind(close, price_dir), bind(indicator, indicator_dir)))
            let price_fact = Primitives::bind(self.vocab.get("close"), self.vocab.get(div.price_dir));
            let ind_fact = Primitives::bind(self.vocab.get(div.indicator), self.vocab.get(div.indicator_dir));
            let div_fact = Primitives::bind(self.vocab.get("diverging"),
                &Primitives::bind(&price_fact, &ind_fact));
            let pos = vm.get_position_vector(div.candles_ago as i64);
            facts.push(Primitives::bind(&div_fact, &pos));
            labels.push(format!("(diverging close {} {} {} @{})",
                div.price_dir, div.indicator, div.indicator_dir, div.candles_ago));
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
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::ichimoku::eval_ichimoku;
        if let Some(ichi_facts) = eval_ichimoku(candles) {
            self.encode_facts(&ichi_facts, facts, owned_facts, labels);
        }
    }

    // ─── Stochastic Oscillator ───────────────────────────────────────────

    fn eval_stochastic<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::stochastic::eval_stochastic;
        if let Some(stoch_facts) = eval_stochastic(candles) {
            self.encode_facts(&stoch_facts, facts, owned_facts, labels);
        }
    }

    // ─── Fibonacci Retracement ───────────────────────────────────────────

    fn eval_fibonacci<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::fibonacci::eval_fibonacci;
        if let Some(fib_facts) = eval_fibonacci(candles) {
            self.encode_facts(&fib_facts, facts, owned_facts, labels);
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
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::keltner::eval_keltner;
        if let Some(kelt_facts) = eval_keltner(candles) {
            self.encode_facts(&kelt_facts, facts, owned_facts, labels);
        }
    }

    // ─── Momentum / ROC / CCI ────────────────────────────────────────────

    fn eval_momentum<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::momentum::eval_momentum;
        self.encode_facts(&eval_momentum(candles), facts, owned_facts, labels);
    }

    // ─── Price Action Patterns ───────────────────────────────────────────

    fn eval_price_action<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::price_action::eval_price_action;
        self.encode_facts(&eval_price_action(candles), facts, owned_facts, labels);
    }

    // ─── vocab/oscillators module ──────────────────────────────────────

    fn eval_oscillators_module<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::oscillators::eval_oscillators;
        self.encode_facts(&eval_oscillators(candles), facts, owned_facts, labels);
    }

    // ─── Advanced indicators (tier-1 underdogs + esoteric) ─────────────

    // ─── vocab/flow module ────────────────────────────────────────────

    fn eval_flow_module<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::flow::eval_flow;
        let (obv, flow_facts) = eval_flow(candles);

        // OBV direction: direct bind patterns that don't fit Fact variants
        if obv.obv_sign > 0.0 {
            owned_facts.push(self.vocab.get("obv").clone());
            labels.push("(obv rising)".to_string());
        } else if obv.obv_sign < 0.0 {
            owned_facts.push(Primitives::bind(self.vocab.get("obv"), self.vocab.get("down")));
            labels.push("(obv falling)".to_string());
        }
        if obv.obv_diverges {
            owned_facts.push(Primitives::bind(self.vocab.get("obv"), self.vocab.get("divergence")));
            labels.push("(obv divergence)".to_string());
        }

        self.encode_facts(&flow_facts, facts, owned_facts, labels);
    }

    // ─── vocab/persistence module ─────────────────────────────────────

    fn eval_persistence_module<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::persistence::eval_persistence;
        self.encode_facts(&eval_persistence(candles), facts, owned_facts, labels);
    }

    // ─── Advanced indicators (tier-1 underdogs + esoteric) ─────────────

    fn eval_advanced<'a>(
        &'a self,
        candles: &[Candle],
        facts: &mut Vec<&'a Vector>,
        owned_facts: &mut Vec<Vector>,
        labels: &mut Vec<String>,
    ) {
        use crate::vocab::regime::eval_regime;
        self.encode_facts(&eval_regime(candles), facts, owned_facts, labels);
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
