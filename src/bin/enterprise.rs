/// enterprise — self-organizing BTC trading enterprise.
///
/// Six primitives. Seven layers. One heartbeat per candle.
/// See wat/examples/enterprise.wat for the specification.
///
/// Experts predict direction from candle data at sampled time scales.
/// The manager reads expert opinions and decides.
/// Risk modulates sizing. Treasury executes. Positions manage themselves.
/// The ledger records everything. The DB is the debugger.
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use rusqlite::params;
use holon::{Primitives, ScalarMode, VectorManager, Vector};

use enterprise::candle::load_candles;
use enterprise::journal::{Label, Direction, Prediction};
use enterprise::thought::{ThoughtEncoder, ThoughtVocab};
use enterprise::portfolio::Phase;
use enterprise::sizing::{kelly_frac, signal_weight};
use enterprise::position::{Pending, ExitReason, ExitObservation, ManagedPosition, PositionPhase, PositionExit};
use enterprise::ledger::init_ledger;
use enterprise::market::{parse_candle_hour, parse_candle_day};
use enterprise::market::manager::{ManagerAtoms, ManagerContext, encode_manager_thought};
use enterprise::state::EnterpriseState;

// ─── Constants ───────────────────────────────────────────────────────────────

const BATCH_SIZE: usize = 256;
const THREADS: usize = 10;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "enterprise", about = "Self-organizing BTC trading enterprise")]
struct Args {
    /// Source candle database (pre-computed indicators).
    #[arg(long, default_value = "data/candles.db")]
    db_path: PathBuf,

    /// Vector dimension. Higher = more expressive, slower.
    #[arg(long, default_value_t = 10000)]
    dims: usize,

    /// Number of candles in the visual grid (columns).
    #[arg(long, default_value_t = 48)]
    window: usize,

    /// Learning horizon: candles to wait before labeling a pending entry.
    /// Also used as safety valve base (10× = max pending age for queue cleanup).
    #[arg(long, default_value_t = 36)]
    horizon: usize,

    /// Price move required to label a candle Buy or Sell (0.005 = 0.5%).
    /// Ignored when atr_multiplier > 0 (dynamic threshold takes over).
    #[arg(long, default_value_t = 0.005)]
    move_threshold: f64,

    /// ATR-based move threshold: threshold = K × atr_r (ATR/close ratio at entry).
    /// 0.0 = use fixed move_threshold. ~3.0 ≈ 0.5% for BTC. Asset-independent.
    #[arg(long, default_value_t = 0.0)]
    atr_multiplier: f64,

    /// Accumulator decay rate per candle (0.999 = slow fade).
    #[arg(long, default_value_t = 0.999)]
    decay: f64,

    /// Candles to observe before any trades are taken.
    #[arg(long, default_value_t = 1000)]
    observe_period: usize,

    /// Journal update count between discriminant recalibrations.
    #[arg(long, default_value_t = 500)]
    recalib_interval: usize,

    /// Starting paper equity in USD.
    #[arg(long, default_value_t = 10000.0)]
    initial_equity: f64,

    /// Stop after this many candles (0 = run all).
    #[arg(long, default_value_t = 0)]
    max_candles: usize,

    /// Minimum conviction to take a trade. 0.0 = no gate.
    #[arg(long, default_value_t = 0.0)]
    min_conviction: f64,

    /// Flip the predicted direction for the top N% of conviction predictions.
    /// 0.85 means flip the top 15% (candles where the model is more confident
    /// than 85% of its other predictions). 0.0 = disabled. The threshold is
    /// computed from the conviction distribution and updated every recalib_interval
    /// candles — no fixed magic value needed.
    /// Ignored when conviction_mode = "auto".
    #[arg(long, default_value_t = 0.85)]
    conviction_quantile: f64,

    /// "quantile" = use conviction_quantile percentile. "auto" = find the conviction
    /// level where cumulative win rate from the top first drops below min_edge.
    #[arg(long, default_value = "quantile")]
    conviction_mode: String,

    /// Minimum acceptable win rate for trading. This is the ONE economic input.
    /// The system finds the conviction threshold where flipped accuracy >= this value.
    /// Higher = fewer trades, higher accuracy. Lower = more trades, thinner edge.
    /// The conviction-accuracy curve is continuous and monotonic — this parameter
    /// sets the operating point. 0.55 = balanced, 0.60 = selective, 0.65 = sniper.
    #[arg(long, default_value_t = 0.55)]
    min_edge: f64,

    /// "legacy" = phase-based with 5% cap. "kelly" = half-Kelly from calibration curve.
    #[arg(long, default_value = "legacy")]
    sizing: String,

    /// Maximum acceptable drawdown (0.20 = 20%). The second economic input.
    /// Combined with the conviction-accuracy curve, this determines position caps.
    /// The system adjusts sizing to keep expected worst-case drawdown within this limit.
    #[arg(long, default_value_t = 0.20)]
    max_drawdown: f64,

    /// Per-swap fee as a fraction (0.0010 = 10bps = Jupiter Ultra).
    /// Applied twice per round trip (entry + exit).
    #[arg(long, default_value_t = 0.0)]
    swap_fee: f64,

    /// Slippage estimate per swap as a fraction (0.0025 = 25bps).
    /// Models DEX/AMM execution cost beyond the explicit fee.
    #[arg(long, default_value_t = 0.0)]
    slippage: f64,

    /// Maximum concurrent positions. The treasury allocates across them.
    #[arg(long, default_value_t = 1)]
    max_positions: usize,

    /// Maximum fraction of total equity deployed at once (0.50 = 50%).
    /// The rest stays liquid for new opportunities and drawdown cushion.
    #[arg(long, default_value_t = 0.50)]
    max_utilization: f64,

    /// Asset model: "round-trip" = USDC→WBTC→USDC per trade (0.70% RT cost).
    /// "hold" = treasury holds WBTC between BUY signals. BUY = swap USDC→WBTC,
    /// SELL = swap WBTC→USDC. One swap per signal (0.35% cost). WBTC appreciates
    /// between signals. The position persists.
    #[arg(long, default_value = "hold")]
    asset_mode: String,

    /// Base asset — the unit of account. Always priced at 1.0.
    #[arg(long, default_value = "USDC")]
    base_asset: String,

    /// Quote asset — what the desk trades. Priced by the candle stream.
    #[arg(long, default_value = "WBTC")]
    quote_asset: String,

    /// Output SQLite ledger for this run. Auto-generated if omitted.
    #[arg(long)]
    ledger: Option<PathBuf>,

    /// Enable heavy diagnostic tables (trade_facts, trade_vectors, observer_log).
    /// Off by default for performance. Enable for analysis runs.
    #[arg(long, default_value_t = false)]
    diagnostics: bool,
}







// ─── Main ─────────────────────────────────────────────────────────────────────

