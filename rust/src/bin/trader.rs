use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use rusqlite::{Connection, params};
use holon::{Accumulator, AttendMode, Primitives, Similarity, VectorManager, Vector};

use btc_walk::db::load_candles;
use btc_walk::thought::{
    self, ThoughtVocab, ThoughtEncoder, ThoughtJournaler,
    IndicatorStreams, FactCodebook,
};
use btc_walk::viewport::{render_viewport, build_viewport, build_null_template, raster_encode, raster_encode_cached, VisualCache};

// ─── CLI ────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "trader", about = "Self-supervised BTC trader with Journaler + Trader agents")]
struct Args {
    #[arg(long, default_value = "../data/analysis.db")]
    db_path: PathBuf,

    #[arg(long, default_value_t = 10000)]
    dims: usize,

    #[arg(long, default_value_t = 48)]
    window: usize,

    #[arg(long, default_value_t = 25)]
    px_rows: usize,

    /// Candles to wait before measuring price outcome
    #[arg(long, default_value_t = 36)]
    horizon: usize,

    /// Price change threshold to label BUY/SELL (0.005 = 0.5%)
    #[arg(long, default_value_t = 0.005)]
    move_threshold: f64,

    #[arg(long, default_value_t = 0.999)]
    decay: f64,

    /// Candles in OBSERVE phase before predictions begin
    #[arg(long, default_value_t = 1000)]
    observe_period: usize,

    #[arg(long, default_value_t = 500)]
    recalib_interval: usize,

    #[arg(long, default_value_t = 1.0)]
    reward_weight: f64,

    #[arg(long, default_value_t = 1.5)]
    correction_weight: f64,

    #[arg(long, default_value_t = false)]
    use_grover: bool,

    #[arg(long, default_value_t = false)]
    use_attend: bool,

    #[arg(long, default_value_t = 10000.0)]
    initial_equity: f64,

    #[arg(long, default_value_t = 0)]
    max_candles: usize,

    #[arg(long, default_value_t = 256)]
    batch_size: usize,

    #[arg(long, default_value_t = 8)]
    threads: usize,

    /// Dummy label column for DB loader compatibility (ignored by trader)
    #[arg(long, default_value = "label_oracle_10")]
    label_col: String,

    /// Log decoded thought vectors at each checkpoint
    #[arg(long, default_value_t = false)]
    debug_thoughts: bool,

    /// Orchestration mode: visual-only, thought-only, agree-only, meta-boost, weighted
    #[arg(long, default_value = "meta-boost")]
    orchestration: String,
}

// ─── Outcome ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Debug)]
enum Outcome {
    Buy,
    Sell,
    Noise,
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Outcome::Buy => write!(f, "BUY"),
            Outcome::Sell => write!(f, "SELL"),
            Outcome::Noise => write!(f, "NOISE"),
        }
    }
}

// ─── Algebra helpers ────────────────────────────────────────────────────────

fn extract_features(vec: &Vector, reference: &Vector, use_attend: bool) -> Vector {
    if use_attend {
        Primitives::attend(vec, reference, 1.0, AttendMode::Soft)
    } else {
        Primitives::resonance(vec, reference)
    }
}

fn amplify_signal(signal: &Vector, background: &Vector, use_grover: bool) -> Vector {
    if use_grover {
        Primitives::grover_amplify(signal, background, 1)
    } else {
        Primitives::amplify(signal, background, 1.0)
    }
}

// ─── Prediction Detail ──────────────────────────────────────────────────────

#[derive(Clone)]
struct PredictionDetail {
    prediction: Option<Outcome>,
    conviction: f64,
    max_sim: f64,
    buy_sim: f64,
    sell_sim: f64,
    buy_confuser_sim: f64,
    sell_confuser_sim: f64,
    noise_sim: f64,
    noise_gated: bool,
    confuser_flipped: bool,
}

impl Default for PredictionDetail {
    fn default() -> Self {
        Self {
            prediction: None,
            conviction: 0.0,
            max_sim: 0.0,
            buy_sim: 0.0,
            sell_sim: 0.0,
            buy_confuser_sim: 0.0,
            sell_confuser_sim: 0.0,
            noise_sim: 0.0,
            noise_gated: false,
            confuser_flipped: false,
        }
    }
}

// ─── Journaler ──────────────────────────────────────────────────────────────

struct Journaler {
    buy_good: Accumulator,
    sell_good: Accumulator,
    buy_confuser: Accumulator,
    sell_confuser: Accumulator,
    noise_accum: Accumulator,
    buy_disc: Option<Vector>,
    sell_disc: Option<Vector>,
    updates: usize,
    recalib_interval: usize,
    use_grover: bool,
    use_attend: bool,
    dims: usize,
    noise_floor: f64,
}

impl Journaler {
    fn new(dims: usize, recalib_interval: usize, use_grover: bool, use_attend: bool) -> Self {
        // 1/sqrt(D): standard deviation of cosine similarity between random
        // vectors in D dimensions. Below this, similarity is indistinguishable
        // from noise.
        let noise_floor = 1.0 / (dims as f64).sqrt();
        Self {
            buy_good: Accumulator::new(dims),
            sell_good: Accumulator::new(dims),
            buy_confuser: Accumulator::new(dims),
            sell_confuser: Accumulator::new(dims),
            noise_accum: Accumulator::new(dims),
            buy_disc: None,
            sell_disc: None,
            updates: 0,
            recalib_interval,
            use_grover,
            use_attend,
            dims,
            noise_floor,
        }
    }

    fn recognition_threshold(&self) -> f64 {
        self.noise_floor
    }

    fn is_ready(&self) -> bool {
        self.buy_good.count() > 0 && self.sell_good.count() > 0
    }

    fn predict(&self, vec: &Vector) -> PredictionDetail {
        if !self.is_ready() {
            return PredictionDetail::default();
        }

        let buy_proto = self.buy_disc.as_ref()
            .cloned()
            .unwrap_or_else(|| self.buy_good.threshold());
        let sell_proto = self.sell_disc.as_ref()
            .cloned()
            .unwrap_or_else(|| self.sell_good.threshold());

        let cleaned = if self.noise_accum.count() > 0 {
            let noise_proto = self.noise_accum.threshold();
            Primitives::negate(vec, &noise_proto)
        } else {
            vec.clone()
        };

        let buy_sim = Similarity::cosine(&cleaned, &buy_proto);
        let sell_sim = Similarity::cosine(&cleaned, &sell_proto);
        let max_sim = buy_sim.max(sell_sim);

        let noise_sim = if self.noise_accum.count() > 0 {
            Similarity::cosine(&cleaned, &self.noise_accum.threshold())
        } else {
            -1.0
        };

        if noise_sim > max_sim {
            return PredictionDetail {
                prediction: None,
                conviction: 0.0,
                max_sim,
                buy_sim,
                sell_sim,
                buy_confuser_sim: 0.0,
                sell_confuser_sim: 0.0,
                noise_sim,
                noise_gated: true,
                confuser_flipped: false,
            };
        }

        let buy_confuser_sim = if self.buy_confuser.count() > 0 {
            Similarity::cosine(&cleaned, &self.buy_confuser.threshold())
        } else {
            -1.0
        };
        let sell_confuser_sim = if self.sell_confuser.count() > 0 {
            Similarity::cosine(&cleaned, &self.sell_confuser.threshold())
        } else {
            -1.0
        };

        let buy_conviction = buy_sim - buy_confuser_sim;
        let sell_conviction = sell_sim - sell_confuser_sim;

        let raw_direction_buy = buy_sim > sell_sim;
        let adjusted_direction_buy = buy_conviction > sell_conviction;
        let confuser_flipped = raw_direction_buy != adjusted_direction_buy;

        let (prediction, conviction) = if adjusted_direction_buy {
            (Some(Outcome::Buy), buy_conviction)
        } else {
            (Some(Outcome::Sell), sell_conviction)
        };

        PredictionDetail {
            prediction,
            conviction,
            max_sim,
            buy_sim,
            sell_sim,
            buy_confuser_sim,
            sell_confuser_sim,
            noise_sim,
            noise_gated: false,
            confuser_flipped,
        }
    }

