use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use holon::{Accumulator, AttendMode, Primitives, Similarity, VectorManager, Vector};

use btc_walk::db::load_candles;
use btc_walk::viewport::{render_viewport, build_viewport, build_null_template, raster_encode};

// ─── CLI ────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "btc-walk", about = "Walk-forward BTC trader with adaptive Holon algebra")]
struct Args {
    #[arg(long, default_value = "../data/analysis.db")]
    db_path: PathBuf,

    #[arg(long, default_value_t = 10000)]
    dims: usize,

    #[arg(long, default_value_t = 48)]
    window: usize,

    #[arg(long, default_value_t = 25)]
    px_rows: usize,

    #[arg(long, default_value_t = 36)]
    oracle_horizon: usize,

    #[arg(long, default_value_t = 0.999)]
    decay: f64,

    #[arg(long, default_value_t = 2019)]
    warmup_year: i32,

    #[arg(long, default_value = "label_oracle_10")]
    label_col: String,

    #[arg(long, default_value_t = 0.002)]
    vol_threshold: f64,

    #[arg(long, default_value_t = 1.0)]
    reward_weight: f64,

    #[arg(long, default_value_t = 1.5)]
    correction_weight: f64,

    #[arg(long, default_value_t = 500)]
    recalib_interval: usize,

    /// Use grover_amplify instead of amplify for reinforcement
    #[arg(long, default_value_t = false)]
    use_grover: bool,

    /// Use soft attend instead of hard resonance
    #[arg(long, default_value_t = false)]
    use_attend: bool,

    /// Limit total candles processed (0 = all)
    #[arg(long, default_value_t = 0)]
    max_candles: usize,

    /// Batch size for parallel viewport encoding
    #[arg(long, default_value_t = 256)]
    batch_size: usize,

    /// Number of rayon worker threads (0 = rayon default)
    #[arg(long, default_value_t = 8)]
    threads: usize,
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

// ─── Adaptive Model ─────────────────────────────────────────────────────────

struct AdaptiveModel {
    buy_accum: Accumulator,
    sell_accum: Accumulator,
    buy_disc: Option<Vector>,
    sell_disc: Option<Vector>,
    labeled_updates: usize,
    recalib_interval: usize,
    use_grover: bool,
    use_attend: bool,
}

impl AdaptiveModel {
    fn new(dims: usize, recalib_interval: usize, use_grover: bool, use_attend: bool) -> Self {
        Self {
            buy_accum: Accumulator::new(dims),
            sell_accum: Accumulator::new(dims),
            buy_disc: None,
            sell_disc: None,
            labeled_updates: 0,
            recalib_interval,
            use_grover,
            use_attend,
        }
    }

    fn is_ready(&self) -> bool {
        self.buy_accum.count() > 0 && self.sell_accum.count() > 0
    }

    fn predict(&self, vec: &Vector) -> (String, f64) {
        let buy_thresh;
        let sell_thresh;
        let buy_ref = match &self.buy_disc {
            Some(v) => v,
            None => { buy_thresh = self.buy_accum.threshold(); &buy_thresh }
        };
        let sell_ref = match &self.sell_disc {
            Some(v) => v,
            None => { sell_thresh = self.sell_accum.threshold(); &sell_thresh }
        };

        let buy_sim = Similarity::cosine(vec, buy_ref);
        let sell_sim = Similarity::cosine(vec, sell_ref);
        let label = if buy_sim > sell_sim { "BUY" } else { "SELL" };
        (label.to_string(), buy_sim - sell_sim)
    }

