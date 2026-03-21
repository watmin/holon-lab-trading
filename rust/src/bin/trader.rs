use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use holon::{Accumulator, AttendMode, Primitives, Similarity, VectorManager, Vector};

use btc_walk::db::load_candles;
use btc_walk::viewport::{render_viewport, build_viewport, build_null_template, raster_encode};

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
}

// ─── Outcome ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
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
}

impl Journaler {
    fn new(dims: usize, recalib_interval: usize, use_grover: bool, use_attend: bool) -> Self {
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
        }
    }

    fn is_ready(&self) -> bool {
        self.buy_good.count() > 0 && self.sell_good.count() > 0
    }

    fn predict(&self, vec: &Vector) -> (Option<Outcome>, f64) {
        if !self.is_ready() {
            return (None, 0.0);
        }

        let buy_proto = self.buy_disc.as_ref()
            .cloned()
            .unwrap_or_else(|| self.buy_good.threshold());
        let sell_proto = self.sell_disc.as_ref()
            .cloned()
            .unwrap_or_else(|| self.sell_good.threshold());

        // Stage 1: noise stripping — remove the average market background
        let cleaned = if self.noise_accum.count() > 0 {
            let noise_proto = self.noise_accum.threshold();
            Primitives::negate(vec, &noise_proto)
        } else {
            vec.clone()
        };

        let buy_sim = Similarity::cosine(&cleaned, &buy_proto);
        let sell_sim = Similarity::cosine(&cleaned, &sell_proto);

        // Stage 2: noise gate — if cleaned vec has low similarity to both, sit out
        if self.noise_accum.count() > 0 {
            let noise_proto = self.noise_accum.threshold();
            let cleaned_noise_sim = Similarity::cosine(&cleaned, &noise_proto);
            if cleaned_noise_sim > buy_sim.max(sell_sim) {
                return (None, 0.0);
            }
        }

        // Stage 3: confuser check
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

        if buy_conviction > sell_conviction {
            (Some(Outcome::Buy), buy_conviction)
        } else {
            (Some(Outcome::Sell), sell_conviction)
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

        // Recognition rejection: if the model has prototypes but this sample
        // isn't similar to any known pattern, skip learning to avoid poisoning
        // accumulators with truly novel/ambiguous data.
        if self.is_ready() {
            let buy_proto = self.buy_good.threshold();
            let sell_proto = self.sell_good.threshold();
            let buy_sim = Similarity::cosine(vec, &buy_proto);
            let sell_sim = Similarity::cosine(vec, &sell_proto);
            if buy_sim.max(sell_sim) < 0.01 {
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
    trade_action: Option<TradeAction>,
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

    // Null template
    eprintln!("  Encoding null template...");
    let null_template = build_null_template(args.window, args.px_rows);
    let null_vec = raster_encode(&vm, &null_template, &Vector::zeros(args.dims));
    eprintln!("  Null template encoded.");

    // Initialize agents
    let mut journaler = Journaler::new(
        args.dims,
        args.recalib_interval,
        args.use_grover,
        args.use_attend,
    );
    let mut trader = Trader::new(args.initial_equity, args.observe_period);

    // Journaler accuracy tracking
    let mut j_total: usize = 0;
    let mut j_correct: usize = 0;
    let mut j_rolling: VecDeque<bool> = VecDeque::new();
    let j_rolling_cap: usize = 1000;
    let mut j_by_year: HashMap<i32, (usize, usize)> = HashMap::new();

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

    while cursor < end_idx {
        let batch_end = (cursor + batch_size).min(end_idx);

        // PARALLEL: render + encode
        let encoded: Vec<(usize, Vector)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let panels = render_viewport(&candles, i, args.window, args.px_rows);
                let vp = build_viewport(&panels, args.window, args.px_rows);
                let vec = raster_encode(&vm, &vp, &null_vec);
                (i, vec)
            })
            .collect();

        // SEQUENTIAL: predict + buffer + resolve
        for (i, vec) in encoded {
            encode_count += 1;

            // Journaler predicts
            let (j_pred, conviction) = journaler.predict(&vec);

            // Trader decides
            let trade_action = if let Some(pred_outcome) = j_pred {
                if let Some(position_frac) = trader.should_trade(conviction) {
                    Some(TradeAction {
                        direction: pred_outcome,
                        position_frac,
                    })
                } else {
                    trader.trades_skipped += 1;
                    None
                }
            } else {
                None
            };

            pending.push_back(PendingEntry {
                candle_idx: i,
                vec,
                journaler_prediction: j_pred,
                conviction,
                trade_action,
            });

            // Resolve oldest entry when buffer exceeds horizon
            if pending.len() > args.horizon {
                let entry = pending.pop_front().unwrap();
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
                let latest_ts = &candles[i].ts;
                let bnh_return = (candles[i].close - bnh_entry_price) / bnh_entry_price * 100.0;
                let trader_return = (trader.equity - args.initial_equity) / args.initial_equity * 100.0;
                eprintln!(
                    "    {}/{} ({:.0}/s, ETA {:.0}s) | {} | {} | j_acc={:.1}% | trades={} win={:.1}% | eq=${:.0} ({:+.1}%) vs bnh {:+.1}% | labeled={} noise={}",
                    encode_count, loop_count, rate, eta,
                    latest_ts,
                    trader.phase,
                    j_roll_acc,
                    trader.trades_taken, trader.win_rate(),
                    trader.equity, trader_return, bnh_return,
                    labeled_count, noise_count,
                );
            }
        }

        cursor = batch_end;
    }

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
        }
    }

    // ─── Final Summary ──────────────────────────────────────────────────────

    let total_time = t_start.elapsed().as_secs_f64();
    eprintln!("\n  Walk-forward complete.");
    eprintln!("  Encoded {} viewports in {:.1}s ({:.0} vec/s)",
        encode_count, total_time, encode_count as f64 / total_time);
    eprintln!("  Labeled (BUY/SELL): {}, Noise: {}", labeled_count, noise_count);

    // Journaler diagnostics
    eprintln!("\n  ═══ Journaler ═══");
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
    }

    let j_overall = if j_total > 0 { j_correct as f64 / j_total as f64 * 100.0 } else { 0.0 };
    let j_roll_final = if j_rolling.is_empty() {
        0.0
    } else {
        j_rolling.iter().filter(|&&x| x).count() as f64 / j_rolling.len() as f64 * 100.0
    };
    eprintln!("\n  Prediction accuracy:");
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