    fn observe(
        &mut self,
        vec: &Vector,
        outcome: Outcome,
        prediction: Option<Outcome>,
        conviction: f64,
        decay: f64,
        reward_weight: f64,
        correction_weight: f64,
    ) {
        let use_grover = self.use_grover;
        let use_attend = self.use_attend;

        // Confidence-gated learning: scale weights by prediction conviction.
        let gate = conviction.abs().clamp(0.3, 1.0);
        let reward_weight = reward_weight * gate;
        let correction_weight = correction_weight * gate;

        // Noise always gets learned (it's its own category)
        if outcome == Outcome::Noise {
            self.noise_accum.decay(decay);
            self.noise_accum.add(vec);
            return;
        }

        // Recognition rejection: skip learning if sample doesn't resemble any prototype.
        // Threshold is self-calibrated via accuracy-by-similarity-bucket tracking.
        if self.is_ready() {
            let buy_proto = self.buy_good.threshold();
            let sell_proto = self.sell_good.threshold();
            let buy_sim = Similarity::cosine(vec, &buy_proto);
            let sell_sim = Similarity::cosine(vec, &sell_proto);
            let max_sim = buy_sim.max(sell_sim);
            if max_sim < self.recognition_threshold() {
                return;
            }
        }

        match outcome {
            Outcome::Buy => {
                self.buy_good.decay(decay);
                self.sell_good.decay(decay);
                self.buy_good.add(vec);
            }
            Outcome::Sell => {
                self.buy_good.decay(decay);
                self.sell_good.decay(decay);
                self.sell_good.add(vec);
            }
            _ => {}
        }

        // Feed confuser if journaler predicted and was wrong
        if let Some(pred) = prediction {
            if pred != outcome && pred != Outcome::Noise {
                match pred {
                    Outcome::Buy => {
                        self.buy_confuser.decay(decay);
                        self.buy_confuser.add(vec);
                    }
                    Outcome::Sell => {
                        self.sell_confuser.decay(decay);
                        self.sell_confuser.add(vec);
                    }
                    _ => {}
                }
            }
        }

        // Algebraic correction gated by prototype separation.
        // When buy and sell prototypes converge (trending market),
        // corrections based on their relationship are noise — scale down.
        if let Some(pred) = prediction {
            if pred != Outcome::Noise && self.is_ready() {
                let buy_proto = self.buy_good.threshold();
                let sell_proto = self.sell_good.threshold();

                let separation = 1.0 - Similarity::cosine(&buy_proto, &sell_proto);
                let sep_gate = separation.clamp(0.05, 1.0);
                let reward_weight = reward_weight * sep_gate;
                let correction_weight = correction_weight * sep_gate;

                let pred_matches = (pred == Outcome::Buy && outcome == Outcome::Buy)
                    || (pred == Outcome::Sell && outcome == Outcome::Sell);

                if pred_matches {
                    let (correct_proto, opposing_proto) = match outcome {
                        Outcome::Buy => (&buy_proto, &sell_proto),
                        _ => (&sell_proto, &buy_proto),
                    };
                    let aligned = extract_features(vec, correct_proto, use_attend);
                    let reinforced = amplify_signal(&aligned, opposing_proto, use_grover);
                    match outcome {
                        Outcome::Buy => self.buy_good.add_weighted(&reinforced, reward_weight),
                        _ => self.sell_good.add_weighted(&reinforced, reward_weight),
                    }
                } else {
                    let wrong_proto = match outcome {
                        Outcome::Buy => &sell_proto,
                        _ => &buy_proto,
                    };
                    let misleading = extract_features(vec, wrong_proto, use_attend);
                    let unique = Primitives::negate(vec, &misleading);
                    let amplified = amplify_signal(&unique, &misleading, true);
                    match outcome {
                        Outcome::Buy => self.buy_good.add_weighted(&amplified, correction_weight),
                        _ => self.sell_good.add_weighted(&amplified, correction_weight),
                    }
                }
            }
        }

        self.updates += 1;
        if self.updates % self.recalib_interval == 0 {
            self.recalibrate();
        }
    }

    fn recalibrate(&mut self) {
        if !self.is_ready() {
            return;
        }
        let buy_proto = self.buy_good.threshold();
        let sell_proto = self.sell_good.threshold();
        let shared = Primitives::resonance(&buy_proto, &sell_proto);
        self.buy_disc = Some(Primitives::negate(&buy_proto, &shared));
        self.sell_disc = Some(Primitives::negate(&sell_proto, &shared));

        // Derive recognition gate from prototype structure:
        // entropy measures effective dimensionality usage (0..1),
        // noise_floor = 1/sqrt(D_eff) where D_eff = dims * entropy.
        // Use the sparser prototype (lower entropy → higher noise_floor)
        // to avoid gating out the less-developed side.
        let buy_entropy = Primitives::entropy(&buy_proto);
        let sell_entropy = Primitives::entropy(&sell_proto);
        let min_entropy = buy_entropy.min(sell_entropy).max(0.01);
        let d_eff = self.dims as f64 * min_entropy;
        self.noise_floor = 1.0 / d_eff.sqrt();
    }
}

// ─── Trader ─────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Observe,
    Tentative,
    Confident,
}

impl fmt::Display for Phase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Phase::Observe => write!(f, "OBSERVE"),
            Phase::Tentative => write!(f, "TENTATIVE"),
            Phase::Confident => write!(f, "CONFIDENT"),
        }
    }
}

#[derive(Default)]
struct YearStats {
    trades: usize,
    wins: usize,
    pnl: f64,
}

struct Trader {
    rolling_results: VecDeque<bool>,
    rolling_cap: usize,
    equity: f64,
    trades_taken: usize,
    trades_won: usize,
    trades_skipped: usize,
    by_year: HashMap<i32, YearStats>,
    phase: Phase,
    observe_remaining: usize,
}