    fn update(
        &mut self,
        vec: &Vector,
        actual_label: &str,
        prediction: Option<&str>,
        decay: f64,
        reward_weight: f64,
        correction_weight: f64,
    ) {
        if actual_label != "BUY" && actual_label != "SELL" {
            return;
        }

        let use_grover = self.use_grover;
        let use_attend = self.use_attend;

        // 1. Decay both accumulators
        self.buy_accum.decay(decay);
        self.sell_accum.decay(decay);

        // 2. Standard update — add vec to correct accumulator
        match actual_label {
            "BUY" => self.buy_accum.add(vec),
            "SELL" => self.sell_accum.add(vec),
            _ => unreachable!(),
        }

        // 3. Algebraic refinement (only if we had a prediction)
        if let Some(pred) = prediction {
            let buy_proto = self.buy_accum.threshold();
            let sell_proto = self.sell_accum.threshold();

            if pred == actual_label {
                // CORRECT — reinforce the aligned signal
                let (correct_proto, opposing_proto) = match actual_label {
                    "BUY" => (&buy_proto, &sell_proto),
                    _ => (&sell_proto, &buy_proto),
                };

                let aligned = extract_features(vec, correct_proto, use_attend);
                let reinforced = amplify_signal(&aligned, opposing_proto, use_grover);

                match actual_label {
                    "BUY" => self.buy_accum.add_weighted(&reinforced, reward_weight),
                    _ => self.sell_accum.add_weighted(&reinforced, reward_weight),
                }
            } else {
                // WRONG — correct via discriminative surgery
                let wrong_proto = match actual_label {
                    "BUY" => &sell_proto,
                    _ => &buy_proto,
                };

                let misleading = extract_features(vec, wrong_proto, use_attend);
                let unique = Primitives::negate(vec, &misleading);
                let amplified = amplify_signal(&unique, &misleading, true);

                match actual_label {
                    "BUY" => self.buy_accum.add_weighted(&amplified, correction_weight),
                    _ => self.sell_accum.add_weighted(&amplified, correction_weight),
                }
            }
        }

        // 4. Periodic recalibration of discriminative prototypes
        self.labeled_updates += 1;
        if self.labeled_updates % self.recalib_interval == 0 {
            self.recalibrate();
        }
    }

    fn recalibrate(&mut self) {
        let buy_proto = self.buy_accum.threshold();
        let sell_proto = self.sell_accum.threshold();
        let shared = Primitives::resonance(&buy_proto, &sell_proto);
        self.buy_disc = Some(Primitives::negate(&buy_proto, &shared));
        self.sell_disc = Some(Primitives::negate(&sell_proto, &shared));
    }
}

// ─── Metrics ────────────────────────────────────────────────────────────────

struct Metrics {
    total: usize,
    correct: usize,
    by_year: HashMap<i32, (usize, usize)>, // (correct, total)
    rolling: VecDeque<bool>,
    rolling_cap: usize,
}

impl Metrics {
    fn new(rolling_cap: usize) -> Self {
        Self {
            total: 0,
            correct: 0,
            by_year: HashMap::new(),
            rolling: VecDeque::new(),
            rolling_cap,
        }
    }

    fn record(&mut self, year: i32, is_correct: bool) {
        self.total += 1;
        if is_correct {
            self.correct += 1;
        }

        let entry = self.by_year.entry(year).or_insert((0, 0));
        entry.1 += 1;
        if is_correct {
            entry.0 += 1;
        }

        self.rolling.push_back(is_correct);
        if self.rolling.len() > self.rolling_cap {
            self.rolling.pop_front();
        }
    }

    fn rolling_accuracy(&self) -> f64 {
        if self.rolling.is_empty() {
            return 0.0;
        }
        let correct = self.rolling.iter().filter(|&&x| x).count();
        correct as f64 / self.rolling.len() as f64 * 100.0
    }

    fn overall_accuracy(&self) -> f64 {
        if self.total == 0 { 0.0 } else { self.correct as f64 / self.total as f64 * 100.0 }
    }