fn main() {
    let args = Args::parse();

    rayon::ThreadPoolBuilder::new()
        .num_threads(THREADS)
        .build_global()
        .expect("failed to configure rayon");

    eprintln!("enterprise: thought journals, discriminant prediction");
    let thresh_desc = if args.atr_multiplier > 0.0 {
        format!("{}×ATR", args.atr_multiplier)
    } else {
        format!("{:.3}%", args.move_threshold * 100.0)
    };
    let flip_desc = match args.conviction_mode.as_str() {
        "auto" => format!("auto(min_edge={:.2})", args.min_edge),
        _ => format!("q{:.0}", args.conviction_quantile * 100.0),
    };
    eprintln!("  {}D  window={}  horizon={}  threshold={}  decay={}  flip={}",
        args.dims, args.window, args.horizon, thresh_desc, args.decay, flip_desc);
    eprintln!("  observe={}  recalib_interval={}  min_conviction={:.3}",
        args.observe_period, args.recalib_interval, args.min_conviction);
    if args.swap_fee > 0.0 || args.slippage > 0.0 {
        eprintln!("  venue: {:.1}bps fee + {:.1}bps slippage per swap ({:.2}% round trip)",
            args.swap_fee * 10000.0, args.slippage * 10000.0,
            2.0 * (args.swap_fee + args.slippage) * 100.0);
    }

    // ─ Load candles and build event stream ─
    eprintln!("\n  Loading candles from {:?}...", args.db_path);
    let t0 = Instant::now();
    let candles = load_candles(&args.db_path, "label_oracle_10");
    // When fn on_event() is extracted, candles become events via
    // enterprise::event::stream_from_candles(). For now, heartbeat uses candles[] directly.
    eprintln!("  Loaded {} candles in {:.1}s",
        candles.len(), t0.elapsed().as_secs_f64());

    let vm = VectorManager::new(args.dims);

    // ─ Pre-warm position vectors for max possible window ─
    for p in 0..2016_i64 { vm.get_position_vector(p); }

    // ─ Thought encoding setup ─
    let thought_vocab   = ThoughtVocab::new(&vm);
    let thought_encoder = ThoughtEncoder::new(thought_vocab);
    let (codebook_labels, codebook_vecs) = thought_encoder.fact_codebook();

    // ─ Immutable encoding setup ─
    let mgr_scalar = holon::ScalarEncoder::new(args.dims);
    let mgr_atoms = ManagerAtoms::new(&vm);

    // ─ Exit expert atoms (immutable) ─
    // decomplect:allow(inline-encoding) — exit expert atoms + encoding grow here until market/exit.rs
    let exit_scalar = holon::ScalarEncoder::new(args.dims);
    let pos_pnl_atom = vm.get_vector("position-pnl");
    let pos_hold_atom = vm.get_vector("position-hold");
    let pos_mfe_atom = vm.get_vector("position-mfe");
    let pos_atr_entry_atom = vm.get_vector("position-atr-entry");
    let pos_atr_now_atom = vm.get_vector("position-atr-now");
    let pos_stop_dist_atom = vm.get_vector("position-stop-dist");
    let pos_phase_atom = vm.get_vector("position-phase");
    let pos_dir_atom = vm.get_vector("position-direction");

    // ─ Observer/manager atoms (immutable) ─
    // decomplect:allow(inline-encoding) — observer/generalist atoms + min_opinion + delta assembly migrate to market/manager.rs
    let observer_names = ["momentum", "structure", "volume", "narrative", "regime"];
    let observer_atoms: Vec<Vector> = observer_names.iter()
        .map(|&name| vm.get_vector(name))
        .collect();
    let generalist_atom = vm.get_vector("generalist");
    let min_opinion_magnitude: f64 = 3.0 / (args.dims as f64).sqrt();

    // Risk scalar encoder — separate from thought encoder's scalar encoder
    let risk_scalar = holon::ScalarEncoder::new(args.dims);

    // ─ Run database ─
    let ledger_path = match &args.ledger {
        Some(p) => {
            if let Some(parent) = p.parent() { std::fs::create_dir_all(parent).ok(); }
            p.display().to_string()
        }
        None => {
            let ts = chrono::Utc::now().format("%Y%m%d_%H%M%S");
            std::fs::create_dir_all("runs").ok();
            format!("runs/enterprise_{}.db", ts)
        }
    };
    let ledger = init_ledger(&ledger_path);
    {
        let mut stmt = ledger.prepare("INSERT INTO meta (key,value) VALUES (?1,?2)").unwrap();
        for (k, v) in &[
            ("binary",          "enterprise"),
            ("mode", "enterprise"),
            ("dims",            &args.dims.to_string()),
            ("window",          &args.window.to_string()),
            ("horizon",         &args.horizon.to_string()),
            ("move_threshold",  &args.move_threshold.to_string()),
            ("atr_multiplier",  &args.atr_multiplier.to_string()),
            ("conviction_mode",       &args.conviction_mode),
            ("min_edge",        &args.min_edge.to_string()),
            ("decay",           &args.decay.to_string()),
            ("observe_period",  &args.observe_period.to_string()),
            ("recalib_interval",&args.recalib_interval.to_string()),
            ("min_conviction",  &args.min_conviction.to_string()),
            ("conviction_quantile",   &args.conviction_quantile.to_string()),
            ("max_candles",     &args.max_candles.to_string()),
            ("swap_fee",        &args.swap_fee.to_string()),
            ("slippage",        &args.slippage.to_string()),
            ("sizing",          &args.sizing),
        ] {
            stmt.execute(params![k, v]).ok();
        }
    }
    eprintln!("  Run database: {}", ledger_path);

    // ─ Config constants (immutable after setup) ─
    // Adaptive decay: fast forgetting during regime transitions, slow during stable periods.
    let decay_stable   = args.decay;          // CLI value (default 0.999)
    let decay_adapting = (args.decay - 0.004).max(0.990); // 0.995 for default
    let highconv_rolling_cap = 200usize;
    let max_single_position: f64 = 0.20; // max 20% of equity in one position

    // ─ Exit parameters (managed mode) ──────────────────────────────────
    let k_stop:  f64 = 3.0;
    let k_trail: f64 = 1.5;
    let k_tp:    f64 = 6.0;
    let exit_horizon: usize = (k_stop * k_stop) as usize;
    let exit_observe_interval: usize = (exit_horizon / 2).max(1);
    let rolling_cap = 1000usize;

    // ─ Loop config ─
    let total_candles = candles.len();
    let start_idx     = args.window - 1;
    let end_idx       = if args.max_candles > 0 {
        (start_idx + args.max_candles).min(total_candles)
    } else {
        total_candles
    };
    let loop_count    = end_idx - start_idx;
    let progress_every = if loop_count <= 5_000 { 500 }
                        else if loop_count <= 50_000 { 2_000 }
                        else { 10_000 };
    let bnh_entry     = candles[start_idx].close;
    let t_start = Instant::now();

    // Dynamic flip threshold config.
    let conviction_warmup = args.recalib_interval * 2;
    let conviction_window: usize = 2000;

    let kill_file = std::path::Path::new("trader-stop");

    // ─ Mutable state: one struct, one owner ─
    let mut state = EnterpriseState::new(
        args.dims,
        args.recalib_interval,
        args.initial_equity,
        args.observe_period,
        args.decay,
        &args.base_asset,
        args.max_positions,
        args.max_utilization,
        start_idx,
    );

    // Seed treasury 50/50: half USDC, half WBTC at starting price.
    // "I don't know which way the market will go — hold both."
    let seed_price = candles[args.window - 1].close;
    {
        let half = args.initial_equity / 2.0;
        let seed_quote = half / seed_price;
        *state.treasury.balances.get_mut(&args.base_asset).unwrap() = half;
        state.treasury.balances.insert(args.quote_asset.clone(), seed_quote);
    }

    ledger.execute_batch("BEGIN").ok();

    eprintln!("\n  Walk-forward: {} candles from index {}...", loop_count, start_idx);

    while state.cursor < end_idx {
        if kill_file.exists() {
            eprintln!("\n  Kill file — aborting.");
            std::fs::remove_file(kill_file).ok();
            break;
        }

        let batch_end = (state.cursor + BATCH_SIZE).min(end_idx);
        // ── Parallel: each observer encodes at their own sampled window ────
        // The manager doesn't encode — it reads expert predictions.
        // Each expert samples their own window from [12, 2016] per candle.
        // Their discriminant learns which scale's patterns predict for their
        // vocabulary. A "full" encoding at args.window is kept for the primary
        // journal (tht_journal) which still drives flip threshold + sizing.
        let n_observers = state.observers.len();

        // Expert samplers are not Send, so collect windows first
        let observer_windows: Vec<Vec<usize>> = state.observers.iter()
            .map(|exp| {
                (state.cursor..batch_end).map(|i| exp.window_sampler.sample(i).min(i + 1)).collect()
            }).collect();

        let batch_start = state.cursor;
        let tht_vecs: Vec<(usize, Vector, Vec<String>, Vec<Vector>)> = (batch_start..batch_end)
            .into_par_iter()
            .map(|i| {
                let bi = i - batch_start; // batch index

                // Primary encoding at fixed window — drives the main journal + flip threshold.
                let w_start = i.saturating_sub(args.window - 1);
                let window  = &candles[w_start..=i];
                let full = thought_encoder.encode_view(window, &vm, "full");

                // Each expert encodes at their own sampled window.
                let observer_vecs: Vec<Vector> = (0..n_observers)
                    .map(|ei| {
                        let ew = observer_windows[ei][bi];
                        let ew_start = i.saturating_sub(ew - 1);
                        let exp_window = &candles[ew_start..=i];
                        thought_encoder.encode_view(exp_window, &vm, observer_names[ei]).thought
                    })
                    .collect();
                (i, full.thought, full.fact_labels, observer_vecs)
            })
            .collect();

        // ── Sequential: predict + buffer + learn + expire ────────────────────
        for (i, tht_vec, tht_facts, observer_vecs) in tht_vecs {
            state.encode_count += 1;

            // ── Expert predictions: each observer speaks ─────────────────
            // No flip. The discriminant learns what predicts — including reversals.
            // The flip was a hack for a single journal. The enterprise lets each
            // expert's discriminant encode the full pattern naturally.
            let observer_preds: Vec<Prediction> = observer_vecs.iter().enumerate()
                .map(|(ei, vec)| state.observers[ei].journal.predict(vec))
                .collect();

            // The generalist still encodes for backward compatibility
            // (flip threshold, resolved_preds tracking, DB logging).
            // But direction and conviction now come from the expert panel.
            let tht_pred = state.tht_journal.predict(&tht_vec);

            // ── Manager: encodes expert opinions via manager.rs ──────────
            // Single canonical encoding path. See manager.rs and wat/manager.wat.
            let obs_curve_valid: Vec<bool> = state.observers.iter().map(|o| o.curve_valid).collect();
            let obs_resolved_lens: Vec<usize> = state.observers.iter().map(|o| o.resolved.len()).collect();
            let obs_resolved_accs: Vec<f64> = state.observers.iter().map(|o| {
                let len = o.resolved.len();
                if len == 0 { 0.0 } else {
                    o.resolved.iter().filter(|(_, c)| *c).count() as f64 / len as f64
                }
            }).collect();
            let mgr_ctx = ManagerContext {
                observer_preds: &observer_preds,
                observer_atoms: &observer_atoms,
                observer_curve_valid: &obs_curve_valid,
                observer_resolved_lens: &obs_resolved_lens,
                observer_resolved_accs: &obs_resolved_accs,
                observer_vecs: &observer_vecs,
                generalist_pred: &tht_pred,
                generalist_atom: &generalist_atom,
                generalist_curve_valid: state.curve_valid,
                candle_atr: candles[i].atr_r,
                candle_hour: parse_candle_hour(&candles[i].ts),
                candle_day: parse_candle_day(&candles[i].ts),
                disc_strength: state.tht_journal.last_disc_strength(),
            };
            let mgr_facts = encode_manager_thought(&mgr_ctx, &mgr_atoms, &mgr_scalar, min_opinion_magnitude);

            // Difference: what changed since last candle?
            // The manager sees motion, not just position.
            let mgr_refs: Vec<&Vector> = mgr_facts.iter().collect();
            let (mgr_pred, stored_mgr_thought) = if mgr_refs.is_empty() {
                (Prediction::default(), None)
            } else {
                let mgr_thought = Primitives::bundle(&mgr_refs);
                let final_thought = if let Some(ref prev) = state.prev_mgr_thought {
                    let delta = Primitives::difference(prev, &mgr_thought);
                    let delta_bound = Primitives::bind(&mgr_atoms.delta, &delta);
                    Primitives::bundle(&[&mgr_thought, &delta_bound])
                } else {
                    mgr_thought.clone()
                };
                state.prev_mgr_thought = Some(mgr_thought);
                let pred = state.mgr_journal.predict(&final_thought);
                (pred, Some(final_thought))
            };

            // Panel state for engram (Template 2 — reaction layer)
            let mut panel_state: Vec<f64> = observer_preds.iter()
                .map(|ep| ep.raw_cos).collect();
            panel_state.push(tht_pred.raw_cos); // generalist's voice
            // dead-thoughts:allow(scaffolding) — panel_familiar computed for display only; wired when panel engram drives decisions
            let panel_familiar = if state.panel_engram.n() >= 10 {
                let residual = state.panel_engram.residual(&panel_state);
                let threshold = state.panel_engram.threshold();
                residual < threshold
            } else {
                false
            };

            // Manager's prediction drives direction + conviction.
            let raw_meta_dir = mgr_pred.direction;
            let meta_conviction = mgr_pred.conviction;

            // Track conviction history for dynamic threshold computation.
            // Window spans recalib_interval * 100 candles (~6 months at 5m).
            // Large enough to be stable across week-to-week regime noise;
            // small enough to adapt as market structure shifts over quarters.
            state.conviction_history.push_back(meta_conviction);
            if state.conviction_history.len() > conviction_window {
                state.conviction_history.pop_front();
            }
            // Recompute flip threshold every recalib_interval candles, after warmup.
            // decomplect:allow(inline-computation) — flip threshold curve fitting, extracts to sizing module
            if state.conviction_history.len() >= conviction_warmup
                && state.encode_count % args.recalib_interval == 0
            {
                match args.conviction_mode.as_str() {
                    "quantile" if args.conviction_quantile > 0.0 => {
                        let mut sorted: Vec<f64> = state.conviction_history.iter().copied().collect();
                        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                        let idx = ((sorted.len() as f64 * args.conviction_quantile) as usize)
                            .min(sorted.len() - 1);
                        state.conviction_threshold = sorted[idx];
                    }
                    "auto" if state.resolved_preds.len() >= conviction_warmup * 5 => {
                        // Need 5× warmup (~5000 resolved) for stable exponential fit.
                        // Fit the exponential conviction-accuracy curve:
                        //   accuracy = 0.50 + a × exp(b × conviction)
                        // Then solve for threshold: conv = ln((min_edge - 0.50) / a) / b
                        //
                        // Bin resolved predictions, compute per-bin accuracy,
                        // log-linear regression on bins where accuracy > 0.50.
                        let n_bins = 20usize;
                        let mut sorted: Vec<(f64, bool)> = state.resolved_preds.iter().copied().collect();
                        sorted.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
                        let bin_size = sorted.len() / n_bins;
                        if bin_size >= 20 {
                            // Compute (mean_conviction, accuracy) per bin.
                            let mut bins: Vec<(f64, f64)> = Vec::new();
                            for bi in 0..n_bins {
                                let start = bi * bin_size;
                                let end = if bi == n_bins - 1 { sorted.len() } else { (bi + 1) * bin_size };
                                let slice = &sorted[start..end];
                                let mean_c: f64 = slice.iter().map(|(c, _)| c).sum::<f64>() / slice.len() as f64;
                                let acc: f64 = slice.iter().filter(|(_, w)| *w).count() as f64 / slice.len() as f64;
                                bins.push((mean_c, acc));
                            }

                            // Log-linear regression on bins where acc > 0.505.
                            // y = ln(acc - 0.50), x = conviction → y = ln(a) + b*x
                            let points: Vec<(f64, f64)> = bins.iter()
                                .filter(|(_, acc)| *acc > 0.505)
                                .map(|(c, acc)| (*c, (acc - 0.50).ln()))
                                .filter(|(_, y)| y.is_finite())
                                .collect();

                            if points.len() >= 3 {
                                let n = points.len() as f64;
                                let sx: f64 = points.iter().map(|(x, _)| x).sum();
                                let sy: f64 = points.iter().map(|(_, y)| y).sum();
                                let sxx: f64 = points.iter().map(|(x, _)| x * x).sum();
                                let sxy: f64 = points.iter().map(|(x, y)| x * y).sum();
                                let denom = n * sxx - sx * sx;
                                if denom.abs() > 1e-10 {
                                    let b = (n * sxy - sx * sy) / denom;
                                    let ln_a = (sy - b * sx) / n;
                                    let a = ln_a.exp();

                                    // Solve: min_edge = 0.50 + a * exp(b * conv)
                                    // conv = ln((min_edge - 0.50) / a) / b
                                    if b > 0.0 && args.min_edge > 0.50 {
                                        let target = (args.min_edge - 0.50) / a;
                                        if target > 0.0 {
                                            let new_thresh = target.ln() / b;
                                            if new_thresh > 0.0 && new_thresh < 1.0 {
                                                state.conviction_threshold = new_thresh;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Fallback: during auto warmup, use quantile if available.
                    "auto" if args.conviction_quantile > 0.0
                        && state.conviction_history.len() >= conviction_warmup => {
                        let mut sorted: Vec<f64> = state.conviction_history.iter().copied().collect();
                        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                        let idx = ((sorted.len() as f64 * args.conviction_quantile) as usize)
                            .min(sorted.len() - 1);
                        state.conviction_threshold = sorted[idx];
                    }
                    _ => {}
                }
            }

            // No flip. The enterprise doesn't invert its own decisions.
            // The experts' discriminants learn the full pattern — including reversals.
            // The manager reads their opinions and decides whether to deploy.
            // If reversal behavior emerges, it emerges from the experts' learning.
            let meta_dir = raw_meta_dir;

            // ── Position management: tick all open positions ─────────
            let quote_price = candles[i].close;
            let fee_rate = args.swap_fee + args.slippage;
            // Treasury equity: the source of truth. Token-agnostic.
            let prices = state.treasury.price_map(&[(&args.quote_asset, quote_price)]);
            let treasury_equity = state.treasury.total_value(&prices);
            if treasury_equity > state.peak_treasury_equity {
                state.peak_treasury_equity = treasury_equity;
            }
            // ── Exit expert: encode each position's state, predict, learn ──
            // Resolve pending exit observations (did holding improve the position?)
            // Two-phase: collect resolved, then learn + drain. Avoids borrow conflict
            // between exit_pending (mut), positions (shared), and exit_journal (mut).
            {
                let mut resolved_exit_indices: Vec<usize> = Vec::new();
                for (idx, obs) in state.exit_pending.iter().enumerate() {
                    if i - obs.snapshot_candle >= exit_horizon {
                        resolved_exit_indices.push(idx);
                    }
                }
                for &idx in resolved_exit_indices.iter().rev() {
                    let obs = state.exit_pending.remove(idx);
                    if let Some(pos) = state.positions.iter().find(|p| p.id == obs.pos_id) {
                        let current_pnl = pos.return_pct(quote_price);
                        let improved = current_pnl > obs.snapshot_pnl;
                        let label = if improved { state.exit_hold } else { state.exit_exit };
                        state.exit_journal.observe(&obs.thought, label, 1.0);
                    }
                }
            }

            for pos in state.positions.iter_mut() {
                if pos.phase == PositionPhase::Closed { continue; }

                // Exit expert: encode at Nyquist rate of position lifecycle
                if pos.candles_held > 0 && pos.candles_held % exit_observe_interval == 0 {
                    let pnl_frac = pos.return_pct(quote_price);
                    let mfe_frac = (pos.high_water - pos.entry_price) / pos.entry_price;
                    let stop_dist = (quote_price - pos.trailing_stop).abs() / quote_price;
                    let exit_thought = Primitives::bundle(&[
                        &Primitives::bind(&pos_pnl_atom, &exit_scalar.encode(pnl_frac.clamp(-1.0, 1.0) * 0.5 + 0.5, ScalarMode::Linear { scale: 1.0 })),
                        &Primitives::bind(&pos_hold_atom, &exit_scalar.encode_log(pos.candles_held as f64)),
                        &Primitives::bind(&pos_mfe_atom, &exit_scalar.encode(mfe_frac.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
                        &Primitives::bind(&pos_atr_entry_atom, &exit_scalar.encode_log(pos.entry_atr.max(1e-10))),
                        &Primitives::bind(&pos_atr_now_atom, &exit_scalar.encode_log(candles[i].atr_r.max(1e-10))),
                        &Primitives::bind(&pos_stop_dist_atom, &exit_scalar.encode(stop_dist.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
                        &Primitives::bind(&pos_phase_atom, &vm.get_vector(if pos.phase == PositionPhase::Runner { "runner" } else { "active" })),
                        &Primitives::bind(&pos_dir_atom, &vm.get_vector(if pos.direction == Direction::Long { "buy" } else { "sell" })),
                    ]);

                    // Buffer observation for resolution
                    state.exit_pending.push(ExitObservation {
                        thought: exit_thought.clone(),
                        pos_id: pos.id,
                        snapshot_pnl: pnl_frac,
                        snapshot_candle: i,
                    });

                }

                if let Some(exit) = pos.tick(quote_price, k_trail) {
                    match exit {
                        PositionExit::TakeProfit if pos.phase == PositionPhase::Active => {
                            // Partial exit: reclaim capital + fees + minimum profit
                            let reclaim_base = pos.base_deployed + pos.total_fees + pos.base_deployed * 0.01;
                            let reclaim_quote = reclaim_base / quote_price / (1.0 - fee_rate);
                            if reclaim_quote < pos.quote_held {
                                // Partial: release from deployed, then sell
                                state.treasury.release(&args.quote_asset, reclaim_quote);
                                let (sold, received) = state.treasury.swap(&args.quote_asset, &args.base_asset,
                                    reclaim_quote, 1.0 / quote_price, fee_rate);
                                pos.quote_held -= sold;
                                pos.base_reclaimed += received;
                                pos.total_fees += sold * quote_price * fee_rate;
                                pos.phase = PositionPhase::Runner;
                                state.hold_swaps += 1;
                                state.hold_wins += 1;
                            } else {
                                // Full exit — release all, then sell
                                state.treasury.release(&args.quote_asset, pos.quote_held);
                                let (sold, received) = state.treasury.swap(&args.quote_asset, &args.base_asset,
                                    pos.quote_held, 1.0 / quote_price, fee_rate);
                                pos.base_reclaimed += received;
                                pos.total_fees += sold * quote_price * fee_rate;
                                pos.quote_held = 0.0;
                                pos.phase = PositionPhase::Closed;
                                state.hold_swaps += 1;
                                if pos.return_pct(quote_price) > 0.0 { state.hold_wins += 1; }
                                state.last_exit_price = quote_price;
                                state.last_exit_atr = candles[i].atr_r;
                            }
                        }
                        PositionExit::StopLoss | PositionExit::TakeProfit => {
                            // Full exit — release from deployed, then sell
                            if pos.quote_held > 0.0 {
                                state.treasury.release(&args.quote_asset, pos.quote_held);
                                let (sold, received) = state.treasury.swap(&args.quote_asset, &args.base_asset,
                                    pos.quote_held, 1.0 / quote_price, fee_rate);
                                pos.base_reclaimed += received;
                                pos.total_fees += sold * quote_price * fee_rate;
                            }
                            pos.quote_held = 0.0;
                            pos.phase = PositionPhase::Closed;
                            state.hold_swaps += 1;
                            if pos.return_pct(quote_price) > 0.0 { state.hold_wins += 1; }
                            state.last_exit_price = quote_price;
                            state.last_exit_atr = candles[i].atr_r;
                        }
                    }
                    // Log to ledger
                    let ret = pos.return_pct(quote_price);
                    let exit_dir = match pos.direction { Direction::Long => "Buy", Direction::Short => "Sell" };
                    let exit_type = match (exit, pos.phase) {
                        (PositionExit::TakeProfit, PositionPhase::Runner) => "RunnerTP",
                        (PositionExit::TakeProfit, _) => "PartialProfit",
                        (PositionExit::StopLoss, _) => "StopLoss",
                    };
                    ledger.execute(
                        "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,exit_price,gross_return_pct,position_usd,swap_fee_pct,horizon_candles,won,exit_reason)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                        rusqlite::params![
                            state.log_step, i as i64, &candles[i].ts,
                            exit_dir, pos.entry_price, quote_price,
                            ret * 100.0, pos.base_deployed,
                            fee_rate * 100.0, pos.candles_held as i64,
                            (ret > 0.0) as i32,
                            exit_type,
                        ],
                    ).ok();
                }
            }
            // Remove closed positions
            state.positions.retain(|p| p.phase != PositionPhase::Closed);

            // ── Open new position: manager BUY in proven band ────────
            let in_proven_band = meta_conviction >= state.mgr_proven_band.0
                && meta_conviction < state.mgr_proven_band.1;
            // Cooldown: has the market moved enough since last exit?
            // Not a timer — a condition. The market tells us when it's ready.
            let market_moved = if state.last_exit_price > 0.0 {
                let move_since_exit = (quote_price - state.last_exit_price).abs() / state.last_exit_price;
                move_since_exit > k_stop * state.last_exit_atr
            } else {
                true // no prior exit — ready
            };
            // ── Open position: BUY or SELL in proven band ──────────────
            // One path for both directions. The direction determines which
            // asset to deploy. Everything else is the same.
            let risk_allows = state.cached_risk_mult > 0.3;
            let should_open = args.asset_mode == "hold"
                && state.portfolio.phase != Phase::Observe
                && state.mgr_curve_valid && in_proven_band && market_moved && risk_allows
                && (meta_dir == Some(state.mgr_buy) || meta_dir == Some(state.mgr_sell));

            if should_open {
                let expected_move = candles[i].atr_r * 6.0;
                if expected_move > 2.0 * fee_rate {
                    let band_edge: f64 = 0.03;
                    let frac = ((band_edge / 2.0) * state.cached_risk_mult).min(max_single_position);
                    let dir_label = meta_dir.unwrap();
                    let direction = if dir_label == state.mgr_buy { Direction::Long } else { Direction::Short };

                    let (from_asset, to_asset, deploy_amount, price_for_swap) = match direction {
                        Direction::Long => {
                            let avail = state.treasury.balance(&args.base_asset);
                            (args.base_asset.as_str(), args.quote_asset.as_str(), avail * frac, quote_price)
                        }
                        Direction::Short => {
                            let avail = state.treasury.balance(&args.quote_asset);
                            let amount = avail * frac;
                            (args.quote_asset.as_str(), args.base_asset.as_str(), amount, 1.0 / quote_price)
                        }
                    };

                    let base_value = if direction == Direction::Long { deploy_amount }
                                     else { deploy_amount * quote_price };

                    if base_value > 10.0 {
                        let (spent, received) = state.treasury.swap(
                            from_asset, to_asset, deploy_amount, price_for_swap, fee_rate);

                        // BUY: claim WBTC. SELL: USDC already in balance.
                        if direction == Direction::Long {
                            state.treasury.claim(&args.quote_asset, received);
                        }

                        let entry_fee = base_value * fee_rate;
                        let (deployed_usd, quote_held) = match direction {
                            Direction::Long => (spent, received),
                            Direction::Short => (spent * quote_price, 0.0),
                        };
                        let pos = ManagedPosition::new(
                            state.next_position_id, i, quote_price, candles[i].atr_r,
                            direction, deployed_usd, quote_held, entry_fee,
                            k_stop, k_tp,
                        );
                        state.next_position_id += 1;
                        state.hold_swaps += 1;
                        let dir_str = if direction == Direction::Long { "Buy" } else { "Sell" };
                        ledger.execute(
                            "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,position_usd,swap_fee_pct,exit_reason)
                             VALUES (?1,?2,?3,?4,?5,?6,?7,'Open')",
                            rusqlite::params![state.log_step, i as i64, &candles[i].ts, dir_str, quote_price, base_value, fee_rate * 100.0],
                        ).ok();
                        state.positions.push(pos);
                    }
                }
            }

            // Position sizing: Kelly from the curve × drawdown cap.
            // The curve handles selectivity. The drawdown cap handles survival.
            // Nothing else. No graduated gate, no stability gate, no phase gate.
            // Risk branch: compute only at recalib intervals (not every candle).
            // Between recalibs, reuse the last risk_mult.
            if state.encode_count % args.recalib_interval == 0 || state.encode_count < 100 {
                let branch_features = state.portfolio.risk_branch_wat(&vm, &risk_scalar);
                let mut worst_ratio = 1.0_f64;
                let healthy = state.portfolio.is_healthy() && state.portfolio.trades_taken >= 20;
                for (bi, branch) in state.risk_branches.iter_mut().enumerate() {
                    let features = &branch_features[bi];
                    if branch.subspace.n() >= 10 {
                        let residual = branch.subspace.residual(features);
                        let threshold = branch.subspace.threshold();
                        let ratio = if residual < threshold { 1.0 }
                            else { (threshold / residual).max(0.1) };
                        worst_ratio = worst_ratio.min(ratio);
                    }
                    if healthy { branch.subspace.update(features); }
                }
                state.cached_risk_mult = if state.risk_branches[0].subspace.n() >= 10 {
                    worst_ratio
                } else { 0.5 };
            }
            let risk_mult = state.cached_risk_mult;

            // The treasury doesn't move until the portfolio has proven edge.
            // Two requirements:
            // 1. Past the observe period (enough data to form a discriminant)
            // 2. Curve is valid (the conviction-accuracy relationship exists)
            // Before both are met, predictions are hypothetical — recorded in the
            // ledger but the treasury withholds capital.
            let portfolio_proven = state.portfolio.phase != Phase::Observe && state.mgr_curve_valid;
            let position_frac = if meta_dir.is_some()
                && portfolio_proven
                && (state.conviction_threshold <= 0.0 || meta_conviction >= state.conviction_threshold)
            {
                let mt = if args.atr_multiplier > 0.0 {
                    args.atr_multiplier * candles[i].atr_r
                } else { args.move_threshold };

                match args.sizing.as_str() {
                    "kelly" => {
                        // Fast path: evaluate cached curve params. No sorting.
                        let kelly_result = if state.curve_valid && state.cached_curve_b > 0.0 {
                            let win_rate = (0.50 + state.cached_curve_a * (state.cached_curve_b * meta_conviction).exp()).min(0.95);
                            let edge = 2.0 * win_rate - 1.0;
                            if edge > 0.0 {
                                let half_kelly_risk = edge / 2.0;
                                Some(half_kelly_risk / mt)
                            } else { None }
                        } else { None };
                        match kelly_result {
                            Some(frac) => {
                                let frac = frac.min(1.0);
                                let dd = if state.peak_treasury_equity > 0.0 {
                                    (state.peak_treasury_equity - treasury_equity) / state.peak_treasury_equity
                                } else { 0.0 };
                                let dd_room = (args.max_drawdown - dd).max(0.0);
                                let cap = (dd_room / (4.0 * mt)).min(1.0);
                                let sized = frac.min(cap) * risk_mult;
                                // NEVER zero. Always learn. Minimum 1% position.
                                // The wat machine never quits — it gets quiet.
                                let min_bet = 0.01;
                                Some(sized.max(min_bet))
                            }
                            None => None
                        }
                    }
                    _ => {
                        // Legacy sizing with flip zone gate
                        if state.conviction_threshold > 0.0 && meta_conviction < state.conviction_threshold {
                            None
                        } else {
                            state.portfolio.position_frac(meta_conviction, args.min_conviction, state.conviction_threshold)
                        }
                    }
                }
            } else { None };

            // decomplect:allow(braided-concerns) — open_position reserves capital on Pending path, ManagedPosition claims/swaps separately. Two accounting paths for one trade. Unify when position lifecycle is refactored.
            // Treasury allocation: reserve capital for this position.
            let deployed_usd = if let Some(frac) = position_frac {
                state.treasury.open_position(state.treasury.allocatable() * frac)
            } else {
                0.0
            };

            state.pending.push_back(Pending {
                candle_idx:    i,
                year:          candles[i].year,
                tht_vec,
                tht_pred:      tht_pred.clone(),
                raw_meta_dir:  raw_meta_dir,
                meta_dir,
                high_conviction:   state.conviction_threshold > 0.0 && meta_conviction >= state.conviction_threshold,
                meta_conviction,
                position_frac,
                observer_vecs,
                observer_preds,
                mgr_thought:   stored_mgr_thought,
                fact_labels:   tht_facts,
                first_outcome: None,
                outcome_pct:   0.0,
                entry_price:       candles[i].close,
                max_favorable:     0.0,
                max_adverse:       0.0,
                peak_abs_pct:      0.0,
                crossing_candle:   None,
                path_candles:      0,
                trailing_stop:     -(k_stop * candles[i].atr_r), // stop at K× ATR from this candle
                exit_reason:       None,
                exit_pct:          0.0,
                deployed_usd,
            });

            // Decay once per candle.
            state.tht_journal.decay(state.adaptive_decay);
            state.mgr_journal.decay(state.adaptive_decay);
            for observer in &mut state.observers {
                observer.journal.decay(args.decay);
            }

            // ── Event-driven learning ─────────────────────────────────────
            // Snapshot recalib counts before scanning so we can detect if
            // any recalibration fired during this candle's learning.
            let tht_recalib_before = state.tht_journal.recalib_count();

            let current_price = candles[i].close;
            for entry in state.pending.iter_mut() {
                let entry_price = candles[entry.candle_idx].close;
                let pct         = (current_price - entry_price) / entry_price;
                let abs_pct     = pct.abs();

                if abs_pct > entry.peak_abs_pct { entry.peak_abs_pct = abs_pct; }
                entry.path_candles = i - entry.candle_idx;

                // Track directional excursion relative to predicted direction.
                let directional_pct = if entry.meta_dir == Some(state.tht_buy) {
                    pct
                } else if entry.meta_dir == Some(state.tht_sell) {
                    -pct
                } else {
                    pct.abs() // no direction → track absolute
                };
                if directional_pct > entry.max_favorable {
                    entry.max_favorable = directional_pct;
                }
                if directional_pct < entry.max_adverse {
                    entry.max_adverse = directional_pct; // most negative = worst drawdown
                }

                // ── Trade management: trailing stop + take profit ────────
                // Each trade has its own parameters from ATR at entry time.
                // No averaging. No calcification. The market at entry tells
                // each trade how much room it needs.
                //
                // Managed exits: the market closes the trade, not the clock.
                if entry.exit_reason.is_none()
                    && entry.position_frac.is_some()
                    && state.portfolio.phase != Phase::Observe
                {
                    // This trade's ATR at entry — how volatile was the market when we entered?
                    let entry_atr = candles[entry.candle_idx].atr_r;

                    // Raise the floor: trail follows favorable movement.
                    let trail = k_trail * entry_atr;
                    let new_stop = entry.max_favorable - trail;
                    if new_stop > entry.trailing_stop {
                        entry.trailing_stop = new_stop;
                    }

                    // Check exits (priority: take profit > stop loss)
                    let tp = k_tp * entry_atr;
                    if directional_pct >= tp {
                        entry.exit_reason = Some(ExitReason::TakeProfit);
                        entry.exit_pct = pct;
                    } else if directional_pct <= entry.trailing_stop {
                        entry.exit_reason = Some(ExitReason::TrailingStop);
                        entry.exit_pct = pct;
                    }
                }

                // Learn only on the first threshold crossing per pending entry.
                if entry.first_outcome.is_none() {
                    let thresh = if args.atr_multiplier > 0.0 {
                        let entry_atr = candles[entry.candle_idx].atr_r;
                        args.atr_multiplier * entry_atr
                    } else {
                        args.move_threshold
                    };
                    let outcome = if pct > thresh       { Some(state.tht_buy)  }
                                  else if pct < -thresh { Some(state.tht_sell) }
                                  else                  { None };

                    if let Some(o) = outcome {
                        entry.crossing_candle = Some(i);
                        let sw = signal_weight(abs_pct, &mut state.move_sum, &mut state.move_count);
                        state.tht_journal.observe(&entry.tht_vec, o, sw);
                        // Manager does NOT learn here. Manager learns Buy/Sell (direction)
                        // at first-crossing in the resolution block below.
                        // wat/manager.wat: "Does NOT know about costs."
                        // Observer resolution: learn, track, gate, validate, log.
                        // Each observer resolves its prediction against the outcome.
                        for (ei, expert_vec) in entry.observer_vecs.iter().enumerate() {
                            if let Some(log) = state.observers[ei].resolve(
                                expert_vec, &entry.observer_preds[ei], o, sw,
                                args.conviction_quantile, conviction_window,
                            ) {
                                if args.diagnostics { ledger.execute(
                                    "INSERT INTO observer_log (step,observer,conviction,direction,correct)
                                     VALUES (?1,?2,?3,?4,?5)",
                                    params![state.log_step, log.name, log.conviction,
                                            state.observers[ei].journal.label_name(log.direction).unwrap_or("?"), log.correct as i32],
                                ).ok(); }
                            }
                        }
                        entry.first_outcome = Some(o);
                        entry.outcome_pct   = pct;
                    }
                }
            }

            // Log any recalibrations that fired during this candle's learning.
            if state.tht_journal.recalib_count() != tht_recalib_before {
                // Pre-compute curve params for Kelly — once per recalib, not per trade.
                // Uses the generalist's resolved_preds for the curve fit.
                if let Some((_, a, b)) = kelly_frac(0.15, &state.resolved_preds, 50,
                    if args.atr_multiplier > 0.0 { args.atr_multiplier * candles[i].atr_r } else { args.move_threshold }) {
                    state.cached_curve_a = a;
                    state.cached_curve_b = b;
                    state.curve_valid = true;
                }
                // Manager's own proof: band-based, not exponential.
                // decomplect:allow(inline-computation) — manager band proof, extracts to market/manager.rs
                // Find the conviction band where accuracy > 51% with 500+ samples.
                // The sweet spot is at 5-10σ (geometric property of dims).
                // The manager acts only in its proven band.
                if state.mgr_resolved.len() >= 500 {
                    let sigma = 1.0 / (args.dims as f64).sqrt();
                    // Scan bands: [k*sigma, (k+2)*sigma] for k in 3..20
                    let mut best_acc = 0.5_f64;
                    let mut best_band = (0.0_f64, 0.0_f64);
                    let mut best_n = 0usize;
                    for k in (3..18).step_by(1) {
                        let lo = k as f64 * sigma;
                        let hi = (k + 4) as f64 * sigma; // 4σ wide bands
                        let in_band: Vec<&(f64, bool)> = state.mgr_resolved.iter()
                            .filter(|(c, _)| *c >= lo && *c < hi).collect();
                        let n = in_band.len();
                        if n >= 200 {
                            let acc = in_band.iter().filter(|(_, c)| *c).count() as f64 / n as f64;
                            if acc > best_acc {
                                best_acc = acc;
                                best_band = (lo, hi);
                                best_n = n;
                            }
                        }
                    }
                    if best_acc > 0.51 && best_n >= 200 {
                        state.mgr_curve_valid = true;
                        state.mgr_proven_band = best_band;
                    } else {
                        state.mgr_curve_valid = false;
                        state.mgr_proven_band = (0.0, 0.0);
                    }
                }

                // Feed panel engram: if recent panel accuracy was good, store current state.
                if state.panel_recalib_total >= 10 {
                    let acc = state.panel_recalib_wins as f64 / state.panel_recalib_total as f64;
                    if acc > 0.55 {
                        state.panel_engram.update(&panel_state);
                    }
                }
                state.panel_recalib_wins = 0;
                state.panel_recalib_total = 0;

                ledger.execute(
                    "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count)
                     VALUES (?1,?2,?3,?4,?5,?6)",
                    params![
                        state.encode_count as i64, "thought",
                        state.tht_journal.last_cos_raw(), state.tht_journal.last_disc_strength(),
                        state.tht_journal.label_count(state.tht_buy) as i64, state.tht_journal.label_count(state.tht_sell) as i64,
                    ],
                ).ok();

                // Decode thought discriminant against the fact codebook.
                if let Some(disc) = state.tht_journal.discriminant(state.tht_buy) {
                    let disc_vec = Vector::from_f64(disc);
                    let mut decoded: Vec<(String, f64)> = codebook_vecs.iter().zip(codebook_labels.iter())
                        .map(|(v, l)| (l.clone(), holon::Similarity::cosine(&disc_vec, v)))
                        .collect();
                    decoded.sort_by(|a, b| b.1.abs().partial_cmp(&a.1.abs()).unwrap());
                    for (rank, (label, cos)) in decoded.iter().take(20).enumerate() {
                        ledger.execute(
                            "INSERT INTO disc_decode (step,journal,rank,fact_label,cosine)
                             VALUES (?1,?2,?3,?4,?5)",
                            params![
                                state.encode_count as i64, "thought",
                                (rank + 1) as i64, label, cos,
                            ],
                        ).ok();
                    }
                }

            }

            // ── Resolve entries: managed exit OR horizon expiry ──────────
            // Horizon is the safety valve, not the exit strategy.
            // The market closes the trade (stop/TP). The horizon only controls
            // learning labels. Safety max (10× horizon) prevents unbounded queue growth.
            let max_pending_age = args.horizon * 10;
            let mut resolved_indices: Vec<usize> = Vec::new();
            for (qi, entry) in state.pending.iter().enumerate() {
                let age = i - entry.candle_idx;
                let safety_expired = age >= max_pending_age;
                let market_exited = entry.exit_reason.is_some();
                if safety_expired || market_exited {
                    resolved_indices.push(qi);
                }
            }
            // Drain in reverse order to preserve indices.
            let mut resolved_entries: Vec<Pending> = Vec::new();
            for &qi in resolved_indices.iter().rev() {
                // VecDeque::remove returns Option, but we just found these indices
                if let Some(entry) = state.pending.remove(qi) {
                    resolved_entries.push(entry);
                }
            }
            resolved_entries.reverse(); // restore chronological order

            for mut entry in resolved_entries {
                // Set exit reason for horizon expiry if not already managed-exited.
                if entry.exit_reason.is_none() {
                    entry.exit_reason = Some(ExitReason::HorizonExpiry);
                    // Exit at current price for horizon expiry
                    let entry_price = candles[entry.candle_idx].close;
                    entry.exit_pct = (current_price - entry_price) / entry_price;
                }
                let final_out: Option<Label> = entry.first_outcome;
                let entry_candle = &candles[entry.candle_idx];

                if final_out.is_none() {
                    state.noise_count += 1;
                } else {
                    state.labeled_count += 1;
                }

                // Rolling accuracy per journal (non-Noise only).
                if let Some(outcome) = final_out {
                    if let Some(td) = entry.tht_pred.direction {
                        let ok = td == outcome;
                        state.tht_rolling.push_back(ok);
                        if state.tht_rolling.len() > rolling_cap { state.tht_rolling.pop_front(); }
                    }

                    // ── Manager learns from ALL non-Noise outcomes ──────────
                    // The manager doesn't need meta_dir to learn. It needs to
                    // see the expert configuration + whether following the experts
                    // would have been profitable. Breaks the deadlock: the manager
                    // learns even when it has no opinion of its own yet.
                    {
                        // Hypothetical: if we followed the majority expert direction,
                        // would it have been profitable after costs?
                        let expert_majority = {
                            let buys = entry.observer_preds.iter()
                                .filter(|ep| ep.direction == Some(state.tht_buy)).count();
                            let sells = entry.observer_preds.iter()
                                .filter(|ep| ep.direction == Some(state.tht_sell)).count();
                            if buys > sells { Some(state.tht_buy) }
                            else if sells > buys { Some(state.tht_sell) }
                            else { None }
                        };
                        if expert_majority.is_some() {
                            // Manager learns raw price direction from intensity patterns.
                            // Not "was the expert majority right?" but "did the price go up or down?"
                            // The manager maps intensity patterns → direction.
                            // Both sides are learned: the same intensity pattern that preceded UP
                            // teaches the Buy accumulator; the same pattern that preceded DOWN
                            // teaches the Sell accumulator. The discriminant separates.
                            let price_change = (current_price - candles[entry.candle_idx].close)
                                / candles[entry.candle_idx].close;
                            let mgr_label = if price_change > 0.0 { state.mgr_buy } else { state.mgr_sell };

                            // Learn from the SAME thought the manager predicted with.
                            // Stored at prediction time, delta-enriched. One encoding path.
                            if let Some(ref mgr_vec) = entry.mgr_thought {
                                state.mgr_journal.observe(mgr_vec, mgr_label, 1.0);
                            }

                            // Track for proof gate: did the manager predict the right direction?
                            // The manager predicts Buy (price up) or Sell (price down) from
                            // intensity patterns. If its prediction matches the actual direction,
                            // that's a correct call — proof the intensity pattern is useful.
                            let mgr_correct = if let Some(mgr_dir) = entry.raw_meta_dir {
                                mgr_dir == mgr_label // manager predicted the actual direction
                            } else {
                                false // no prediction = not correct
                            };
                            state.mgr_resolved.push_back((entry.meta_conviction, mgr_correct));
                            if state.mgr_resolved.len() > 5000 { state.mgr_resolved.pop_front(); }
                            state.resolved_preds.push_back((entry.meta_conviction, mgr_correct));
                            if state.resolved_preds.len() > conviction_window {
                                state.resolved_preds.pop_front();
                            }
                        }
                    }
                }

                // Every prediction goes to the ledger — hypothetical or real.
                // Traders predict on paper. The treasury decides whether to act.
                // The paper trail is how traders prove themselves.
                if let Some(dir) = entry.meta_dir {
                    let frac = entry.position_frac.unwrap_or(0.0);
                    let is_live = frac > 0.0; // treasury committed capital

                    let trade_pct = entry.exit_pct;
                    {
                        // ── Accounting: compute P&L (real or hypothetical) ────
                        let gross_ret = if dir == state.mgr_buy { trade_pct }
                            else { -trade_pct };
                        let per_swap = args.swap_fee + args.slippage;
                        let after_entry = 1.0 - per_swap;
                        let gross_value = after_entry * (1.0 + gross_ret);
                        let after_exit = gross_value * (1.0 - per_swap);
                        let net_ret = after_exit - 1.0;
                        let entry_cost_frac = per_swap;
                        let exit_cost_frac = gross_value * per_swap;

                        // Position value: real if live, hypothetical if paper
                        let pos_usd = if is_live {
                            if entry.deployed_usd > 0.0 { entry.deployed_usd }
                            else { treasury_equity * frac }
                        } else { 0.0 };
                        let trade_pnl = pos_usd * net_ret;

                        // Manager learns direction only, at first-crossing time (above).
                        // wat/manager.wat: "Does NOT know about costs."
                        // Profitability is the treasury's domain, not the manager's.

                        // ── Treasury: only moves money for live trades ───────
                        if is_live {
                            let trade_fees = pos_usd * (args.swap_fee * 2.0);
                            let trade_slip = pos_usd * (args.slippage * 2.0);
                            let trade_dir = if dir == state.mgr_buy { Direction::Long } else { Direction::Short };
                            state.portfolio.record_trade(trade_pct, frac, trade_dir, entry.year,
                                                args.swap_fee, args.slippage);
                            state.treasury.close_position(entry.deployed_usd,
                                pos_usd * gross_ret, trade_fees, trade_slip);
                        }

                        // ── Ledger: ALWAYS records. Paper trail for all. ─────
                        let exit_candle = entry.crossing_candle;
                        let exit_ts = exit_candle.map(|ci| candles[ci].ts.clone());
                        let exit_price = exit_candle.map(|ci| candles[ci].close)
                            .unwrap_or(candles[i].close);
                        let crossing_elapsed = entry.crossing_candle
                            .map(|ci| (ci - entry.candle_idx) as i64);
                        ledger.execute(
                            "INSERT INTO trade_ledger
                             (step,candle_idx,timestamp,exit_candle_idx,exit_timestamp,
                              direction,conviction,high_conviction,
                              entry_price,exit_price,position_frac,position_usd,
                              gross_return_pct,swap_fee_pct,slippage_pct,net_return_pct,
                              pnl_usd,equity_after,
                              max_favorable_pct,max_adverse_pct,
                              crossing_candles,horizon_candles,outcome,won,exit_reason)
                             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)",
                            params![
                                state.log_step, entry.candle_idx as i64, &entry_candle.ts,
                                exit_candle.map(|ci| ci as i64), exit_ts,
                                state.mgr_journal.label_name(dir).unwrap_or("?"), entry.meta_conviction,
                                entry.high_conviction as i32,
                                entry.entry_price, exit_price,
                                frac, pos_usd,
                                gross_ret * 100.0,
                                entry_cost_frac * 100.0,
                                exit_cost_frac * 100.0,
                                net_ret * 100.0, trade_pnl, treasury_equity,
                                entry.max_favorable * 100.0, entry.max_adverse * 100.0,
                                crossing_elapsed, entry.path_candles as i64,
                                final_out.map(|l| state.tht_journal.label_name(l).unwrap_or("?").to_string()).unwrap_or_else(|| "Noise".to_string()), (net_ret > 0.0) as i32,
                                match entry.exit_reason {
                                    Some(ExitReason::TrailingStop) => "TrailingStop",
                                    Some(ExitReason::TakeProfit) => "TakeProfit",
                                    Some(ExitReason::HorizonExpiry) => "HorizonExpiry",
                                    None => "HorizonExpiry",
                                },
                            ],
                        ).ok();

                        // Panel tracking (all predictions, not just live)
                        state.panel_recalib_total += 1;
                        if final_out == Some(dir) { state.panel_recalib_wins += 1; }

                        // resolved_preds is populated at first-crossing time (direction
                        // accuracy only). No second push here — the calibration curve
                        // must not mix direction and profitability signals.

                        // ── Risk/diagnostics: only for live trades ───────────
                        if is_live {
                                let dd = if state.peak_treasury_equity > 0.0 {
                                    (state.peak_treasury_equity - treasury_equity) / state.peak_treasury_equity * 100.0
                                } else { 0.0 };
                                let (streak_len, streak_dir) = {
                                    let mut len = 0i32;
                                    if let Some(&last) = state.portfolio.rolling.back() {
                                        for &o in state.portfolio.rolling.iter().rev() {
                                            if o == last { len += 1; } else { break; }
                                        }
                                    }
                                    let dir = if state.portfolio.rolling.back() == Some(&true) { "winning" } else { "losing" };
                                    (len, dir)
                                };
                                let recent_acc = if state.portfolio.rolling.len() >= 5 {
                                    state.portfolio.rolling.iter().filter(|&&x| x).count() as f64
                                        / state.portfolio.rolling.len() as f64
                                } else { 0.5 };
                                let eq_pct = (treasury_equity - args.initial_equity) / args.initial_equity * 100.0;
                                let won = (final_out == Some(dir)) as i32;
                                if args.diagnostics { ledger.execute(
                                    "INSERT INTO risk_log (step,drawdown_pct,streak_len,streak_dir,recent_acc,equity_pct,won)
                                     VALUES (?1,?2,?3,?4,?5,?6,?7)",
                                    params![state.log_step, dd, streak_len, streak_dir, recent_acc, eq_pct, won],
                                ).ok(); }
                            // Track flip-zone trade outcomes.
                            if entry.high_conviction {
                                // Adaptive decay state machine.
                                let won = final_out == Some(dir);
                                state.highconv_wins.push_back(won);
                                if state.highconv_wins.len() > highconv_rolling_cap {
                                    state.highconv_wins.pop_front();
                                }
                                if state.highconv_wins.len() >= 30 {
                                    let wr = state.highconv_wins.iter().filter(|&&w| w).count() as f64
                                           / state.highconv_wins.len() as f64;
                                    if !state.in_adaptation && wr < 0.50 {
                                        state.in_adaptation = true;
                                        state.adaptive_decay = decay_adapting;
                                    } else if state.in_adaptation && wr > 0.55 {
                                        state.in_adaptation = false;
                                        state.adaptive_decay = decay_stable;
                                    }
                                }
                            }
                            // Log which facts were present for this trade.
                            for label in &entry.fact_labels {
                                if args.diagnostics { ledger.execute(
                                    "INSERT INTO trade_facts (step, fact_label) VALUES (?1, ?2)",
                                    params![state.log_step, label],
                                ).ok(); }
                            }
                            // Store thought vectors for engram analysis.
                            if entry.high_conviction {
                                let won = (final_out == Some(dir)) as i32;
                                let tht_bytes: Vec<u8> = entry.tht_vec.data().iter()
                                    .map(|&v| v as u8).collect();
                                if args.diagnostics { ledger.execute(
                                    "INSERT INTO trade_vectors (step, won, tht_data)
                                     VALUES (?1, ?2, ?3)",
                                    params![
                                        state.log_step, won,
                                        tht_bytes,
                                    ],
                                ).ok(); }
                            }
                        } // is_live
                    }
                } // if let Some(dir)

                // Log to ledger.
                ledger.execute(
                    "INSERT INTO candle_log
                     (step,candle_idx,timestamp,
                      tht_cos,tht_conviction,tht_pred,
                      meta_pred,meta_conviction,
                      actual,traded,position_frac,equity,outcome_pct)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
                    params![
                        state.log_step, entry.candle_idx as i64, &entry_candle.ts,
                        entry.tht_pred.raw_cos, entry.tht_pred.conviction,
                        entry.tht_pred.direction.and_then(|d| state.tht_journal.label_name(d).map(|s| s.to_string())),
                        entry.meta_dir.and_then(|d| state.mgr_journal.label_name(d).map(|s| s.to_string())),
                        entry.meta_conviction,
                        final_out.and_then(|l| state.tht_journal.label_name(l).map(|s| s.to_string())).unwrap_or_else(|| "Noise".to_string()),
                        entry.position_frac.is_some() as i32,
                        entry.position_frac,
                        treasury_equity,
                        entry.outcome_pct,
                    ],
                ).ok();
                state.log_step   += 1;
                state.db_batch   += 1;
                if state.db_batch >= 5_000 {
                    ledger.execute_batch("COMMIT; BEGIN").ok();
                    state.db_batch = 0;
                }

                state.portfolio.tick_observe();
            }

            // ── Progress line ─────────────────────────────────────────────
            if state.encode_count % progress_every == 0 {
                let elapsed = t_start.elapsed().as_secs_f64();
                let rate    = state.encode_count as f64 / elapsed;
                let eta     = (loop_count - state.encode_count) as f64 / rate;
                let tht_acc = if state.tht_rolling.is_empty() { 0.0 }
                    else { state.tht_rolling.iter().filter(|&&x| x).count() as f64 / state.tht_rolling.len() as f64 * 100.0 };
                let ret = (treasury_equity - args.initial_equity) / args.initial_equity * 100.0;
                let bnh = (candles[i].close - bnh_entry) / bnh_entry * 100.0;
                let atr_now = candles[i].atr_r;
                let exit_info = format!(" | ATR={:.2}% sl={:.2}% tp={:.2}% tr={:.2}% open={}",
                    atr_now * 100.0,
                    k_stop * atr_now * 100.0,
                    k_tp * atr_now * 100.0,
                    k_trail * atr_now * 100.0,
                    state.treasury.n_open);
                eprintln!(
                    "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) vs B&H {:+.1}% | flip@{:.3} {}{}",
                    state.encode_count, loop_count, rate, eta,
                    &candles[i].ts[..10],
                    state.portfolio.phase,
                    tht_acc,
                    state.portfolio.trades_taken, state.portfolio.win_rate(),
                    treasury_equity, ret, bnh,
                    state.conviction_threshold,
                    if !state.mgr_curve_valid { "CALIBRATING" }
                    else if panel_familiar { "ENGRAM" }
                    else if state.in_adaptation { "ADAPT" }
                    else { "STABLE" },
                    exit_info,
                );
                if args.asset_mode == "hold" {
                    let tv = treasury_equity;
                    let tv_ret = (treasury_equity - args.initial_equity) / args.initial_equity * 100.0;
                    let mut proven: Vec<&str> = state.observers.iter()
                        .filter(|e| e.curve_valid).map(|e| e.name).collect();
                    if state.curve_valid { proven.push("generalist"); }
                    let proven_str = if proven.is_empty() { "none".to_string() }
                        else { proven.join(",") };
                    let band_str = if state.mgr_curve_valid {
                        format!(" band=[{:.3},{:.3}]", state.mgr_proven_band.0, state.mgr_proven_band.1)
                    } else { " band=none".to_string() };
                    let open_positions = state.positions.len();
                    eprintln!("    treasury: ${:.0} ({:+.1}%) | pos={} swaps={} wins={} | proven=[{}]{}",
                        tv, tv_ret, open_positions, state.hold_swaps, state.hold_wins, proven_str, band_str);
                }
            }
        }

        state.cursor = batch_end;
    }

    // Final treasury equity for post-loop reporting
    let final_price = candles[end_idx - 1].close;
    let prices = state.treasury.price_map(&[(&args.quote_asset, final_price)]);
    let treasury_equity = state.treasury.total_value(&prices);

    // ─ Drain remaining pending entries (log, no further learning) ────────────
    while let Some(entry) = state.pending.pop_front() {
        let final_out: Option<Label> = entry.first_outcome;
        let entry_candle = &candles[entry.candle_idx];
        if final_out.is_none() { state.noise_count += 1; } else { state.labeled_count += 1; }

        ledger.execute(
            "INSERT INTO candle_log
             (step,candle_idx,timestamp,
              tht_cos,tht_conviction,tht_pred,
              meta_pred,meta_conviction,
              actual,traded,position_frac,equity,outcome_pct)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            params![
                state.log_step, entry.candle_idx as i64, &entry_candle.ts,
                entry.tht_pred.raw_cos, entry.tht_pred.conviction,
                entry.tht_pred.direction.and_then(|d| state.tht_journal.label_name(d).map(|s| s.to_string())),
                entry.meta_dir.and_then(|d| state.mgr_journal.label_name(d).map(|s| s.to_string())),
                entry.meta_conviction,
                final_out.and_then(|l| state.tht_journal.label_name(l).map(|s| s.to_string())).unwrap_or_else(|| "Noise".to_string()),
                entry.position_frac.is_some() as i32,
                entry.position_frac,
                treasury_equity,
                entry.outcome_pct,
            ],
        ).ok();
        state.log_step += 1;
    }

    ledger.execute_batch("COMMIT").ok();

    // ─ Final summary ─────────────────────────────────────────────────────────
    let total_time = t_start.elapsed().as_secs_f64();
    let ret        = (treasury_equity - args.initial_equity) / args.initial_equity * 100.0;
    let bnh_final  = (candles[end_idx - 1].close - bnh_entry) / bnh_entry * 100.0;

    eprintln!("\n═══════════════════════════════════════════════════════════");
    eprintln!("  enterprise complete — {} candles in {:.1}s ({:.0}/s)",
        state.encode_count, total_time, state.encode_count as f64 / total_time);
    eprintln!("  Orchestration: {}", "enterprise");
    if args.swap_fee > 0.0 || args.slippage > 0.0 {
        let rt = 2.0 * (args.swap_fee + args.slippage) * 100.0;
        eprintln!("  Venue costs: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip",
            args.swap_fee * 10000.0, args.slippage * 10000.0, rt);
    }
    eprintln!("  Exit: ATR-scaled (K_stop={} K_trail={} K_tp={})", k_stop, k_trail, k_tp);
    eprintln!("  Labeled: {}  Noise: {} ({:.1}% noise rate)",
        state.labeled_count, state.noise_count,
        state.noise_count as f64 / (state.labeled_count + state.noise_count).max(1) as f64 * 100.0);
    eprintln!();
    eprintln!("  Equity: ${:.2} ({:+.2}%) | B&H: {:+.2}%",
        treasury_equity, ret, bnh_final);
    eprintln!("  Trades taken: {}  Won: {}  Win rate: {:.1}%  Skipped: {}",
        state.portfolio.trades_taken, state.portfolio.trades_won, state.portfolio.win_rate(), state.portfolio.trades_skipped);
    eprintln!("  Treasury: ${:.2} available  ${:.2} deployed  {:.1}% utilization  fees=${:.2}  slip=${:.2}",
        state.treasury.balance(&args.base_asset), state.treasury.deployed(&args.base_asset),
        state.treasury.utilization() * 100.0,
        state.treasury.total_fees_paid, state.treasury.total_slippage);
    eprintln!();
    eprintln!("  Thought journal — buy_obs={} sell_obs={} cos_raw={:.4} disc_strength={:.4} recalibs={}",
        state.tht_journal.label_count(state.tht_buy), state.tht_journal.label_count(state.tht_sell),
        state.tht_journal.last_cos_raw(), state.tht_journal.last_disc_strength(), state.tht_journal.recalib_count());
    eprintln!();

    let tht_acc = if state.tht_rolling.is_empty() { 0.0 }
        else { state.tht_rolling.iter().filter(|&&x| x).count() as f64 / state.tht_rolling.len() as f64 * 100.0 };
    eprintln!("  Rolling accuracy (last {}): thought={:.1}%",
        rolling_cap, tht_acc);
    eprintln!();

    // Observer panel summary.
    if !state.observers.is_empty() {
        eprintln!("  Observer panel:");
        for observer in &state.observers {
            eprintln!("    {}: recalibs={} disc_str={:.4} buy={} sell={}",
                observer.name,
                observer.journal.recalib_count(),
                observer.journal.last_disc_strength(),
                observer.journal.label_count(observer.primary_label),
                {
                    // sell is always the second registered label (index 1)
                    let labels = observer.journal.labels();
                    if labels.len() > 1 { observer.journal.label_count(labels[1]) } else { 0 }
                });
        }
        eprintln!();
    }

    // By-year breakdown removed — portfolio.by_year tracks trade P&L which
    // diverges from treasury value in hold mode. Treasury is the source of truth.
    // TODO: compute by-year from the treasury's value snapshots or the ledger DB.

    eprintln!("  Run DB: {} ({} rows)", ledger_path, state.log_step);
    eprintln!("═══════════════════════════════════════════════════════════");
}