impl Trader {
    fn new(initial_equity: f64, observe_period: usize) -> Self {
        Self {
            rolling_results: VecDeque::new(),
            rolling_cap: 500,
            equity: initial_equity,
            trades_taken: 0,
            trades_won: 0,
            trades_skipped: 0,
            by_year: HashMap::new(),
            phase: Phase::Observe,
            observe_remaining: observe_period,
        }
    }

    fn rolling_accuracy(&self) -> f64 {
        if self.rolling_results.is_empty() {
            return 0.0;
        }
        let correct = self.rolling_results.iter().filter(|&&x| x).count();
        correct as f64 / self.rolling_results.len() as f64
    }

    fn confidence(&self) -> f64 {
        self.rolling_accuracy() - 0.5
    }

    fn should_trade(&self, conviction: f64) -> Option<f64> {
        if self.phase == Phase::Observe {
            return None;
        }
        if conviction <= 0.0 {
            return None;
        }

        // During TENTATIVE, always trade at minimum size to build a track record
        if self.phase == Phase::Tentative {
            return Some(0.005);
        }

        // CONFIDENT: scale by confidence
        let conf = self.confidence();
        let position_frac = if conf < 0.0 {
            return None;
        } else if conf < 0.05 {
            0.005
        } else if conf < 0.10 {
            0.01
        } else {
            (conf * 0.10).min(0.02)
        };

        Some(position_frac)
    }

    fn record_trade(&mut self, pct_change: f64, position_frac: f64, direction: Outcome, year: i32) {
        let directed_change = match direction {
            Outcome::Buy => pct_change,
            Outcome::Sell => -pct_change,
            _ => return,
        };

        let trade_pnl = self.equity * position_frac * directed_change;
        let is_win = directed_change > 0.0;

        self.equity += trade_pnl;
        self.trades_taken += 1;
        if is_win {
            self.trades_won += 1;
        }

        self.rolling_results.push_back(is_win);
        if self.rolling_results.len() > self.rolling_cap {
            self.rolling_results.pop_front();
        }

        let ys = self.by_year.entry(year).or_default();
        ys.trades += 1;
        if is_win {
            ys.wins += 1;
        }
        ys.pnl += trade_pnl;

        self.check_phase_transition();
    }

    fn tick_observe(&mut self) {
        if self.phase == Phase::Observe && self.observe_remaining > 0 {
            self.observe_remaining -= 1;
            if self.observe_remaining == 0 {
                self.phase = Phase::Tentative;
            }
        }
    }

    fn check_phase_transition(&mut self) {
        let n = self.rolling_results.len();
        let acc = self.rolling_accuracy();

        match self.phase {
            Phase::Observe => {}
            Phase::Tentative => {
                if n >= 500 && acc > 0.52 {
                    self.phase = Phase::Confident;
                }
            }
            Phase::Confident => {
                if n >= 200 && acc < 0.50 {
                    self.phase = Phase::Tentative;
                }
            }
        }
    }

    fn win_rate(&self) -> f64 {
        if self.trades_taken == 0 {
            0.0
        } else {
            self.trades_won as f64 / self.trades_taken as f64 * 100.0
        }
    }
}

// ─── Pending Entry ──────────────────────────────────────────────────────────

struct TradeAction {
    direction: Outcome,
    position_frac: f64,
}

struct PendingEntry {
    candle_idx: usize,
    vec: Vector,
    journaler_prediction: Option<Outcome>,
    conviction: f64,
    max_sim: f64,
    trade_action: Option<TradeAction>,
    thought_vec: Vector,
    thought_prediction: Option<thought::Outcome>,
    thought_conviction: f64,
    vis_detail: PredictionDetail,
}

struct Resolution {
    outcome: Outcome,
    pct_change: f64,
}

/// Scan candles from entry+1 through entry+horizon for the first threshold hit.
/// Exit at the first candle that crosses the move threshold in either direction.
/// If neither threshold is hit, label as Noise.
fn resolve_outcome(
    candles: &[btc_walk::db::Candle],
    entry_idx: usize,
    horizon: usize,
    move_threshold: f64,
    total_candles: usize,
) -> Option<Resolution> {
    let max_idx = (entry_idx + horizon).min(total_candles - 1);
    if entry_idx + 1 > max_idx {
        return None;
    }

    let entry_price = candles[entry_idx].close;

    for k in 1..=(max_idx - entry_idx) {
        let pct = (candles[entry_idx + k].close - entry_price) / entry_price;
        if pct > move_threshold {
            return Some(Resolution { outcome: Outcome::Buy, pct_change: pct });
        } else if pct < -move_threshold {
            return Some(Resolution { outcome: Outcome::Sell, pct_change: pct });
        }
    }

    Some(Resolution { outcome: Outcome::Noise, pct_change: 0.0 })
}

// ─── Meta Orchestrator ───────────────────────────────────────────────────────

fn thought_to_outcome(t: thought::Outcome) -> Outcome {
    match t {
        thought::Outcome::Buy => Outcome::Buy,
        thought::Outcome::Sell => Outcome::Sell,
        thought::Outcome::Noise => Outcome::Noise,
    }
}