    fn print_summary(&self) {
        eprintln!("\n  ═══════════════════════════════════════");
        eprintln!("  Overall: {:.1}% ({}/{} predictions)",
            self.overall_accuracy(), self.correct, self.total);
        eprintln!("  Rolling (last {}): {:.1}%", self.rolling_cap, self.rolling_accuracy());
        eprintln!();
        eprintln!("  Per-year breakdown:");
        let mut years: Vec<i32> = self.by_year.keys().copied().collect();
        years.sort();
        for year in years {
            let (c, t) = self.by_year[&year];
            let acc = if t > 0 { c as f64 / t as f64 * 100.0 } else { 0.0 };
            eprintln!("    {}: {:.1}% ({}/{})", year, acc, c, t);
        }
        eprintln!("  ═══════════════════════════════════════");
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
    let cap_sqrt = (args.dims as f64).sqrt() as usize;
    let cap_dlogd = args.dims / (args.dims as f64).log2() as usize;

    eprintln!("btc-walk: Walk-Forward Adaptive Trader");
    eprintln!("  {}D, window={}, px_rows={}", args.dims, args.window, args.px_rows);
    eprintln!("  Panels: price_vol, rsi, macd, dmi");
    eprintln!("  Grid: {} cols x {} rows ({} pixels/viewport)",
        args.window, args.px_rows * 4, total_pixels);
    eprintln!("  Capacity: sqrt(D)={}, D/log2(D)={}", cap_sqrt, cap_dlogd);
    eprintln!("  Oracle horizon: {} candles ({}min)", args.oracle_horizon, args.oracle_horizon * 5);
    eprintln!("  Decay: {} per labeled update", args.decay);
    eprintln!("  Warmup year: {}", args.warmup_year);
    eprintln!("  Reward weight: {}, Correction weight: {}", args.reward_weight, args.correction_weight);
    eprintln!("  Recalib interval: {} updates", args.recalib_interval);
    eprintln!("  Use grover: {}, Use attend: {}", args.use_grover, args.use_attend);
    eprintln!("  Threads: {}, Batch size: {}", args.threads, args.batch_size);

    // Load data
    eprintln!("\n  Loading candles from {:?}...", args.db_path);
    let t0 = Instant::now();
    let candles = load_candles(&args.db_path, &args.label_col);
    eprintln!("  Loaded {} candles in {:.1}s", candles.len(), t0.elapsed().as_secs_f64());

    // Initialize Holon
    let vm = VectorManager::new(args.dims);

    // Pre-warm VM cache so parallel threads never contend on write locks
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

    // Build null template and encode it
    eprintln!("  Encoding null template...");
    let null_template = build_null_template(args.window, args.px_rows);
    let null_vec = raster_encode(&vm, &null_template, &Vector::zeros(args.dims));
    // For null template, raw IS the null vec (no subtraction needed),
    // so re-encode without subtraction:
    // Actually, raster_encode does difference(null_vec_arg, raw). For the null template itself,
    // we want just the raw encoding. Pass a zeros vector so difference(zeros, raw) ≈ raw.
    // Since difference = (after - before).clamp(-1,1) and before=zeros, result = raw.clamp(-1,1) = raw.
    eprintln!("  Null template encoded.");

    // Initialize model and metrics
    let mut model = AdaptiveModel::new(
        args.dims,
        args.recalib_interval,
        args.use_grover,
        args.use_attend,
    );
    let mut metrics = Metrics::new(1000);

    // Ring buffer: (candle_idx, encoded_vec, prediction, predicted_label)
    struct PendingEntry {
        candle_idx: usize,
        vec: Vector,
        prediction: Option<String>,
    }
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
    let t_start = Instant::now();

    eprintln!("\n  Starting walk-forward ({} candles, starting at index {})...",
        loop_count, start_idx);

    let batch_size = args.batch_size.max(1);
    let mut cursor = start_idx;

    while cursor < end_idx {
        let batch_end = (cursor + batch_size).min(end_idx);

        // 1. PARALLEL: render + encode the entire batch
        let encoded: Vec<(usize, Vector)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let panels = render_viewport(&candles, i, args.window, args.px_rows);
                let vp = build_viewport(&panels, args.window, args.px_rows);
                let vec = raster_encode(&vm, &vp, &null_vec);
                (i, vec)
            })
            .collect();