fn meta_orchestrate(
    mode: &str,
    visual_pred: Option<Outcome>,
    visual_conviction: f64,
    thought_pred: Option<thought::Outcome>,
    thought_conviction: f64,
    thought_coherence: f64,
    visual_rolling_acc: f64,
    thought_rolling_acc: f64,
) -> (Option<Outcome>, f64) {
    match mode {
        "visual-only" => (visual_pred, visual_conviction),

        "thought-only" => match thought_pred {
            Some(t) => (Some(thought_to_outcome(t)), thought_conviction),
            None => (None, 0.0),
        },

        "agree-only" => match (visual_pred, thought_pred) {
            (Some(v), Some(t)) => {
                let agree = (v == Outcome::Buy) == (t == thought::Outcome::Buy);
                if agree {
                    let combined = (visual_conviction + thought_conviction) / 2.0;
                    (Some(v), combined)
                } else {
                    (None, 0.0)
                }
            }
            _ => (None, 0.0),
        },

        "meta-boost" => match (visual_pred, thought_pred) {
            (Some(v), Some(t)) => {
                let v_is_buy = v == Outcome::Buy;
                let t_is_buy = t == thought::Outcome::Buy;
                if v_is_buy == t_is_buy {
                    let combined = (visual_conviction + thought_conviction) / 2.0;
                    let coherence_boost = 1.0 + thought_coherence.clamp(0.0, 0.5);
                    (Some(v), combined * coherence_boost)
                } else {
                    let (winner, conv) = if visual_conviction > thought_conviction {
                        (v, visual_conviction)
                    } else {
                        (thought_to_outcome(t), thought_conviction)
                    };
                    (Some(winner), conv * 0.5)
                }
            }
            (Some(v), None) => (Some(v), visual_conviction * 0.8),
            (None, Some(t)) => (Some(thought_to_outcome(t)), thought_conviction * 0.8),
            (None, None) => (None, 0.0),
        },

        "weighted" => match (visual_pred, thought_pred) {
            (Some(v), Some(t)) => {
                let v_weight = (visual_rolling_acc - 0.5).max(0.01);
                let t_weight = (thought_rolling_acc - 0.5).max(0.01);
                let total = v_weight + t_weight;
                let v_frac = v_weight / total;
                let t_frac = t_weight / total;

                let v_is_buy = v == Outcome::Buy;
                let t_is_buy = t == thought::Outcome::Buy;

                if v_is_buy == t_is_buy {
                    let combined = visual_conviction * v_frac + thought_conviction * t_frac;
                    (Some(v), combined)
                } else {
                    if visual_conviction * v_frac > thought_conviction * t_frac {
                        (Some(v), visual_conviction * v_frac)
                    } else {
                        (Some(thought_to_outcome(t)), thought_conviction * t_frac)
                    }
                }
            }
            (Some(v), None) => (Some(v), visual_conviction * 0.8),
            (None, Some(t)) => (Some(thought_to_outcome(t)), thought_conviction * 0.8),
            (None, None) => (None, 0.0),
        },

        _ => panic!("unknown orchestration mode: {}", mode),
    }
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() {
    let args = Args::parse();

    if args.threads > 0 {
        rayon::ThreadPoolBuilder::new()
            .num_threads(args.threads)
            .build_global()
            .expect("failed to configure rayon thread pool");
    }

    let total_pixels = args.window * args.px_rows * 4;

    eprintln!("trader: Self-Supervised BTC Trader");
    eprintln!("  {}D, window={}, px_rows={}", args.dims, args.window, args.px_rows);
    eprintln!("  Grid: {} cols x {} rows ({} pixels/viewport)",
        args.window, args.px_rows * 4, total_pixels);
    eprintln!("  Horizon: {} candles ({}min)", args.horizon, args.horizon * 5);
    eprintln!("  Move threshold: {:.3}% ({:.1}bps)", args.move_threshold * 100.0, args.move_threshold * 10000.0);
    eprintln!("  Decay: {}, Recalib interval: {}", args.decay, args.recalib_interval);
    eprintln!("  Observe period: {} candles", args.observe_period);
    eprintln!("  Initial equity: ${:.0}", args.initial_equity);
    eprintln!("  Reward weight: {}, Correction weight: {}", args.reward_weight, args.correction_weight);
    eprintln!("  Use grover: {}, Use attend: {}", args.use_grover, args.use_attend);
    eprintln!("  Threads: {}, Batch size: {}", args.threads, args.batch_size);

    // Load data
    eprintln!("\n  Loading candles from {:?}...", args.db_path);
    let t0 = Instant::now();
    let candles = load_candles(&args.db_path, &args.label_col);
    eprintln!("  Loaded {} candles in {:.1}s", candles.len(), t0.elapsed().as_secs_f64());

    let vm = VectorManager::new(args.dims);

    // Pre-warm VM cache
    eprintln!("  Warming vector cache...");
    let color_tokens = [
        "null", "gs", "rs", "gw", "rw", "dj", "yl", "rl", "gl",
        "wu", "wl", "vg", "vr", "rb", "ro", "rn", "ml", "ms",
        "mhg", "mhr", "dp", "dm", "ax", "set_indicator",
    ];
    for tok in &color_tokens {
        vm.get_vector(tok);
    }
    let total_rows = args.px_rows * 4;
    let max_pos = args.window.max(total_rows);
    for p in 0..max_pos as i64 {
        vm.get_position_vector(p);
    }

    // Null template + visual cache
    eprintln!("  Encoding null template...");
    let null_template = build_null_template(args.window, args.px_rows);
    let null_vec = raster_encode(&vm, &null_template, &Vector::zeros(args.dims));
    let visual_cache = VisualCache::new(&vm, args.window, args.px_rows);
    eprintln!("  Null template + visual cache ready.");

    // Initialize thought system
    eprintln!("  Initializing thought system...");
    let thought_vocab = ThoughtVocab::new(&vm);
    let thought_encoder = ThoughtEncoder::new(thought_vocab);
    let mut thought_streams = IndicatorStreams::new(args.dims, args.window + 48);
    let mut thought_journaler = ThoughtJournaler::new(args.dims, args.recalib_interval);
    let fact_codebook = FactCodebook::build(thought_encoder.vocab());
    eprintln!("  Thought system ready ({} fact codebook entries).", fact_codebook.labels.len());

    // Initialize run database for structured logging
    let run_ts = chrono::Utc::now().format("%Y%m%d_%H%M%S").to_string();
    let run_db_path = format!("runs/run_{}.db", run_ts);
    std::fs::create_dir_all("runs").ok();
    let run_db = Connection::open(&run_db_path).expect("failed to open run DB");
    run_db.execute_batch("
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;

        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS candle_log (
            step              INTEGER PRIMARY KEY,
            candle_idx        INTEGER,
            timestamp         TEXT,
            -- visual prediction detail
            vis_pred          TEXT,
            vis_buy_sim       REAL,
            vis_sell_sim      REAL,
            vis_buy_conf_sim  REAL,
            vis_sell_conf_sim REAL,
            vis_noise_sim     REAL,
            vis_conviction    REAL,
            vis_noise_gated   INTEGER,
            vis_confuser_flipped INTEGER,
            -- thought prediction detail
            thought_pred      TEXT,
            thought_conviction REAL,
            -- agreement
            agree             INTEGER,
            -- outcome (filled when resolved)
            actual            TEXT,
            -- trader
            action            TEXT,
            equity            REAL
        );

        CREATE TABLE IF NOT EXISTS recalib_log (
            step          INTEGER,
            system        TEXT,
            cos_buy_sell  REAL,
            cos_buy_noise REAL,
            cos_sell_noise REAL,
            noise_floor   REAL,
            buy_count     INTEGER,
            sell_count    INTEGER,
            confuser_buy_count  INTEGER,
            confuser_sell_count INTEGER
        );
    ").expect("failed to create run DB tables");

    {
        let mut stmt = run_db.prepare("INSERT INTO meta (key, value) VALUES (?1, ?2)")
            .expect("failed to prepare meta insert");
        stmt.execute(params!["orchestration", &args.orchestration]).ok();
        stmt.execute(params!["dims", args.dims.to_string()]).ok();
        stmt.execute(params!["max_candles", args.max_candles.to_string()]).ok();
        stmt.execute(params!["window", args.window.to_string()]).ok();
        stmt.execute(params!["horizon", args.horizon.to_string()]).ok();
        stmt.execute(params!["move_threshold", args.move_threshold.to_string()]).ok();
        stmt.execute(params!["decay", args.decay.to_string()]).ok();
        stmt.execute(params!["reward_weight", args.reward_weight.to_string()]).ok();
        stmt.execute(params!["correction_weight", args.correction_weight.to_string()]).ok();
        stmt.execute(params!["run_db_path", &run_db_path]).ok();
    }
    eprintln!("  Run database: {}", run_db_path);

    // Initialize agents
    let mut journaler = Journaler::new(
        args.dims,
        args.recalib_interval,
        args.use_grover,
        args.use_attend,
    );
    let mut trader = Trader::new(args.initial_equity, args.observe_period);

    // Journaler accuracy tracking (visual)
    let mut j_total: usize = 0;
    let mut j_correct: usize = 0;
    let mut j_rolling: VecDeque<bool> = VecDeque::new();
    let j_rolling_cap: usize = 1000;
    let mut j_by_year: HashMap<i32, (usize, usize)> = HashMap::new();

    // Thought journaler accuracy tracking
    let mut tj_total: usize = 0;
    let mut tj_correct: usize = 0;
    let mut tj_rolling: VecDeque<bool> = VecDeque::new();
    let mut tj_agree_count: usize = 0;
    let mut tj_disagree_count: usize = 0;

    let mut pending: VecDeque<PendingEntry> = VecDeque::new();

    let total_candles = candles.len();
    let start_idx = args.window - 1;
    let end_idx = if args.max_candles > 0 {
        (start_idx + args.max_candles).min(total_candles)
    } else {
        total_candles
    };
    let loop_count = end_idx - start_idx;
    let progress_interval = if loop_count <= 10_000 { 500 } else { 10_000 };
    let mut encode_count: usize = 0;
    let mut labeled_count: usize = 0;
    let bnh_entry_price = candles[start_idx].close;
    let mut noise_count: usize = 0;
    let t_start = Instant::now();

    eprintln!("\n  Starting walk-forward ({} candles, starting at index {})...",
        loop_count, start_idx);

    let batch_size = args.batch_size.max(1);
    let mut cursor = start_idx;
    let mut log_step: i64 = 0;
    let mut db_batch_count = 0;
    run_db.execute_batch("BEGIN").ok();

    let mut t_visual_batch_us = 0u128;
    let mut t_thought_encode_us = 0u128;
    let mut t_visual_predict_us = 0u128;
    let mut t_thought_predict_us = 0u128;
    let mut t_rest_us = 0u128;

    while cursor < end_idx {
        let batch_end = (cursor + batch_size).min(end_idx);
        let batch_len = batch_end - cursor;

        // PARALLEL: render + encode visual vectors (using cached atom/position lookups)
        let vb_start = std::time::Instant::now();
        let encoded: Vec<(usize, Vector)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let panels = render_viewport(&candles, i, args.window, args.px_rows);
                let vp = build_viewport(&panels, args.window, args.px_rows);
                let vec = raster_encode_cached(&visual_cache, &vp, &null_vec);
                (i, vec)
            })
            .collect();
        t_visual_batch_us += vb_start.elapsed().as_micros();

        // SEQUENTIAL: push all batch candles to thought streams (cheap scalar encoding)
        let stream_base_len = thought_streams.len();
        let orig_max_len = thought_streams.max_len_val();
        thought_streams.set_max_len(orig_max_len + batch_len);
        for j in cursor..batch_end {
            thought_streams.push_candle(&candles[j]);
        }

        // PARALLEL: encode all thought vectors for the batch
        let te_start = std::time::Instant::now();
        let thought_results: Vec<thought::ThoughtResult> = (0..batch_len)
            .into_par_iter()
            .map(|j| {
                let candle_idx = cursor + j;
                let candle_window_start = candle_idx.saturating_sub(args.window - 1);
                let candle_window = &candles[candle_window_start..=candle_idx];
                let stream_end = stream_base_len + j + 1;
                thought_encoder.encode_view(candle_window, &thought_streams, stream_end, orig_max_len, &vm)
            })
            .collect();
        t_thought_encode_us += te_start.elapsed().as_micros();

        // Trim streams back to original window size
        thought_streams.set_max_len(orig_max_len);
        thought_streams.trim_to_max();

        // SEQUENTIAL: predict + buffer + resolve
        for ((i, vec), thought_result) in encoded.into_iter().zip(thought_results) {
            encode_count += 1;

            let vp_start = std::time::Instant::now();
            let vis_detail = journaler.predict(&vec);
            t_visual_predict_us += vp_start.elapsed().as_micros();

            let tp_start = std::time::Instant::now();
            let t_pred = thought_journaler.predict(&thought_result);
            t_thought_predict_us += tp_start.elapsed().as_micros();

            let rest_start = std::time::Instant::now();

            let j_pred = vis_detail.prediction;
            let conviction = vis_detail.conviction;
            let j_max_sim = vis_detail.max_sim;

            let t_outcome = t_pred.outcome;
            let t_conviction = t_pred.conviction;
            let t_coherence = t_pred.coherence;

            // Rolling accuracies for weighted mode
            let v_roll_acc = if j_rolling.is_empty() {
                0.5
            } else {
                j_rolling.iter().filter(|&&x| x).count() as f64 / j_rolling.len() as f64
            };
            let t_roll_acc = if tj_rolling.is_empty() {
                0.5
            } else {
                tj_rolling.iter().filter(|&&x| x).count() as f64 / tj_rolling.len() as f64
            };

            let (meta_direction, meta_conviction) = meta_orchestrate(
                &args.orchestration,
                j_pred, conviction,
                t_outcome, t_conviction, t_coherence,
                v_roll_acc, t_roll_acc,
            );

            // Trader decides based on meta prediction
            let trade_action = if let Some(dir) = meta_direction {
                if let Some(position_frac) = trader.should_trade(meta_conviction) {
                    Some(TradeAction {
                        direction: dir,
                        position_frac,
                    })
                } else {
                    trader.trades_skipped += 1;
                    None
                }
            } else {
                None
            };

            // Track agreement stats
            if let (Some(vp), Some(tp)) = (j_pred, t_outcome) {
                let v_is_buy = vp == Outcome::Buy;
                let t_is_buy = tp == thought::Outcome::Buy;
                if v_is_buy == t_is_buy {
                    tj_agree_count += 1;
                } else {
                    tj_disagree_count += 1;
                }
            }

            pending.push_back(PendingEntry {
                candle_idx: i,
                vec,
                journaler_prediction: j_pred,
                conviction,
                max_sim: j_max_sim,
                trade_action,
                thought_vec: thought_result.thought,
                thought_prediction: t_outcome,
                thought_conviction: t_conviction,
                vis_detail: vis_detail.clone(),
            });

            // Resolve oldest entry when buffer exceeds horizon
            if pending.len() > args.horizon {
                let entry = pending.pop_front().unwrap();
                let entry_candle = &candles[entry.candle_idx];

                if let Some(res) = resolve_outcome(&candles, entry.candle_idx, args.horizon, args.move_threshold, total_candles) {
                    // Visual journaler observes
                    journaler.observe(
                        &entry.vec,
                        res.outcome,
                        entry.journaler_prediction,
                        entry.conviction,
                        args.decay,
                        args.reward_weight,
                        args.correction_weight,
                    );

                    // Thought journaler observes
                    let t_outcome_th = match res.outcome {
                        Outcome::Buy => thought::Outcome::Buy,
                        Outcome::Sell => thought::Outcome::Sell,
                        Outcome::Noise => thought::Outcome::Noise,
                    };
                    thought_journaler.observe(
                        &entry.thought_vec,
                        t_outcome_th,
                        entry.thought_prediction,
                        entry.thought_conviction,
                        args.decay,
                        args.reward_weight,
                        args.correction_weight,
                    );

                    match res.outcome {
                        Outcome::Noise => noise_count += 1,
                        _ => labeled_count += 1,
                    }

                    // Visual accuracy tracking + sim bucket recording
                    if let Some(pred) = entry.journaler_prediction {
                        if res.outcome != Outcome::Noise {
                            let is_correct = pred == res.outcome;
                            j_total += 1;
                            if is_correct { j_correct += 1; }
                            j_rolling.push_back(is_correct);
                            if j_rolling.len() > j_rolling_cap {
                                j_rolling.pop_front();
                            }
                            let ye = j_by_year.entry(entry_candle.year).or_insert((0, 0));
                            ye.1 += 1;
                            if is_correct { ye.0 += 1; }
                        }
                    }

                    // Thought accuracy tracking
                    if let Some(t_pred) = entry.thought_prediction {
                        if res.outcome != Outcome::Noise {
                            let t_is_correct = (t_pred == thought::Outcome::Buy && res.outcome == Outcome::Buy)
                                || (t_pred == thought::Outcome::Sell && res.outcome == Outcome::Sell);
                            tj_total += 1;
                            if t_is_correct { tj_correct += 1; }
                            tj_rolling.push_back(t_is_correct);
                            if tj_rolling.len() > j_rolling_cap {
                                tj_rolling.pop_front();
                            }
                        }
                    }

                    if let Some(ref action) = entry.trade_action {
                        if res.outcome != Outcome::Noise {
                            trader.record_trade(
                                res.pct_change,
                                action.position_frac,
                                action.direction,
                                entry_candle.year,
                            );
                        }
                    }

                    // Log to run DB
                    let vd = &entry.vis_detail;
                    let vis_pred_str = entry.journaler_prediction.map(|p| format!("{:?}", p));
                    let thought_pred_str = entry.thought_prediction.map(|p| format!("{:?}", p));
                    let agree = match (entry.journaler_prediction, entry.thought_prediction) {
                        (Some(vp), Some(tp)) => {
                            let v_buy = vp == Outcome::Buy;
                            let t_buy = tp == thought::Outcome::Buy;
                            Some(v_buy == t_buy)
                        }
                        _ => None,
                    };
                    let action_str = entry.trade_action.as_ref().map(|a| format!("{:?}", a.direction));
                    let actual_str = format!("{:?}", res.outcome);

                    run_db.execute(
                        "INSERT INTO candle_log (step, candle_idx, timestamp,
                            vis_pred, vis_buy_sim, vis_sell_sim, vis_buy_conf_sim, vis_sell_conf_sim,
                            vis_noise_sim, vis_conviction, vis_noise_gated, vis_confuser_flipped,
                            thought_pred, thought_conviction, agree, actual, action, equity)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
                        params![
                            log_step, entry.candle_idx as i64, &entry_candle.ts,
                            vis_pred_str, vd.buy_sim, vd.sell_sim, vd.buy_confuser_sim, vd.sell_confuser_sim,
                            vd.noise_sim, vd.conviction, vd.noise_gated as i32, vd.confuser_flipped as i32,
                            thought_pred_str, entry.thought_conviction,
                            agree.map(|a| a as i32), &actual_str, action_str, trader.equity,
                        ],
                    ).ok();
                    log_step += 1;
                    db_batch_count += 1;
                    if db_batch_count >= 5000 {
                        run_db.execute_batch("COMMIT; BEGIN").ok();
                        db_batch_count = 0;
                    }

                    trader.tick_observe();
                }
            }

            // Progress reporting
            if encode_count % progress_interval == 0 {
                let elapsed = t_start.elapsed().as_secs_f64();
                let rate = encode_count as f64 / elapsed;
                let remaining = loop_count - encode_count;
                let eta = remaining as f64 / rate;
                let j_roll_acc = if j_rolling.is_empty() {
                    0.0
                } else {
                    j_rolling.iter().filter(|&&x| x).count() as f64 / j_rolling.len() as f64 * 100.0
                };
                let tj_roll_acc = if tj_rolling.is_empty() {
                    0.0
                } else {
                    tj_rolling.iter().filter(|&&x| x).count() as f64 / tj_rolling.len() as f64 * 100.0
                };
                let latest_ts = &candles[i].ts;
                let bnh_return = (candles[i].close - bnh_entry_price) / bnh_entry_price * 100.0;
                let trader_return = (trader.equity - args.initial_equity) / args.initial_equity * 100.0;
                let agree_total = tj_agree_count + tj_disagree_count;
                let agree_pct = if agree_total > 0 { tj_agree_count as f64 / agree_total as f64 * 100.0 } else { 0.0 };
                eprintln!(
                    "    {}/{} ({:.0}/s, ETA {:.0}s) | {} | {} | vis={:.1}% thought={:.1}% agree={:.0}% | trades={} win={:.1}% | eq=${:.0} ({:+.1}%) vs bnh {:+.1}%",
                    encode_count, loop_count, rate, eta,
                    latest_ts,
                    trader.phase,
                    j_roll_acc, tj_roll_acc, agree_pct,
                    trader.trades_taken, trader.win_rate(),
                    trader.equity, trader_return, bnh_return,
                );

                // Snapshot recalib state to DB
                if journaler.is_ready() {
                    let bp = journaler.buy_good.threshold();
                    let sp = journaler.sell_good.threshold();
                    let np = if journaler.noise_accum.count() > 0 {
                        Some(journaler.noise_accum.threshold())
                    } else { None };
                    run_db.execute(
                        "INSERT INTO recalib_log (step, system, cos_buy_sell, cos_buy_noise, cos_sell_noise, noise_floor, buy_count, sell_count, confuser_buy_count, confuser_sell_count)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                        params![
                            encode_count as i64, "visual",
                            Similarity::cosine(&bp, &sp),
                            np.as_ref().map(|n| Similarity::cosine(&bp, n)).unwrap_or(0.0),
                            np.as_ref().map(|n| Similarity::cosine(&sp, n)).unwrap_or(0.0),
                            journaler.noise_floor,
                            journaler.buy_good.count() as i64,
                            journaler.sell_good.count() as i64,
                            journaler.buy_confuser.count() as i64,
                            journaler.sell_confuser.count() as i64,
                        ],
                    ).ok();
                }
                if thought_journaler.is_ready() {
                    let bp = thought_journaler.buy_good.threshold();
                    let sp = thought_journaler.sell_good.threshold();
                    run_db.execute(
                        "INSERT INTO recalib_log (step, system, cos_buy_sell, cos_buy_noise, cos_sell_noise, noise_floor, buy_count, sell_count, confuser_buy_count, confuser_sell_count)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                        params![
                            encode_count as i64, "thought",
                            Similarity::cosine(&bp, &sp),
                            0.0, 0.0,
                            thought_journaler.noise_floor,
                            thought_journaler.buy_good.count() as i64,
                            thought_journaler.sell_good.count() as i64,
                            thought_journaler.buy_confuser.count() as i64,
                            thought_journaler.sell_confuser.count() as i64,
                        ],
                    ).ok();
                }
            }
            t_rest_us += rest_start.elapsed().as_micros();
        }

        cursor = batch_end;
    }

    eprintln!("\n  --- Timing breakdown (total ms) ---");
    eprintln!("  Visual batch encode:  {:>8.1}", t_visual_batch_us as f64 / 1000.0);
    eprintln!("  Thought encode:       {:>8.1}", t_thought_encode_us as f64 / 1000.0);
    eprintln!("  Visual predict:       {:>8.1}", t_visual_predict_us as f64 / 1000.0);
    eprintln!("  Thought predict:      {:>8.1}", t_thought_predict_us as f64 / 1000.0);
    eprintln!("  Rest (resolve/log):   {:>8.1}", t_rest_us as f64 / 1000.0);
    let total_ms = (t_visual_batch_us + t_thought_encode_us + t_visual_predict_us + t_thought_predict_us + t_rest_us) as f64 / 1000.0;
    eprintln!("  Total accounted:      {:>8.1}", total_ms);

    // Drain remaining pending entries
    while let Some(entry) = pending.pop_front() {
        let entry_candle = &candles[entry.candle_idx];

        if let Some(res) = resolve_outcome(&candles, entry.candle_idx, args.horizon, args.move_threshold, total_candles) {
            journaler.observe(
                &entry.vec,
                res.outcome,
                entry.journaler_prediction,
                entry.conviction,
                args.decay,
                args.reward_weight,
                args.correction_weight,
            );

            let t_outcome_th = match res.outcome {
                Outcome::Buy => thought::Outcome::Buy,
                Outcome::Sell => thought::Outcome::Sell,
                Outcome::Noise => thought::Outcome::Noise,
            };
            thought_journaler.observe(
                &entry.thought_vec,
                t_outcome_th,
                entry.thought_prediction,
                entry.thought_conviction,
                args.decay,
                args.reward_weight,
                args.correction_weight,
            );

            match res.outcome {
                Outcome::Noise => noise_count += 1,
                _ => labeled_count += 1,
            }

            if let Some(pred) = entry.journaler_prediction {
                if res.outcome != Outcome::Noise {
                    let is_correct = pred == res.outcome;
                    j_total += 1;
                    if is_correct { j_correct += 1; }
                    j_rolling.push_back(is_correct);
                    if j_rolling.len() > j_rolling_cap {
                        j_rolling.pop_front();
                    }
                    let ye = j_by_year.entry(entry_candle.year).or_insert((0, 0));
                    ye.1 += 1;
                    if is_correct { ye.0 += 1; }
                }
            }

            if let Some(t_pred) = entry.thought_prediction {
                if res.outcome != Outcome::Noise {
                    let t_is_correct = (t_pred == thought::Outcome::Buy && res.outcome == Outcome::Buy)
                        || (t_pred == thought::Outcome::Sell && res.outcome == Outcome::Sell);
                    tj_total += 1;
                    if t_is_correct { tj_correct += 1; }
                    tj_rolling.push_back(t_is_correct);
                    if tj_rolling.len() > j_rolling_cap {
                        tj_rolling.pop_front();
                    }
                }
            }

            if let Some(ref action) = entry.trade_action {
                if res.outcome != Outcome::Noise {
                    trader.record_trade(
                        res.pct_change,
                        action.position_frac,
                        action.direction,
                        entry_candle.year,
                    );
                }
            }

            // Log to run DB (drain)
            let vd = &entry.vis_detail;
            let vis_pred_str = entry.journaler_prediction.map(|p| format!("{:?}", p));
            let thought_pred_str = entry.thought_prediction.map(|p| format!("{:?}", p));
            let agree = match (entry.journaler_prediction, entry.thought_prediction) {
                (Some(vp), Some(tp)) => {
                    let v_buy = vp == Outcome::Buy;
                    let t_buy = tp == thought::Outcome::Buy;
                    Some(v_buy == t_buy)
                }
                _ => None,
            };
            let action_str = entry.trade_action.as_ref().map(|a| format!("{:?}", a.direction));
            let actual_str = format!("{:?}", res.outcome);
            run_db.execute(
                "INSERT INTO candle_log (step, candle_idx, timestamp,
                    vis_pred, vis_buy_sim, vis_sell_sim, vis_buy_conf_sim, vis_sell_conf_sim,
                    vis_noise_sim, vis_conviction, vis_noise_gated, vis_confuser_flipped,
                    thought_pred, thought_conviction, agree, actual, action, equity)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
                params![
                    log_step, entry.candle_idx as i64, &entry_candle.ts,
                    vis_pred_str, vd.buy_sim, vd.sell_sim, vd.buy_confuser_sim, vd.sell_confuser_sim,
                    vd.noise_sim, vd.conviction, vd.noise_gated as i32, vd.confuser_flipped as i32,
                    thought_pred_str, entry.thought_conviction,
                    agree.map(|a| a as i32), &actual_str, action_str, trader.equity,
                ],
            ).ok();
            log_step += 1;
        }
    }

    run_db.execute_batch("COMMIT").ok();
    eprintln!("\n  Run database written: {} ({} rows)", run_db_path, log_step);

    // ─── Final Summary ──────────────────────────────────────────────────────

    let total_time = t_start.elapsed().as_secs_f64();
    eprintln!("\n  Walk-forward complete.");
    eprintln!("  Orchestration mode: {}", args.orchestration);
    eprintln!("  Encoded {} viewports in {:.1}s ({:.0} vec/s)",
        encode_count, total_time, encode_count as f64 / total_time);
    eprintln!("  Labeled (BUY/SELL): {}, Noise: {}", labeled_count, noise_count);

    // Visual Journaler diagnostics
    eprintln!("\n  ═══ Visual Journaler ═══");
    eprintln!("  Accumulators:");
    eprintln!("    buy_good:     count={}, purity={:.4}",
        journaler.buy_good.count(), journaler.buy_good.purity());
    eprintln!("    sell_good:    count={}, purity={:.4}",
        journaler.sell_good.count(), journaler.sell_good.purity());
    eprintln!("    buy_confuser: count={}", journaler.buy_confuser.count());
    eprintln!("    sell_confuser:count={}", journaler.sell_confuser.count());
    eprintln!("    noise:        count={}", journaler.noise_accum.count());

    if journaler.is_ready() {
        let buy_proto = journaler.buy_good.threshold();
        let sell_proto = journaler.sell_good.threshold();
        eprintln!("    cos(buy_good, sell_good) = {:.4}", Similarity::cosine(&buy_proto, &sell_proto));

        if journaler.noise_accum.count() > 0 {
            let noise_proto = journaler.noise_accum.threshold();
            eprintln!("    cos(buy_good, noise) = {:.4}", Similarity::cosine(&buy_proto, &noise_proto));
            eprintln!("    cos(sell_good, noise) = {:.4}", Similarity::cosine(&sell_proto, &noise_proto));
        }

        if let (Some(ref bd), Some(ref sd)) = (&journaler.buy_disc, &journaler.sell_disc) {
            eprintln!("    cos(buy_disc, sell_disc) = {:.4}", Similarity::cosine(bd, sd));
        }
        let buy_ent = Primitives::entropy(&buy_proto);
        let sell_ent = Primitives::entropy(&sell_proto);
        eprintln!("    recognition gate: noise_floor={:.4} (buy_entropy={:.4}, sell_entropy={:.4}, d_eff={:.0})",
            journaler.noise_floor, buy_ent, sell_ent,
            journaler.dims as f64 * buy_ent.min(sell_ent).max(0.01));
    }

    let j_overall = if j_total > 0 { j_correct as f64 / j_total as f64 * 100.0 } else { 0.0 };
    let j_roll_final = if j_rolling.is_empty() {
        0.0
    } else {
        j_rolling.iter().filter(|&&x| x).count() as f64 / j_rolling.len() as f64 * 100.0
    };
    eprintln!("\n  Visual prediction accuracy:");
    eprintln!("    Overall: {:.1}% ({}/{})", j_overall, j_correct, j_total);
    eprintln!("    Rolling (last {}): {:.1}%", j_rolling_cap, j_roll_final);
    eprintln!("\n  Per-year breakdown:");
    let mut years: Vec<i32> = j_by_year.keys().copied().collect();
    years.sort();
    for year in &years {
        let (c, t) = j_by_year[year];
        let acc = if t > 0 { c as f64 / t as f64 * 100.0 } else { 0.0 };
        eprintln!("    {}: {:.1}% ({}/{})", year, acc, c, t);
    }

    // Thought Journaler diagnostics
    eprintln!("\n  ═══ Thought Journaler ═══");
    eprintln!("  Accumulators:");
    eprintln!("    buy_good:     count={}, purity={:.4}",
        thought_journaler.buy_good.count(), thought_journaler.buy_good.purity());
    eprintln!("    sell_good:    count={}, purity={:.4}",
        thought_journaler.sell_good.count(), thought_journaler.sell_good.purity());
    eprintln!("    buy_confuser: count={}", thought_journaler.buy_confuser.count());
    eprintln!("    sell_confuser:count={}", thought_journaler.sell_confuser.count());
    eprintln!("    noise:        count={}", thought_journaler.noise_accum.count());

    if thought_journaler.is_ready() {
        let t_buy = thought_journaler.buy_good.threshold();
        let t_sell = thought_journaler.sell_good.threshold();
        eprintln!("    cos(buy_good, sell_good) = {:.4}", Similarity::cosine(&t_buy, &t_sell));

        if thought_journaler.noise_accum.count() > 0 {
            let t_noise = thought_journaler.noise_accum.threshold();
            eprintln!("    cos(buy_good, noise) = {:.4}", Similarity::cosine(&t_buy, &t_noise));
            eprintln!("    cos(sell_good, noise) = {:.4}", Similarity::cosine(&t_sell, &t_noise));
        }

        if args.debug_thoughts {
            eprintln!("\n  Thought buy prototype top facts:");
            for (label, sim) in fact_codebook.decode(&t_buy, 5, 0.05) {
                eprintln!("    {:.3}  {}", sim, label);
            }
            eprintln!("  Thought sell prototype top facts:");
            for (label, sim) in fact_codebook.decode(&t_sell, 5, 0.05) {
                eprintln!("    {:.3}  {}", sim, label);
            }
            if thought_journaler.buy_confuser.count() > 0 {
                eprintln!("  Thought buy confuser top facts:");
                for (label, sim) in fact_codebook.decode(&thought_journaler.buy_confuser.threshold(), 5, 0.05) {
                    eprintln!("    {:.3}  {}", sim, label);
                }
            }
        }
    }

    let tj_overall = if tj_total > 0 { tj_correct as f64 / tj_total as f64 * 100.0 } else { 0.0 };
    let tj_roll_final = if tj_rolling.is_empty() {
        0.0
    } else {
        tj_rolling.iter().filter(|&&x| x).count() as f64 / tj_rolling.len() as f64 * 100.0
    };
    eprintln!("\n  Thought prediction accuracy:");
    eprintln!("    Overall: {:.1}% ({}/{})", tj_overall, tj_correct, tj_total);
    eprintln!("    Rolling (last {}): {:.1}%", j_rolling_cap, tj_roll_final);

    let agree_total = tj_agree_count + tj_disagree_count;
    let agree_pct = if agree_total > 0 { tj_agree_count as f64 / agree_total as f64 * 100.0 } else { 0.0 };
    eprintln!("    Visual-Thought agreement: {:.1}% ({}/{})", agree_pct, tj_agree_count, agree_total);

    // Trader diagnostics
    eprintln!("\n  ═══ Trader ═══");
    eprintln!("  Final phase: {}", trader.phase);
    eprintln!("  Equity: ${:.2} (started ${:.0})", trader.equity, args.initial_equity);
    let total_return = (trader.equity - args.initial_equity) / args.initial_equity * 100.0;
    eprintln!("  Total return: {:.2}%", total_return);
    eprintln!("  Trades taken: {}, skipped: {}", trader.trades_taken, trader.trades_skipped);
    eprintln!("  Win rate: {:.1}% ({}/{})", trader.win_rate(), trader.trades_won, trader.trades_taken);
    eprintln!("  Confidence (rolling acc - 0.5): {:.3}", trader.confidence());

    if !trader.by_year.is_empty() {
        eprintln!("\n  Per-year P&L:");
        for year in &years {
            if let Some(ys) = trader.by_year.get(year) {
                let wr = if ys.trades > 0 { ys.wins as f64 / ys.trades as f64 * 100.0 } else { 0.0 };
                eprintln!("    {}: trades={} win_rate={:.1}% pnl=${:.2}", year, ys.trades, wr, ys.pnl);
            }
        }
    }

    // Buy-and-hold comparison
    if total_candles > args.window {
        let first_close = candles[start_idx].close;
        let last_close = candles[end_idx.min(total_candles) - 1].close;
        let bnh_return = (last_close - first_close) / first_close * 100.0;
        eprintln!("\n  Buy-and-hold return over same period: {:.2}%", bnh_return);
    }

    eprintln!("  ═══════════════════════════════════════");
}