        // 2. SEQUENTIAL: predict + buffer + oracle resolve
        for (i, vec) in encoded {
            encode_count += 1;

            let prediction = if candles[i].year > args.warmup_year && model.is_ready() {
                let (pred, _confidence) = model.predict(&vec);
                Some(pred)
            } else {
                None
            };

            pending.push_back(PendingEntry {
                candle_idx: i,
                vec,
                prediction,
            });

            if pending.len() > args.oracle_horizon {
                let entry = pending.pop_front().unwrap();
                let resolved_candle = &candles[entry.candle_idx];
                let label = &resolved_candle.label;

                if (label == "BUY" || label == "SELL") && resolved_candle.atr_r > args.vol_threshold {
                    model.update(
                        &entry.vec,
                        label,
                        entry.prediction.as_deref(),
                        args.decay,
                        args.reward_weight,
                        args.correction_weight,
                    );
                    labeled_count += 1;

                    if let Some(ref pred) = entry.prediction {
                        let is_correct = pred == label;
                        metrics.record(resolved_candle.year, is_correct);
                    }
                }
            }

            if encode_count % progress_interval == 0 {
                let elapsed = t_start.elapsed().as_secs_f64();
                let rate = encode_count as f64 / elapsed;
                let remaining = loop_count - encode_count;
                let eta = remaining as f64 / rate;
                eprintln!(
                    "    {}/{} ({:.0}/s, ETA {:.0}s) | labeled={} | rolling_acc={:.1}% | buy_n={} sell_n={}",
                    encode_count,
                    loop_count,
                    rate,
                    eta,
                    labeled_count,
                    metrics.rolling_accuracy(),
                    model.buy_accum.count(),
                    model.sell_accum.count(),
                );
            }
        }

        cursor = batch_end;
    }

    // Drain remaining pending entries
    while let Some(entry) = pending.pop_front() {
        let resolved_candle = &candles[entry.candle_idx];
        let label = &resolved_candle.label;

        if (label == "BUY" || label == "SELL") && resolved_candle.atr_r > args.vol_threshold {
            model.update(
                &entry.vec,
                label,
                entry.prediction.as_deref(),
                args.decay,
                args.reward_weight,
                args.correction_weight,
            );
            labeled_count += 1;

            if let Some(ref pred) = entry.prediction {
                metrics.record(resolved_candle.year, pred == label);
            }
        }
    }

    let total_time = t_start.elapsed().as_secs_f64();
    eprintln!("\n  Walk-forward complete.");
    eprintln!("  Encoded {} viewports in {:.1}s ({:.0} vec/s)",
        encode_count, total_time, encode_count as f64 / total_time);
    eprintln!("  Labeled updates: {}", labeled_count);

    // Accumulator diagnostics
    eprintln!("\n  Accumulator diagnostics:");
    eprintln!("    BUY:  count={}, purity={:.4}, participation_ratio={:.0}",
        model.buy_accum.count(), model.buy_accum.purity(), model.buy_accum.participation_ratio());
    eprintln!("    SELL: count={}, purity={:.4}, participation_ratio={:.0}",
        model.sell_accum.count(), model.sell_accum.purity(), model.sell_accum.participation_ratio());

    if model.is_ready() {
        let buy_proto = model.buy_accum.threshold();
        let sell_proto = model.sell_accum.threshold();
        let proto_sim = Similarity::cosine(&buy_proto, &sell_proto);
        eprintln!("    cos(BUY_proto, SELL_proto) = {:.4}", proto_sim);

        if let (Some(ref bd), Some(ref sd)) = (&model.buy_disc, &model.sell_disc) {
            let disc_sim = Similarity::cosine(bd, sd);
            eprintln!("    cos(BUY_disc, SELL_disc) = {:.4}", disc_sim);
        }
    }

    metrics.print_summary();
}
