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
use holon::{VectorManager, Vector};

use enterprise::candle::load_candles;
use enterprise::treasury::Asset;
use enterprise::journal::Label;
use enterprise::thought::{ThoughtEncoder, ThoughtVocab};
use enterprise::ledger::init_ledger;
use enterprise::market::manager::{ManagerAtoms, noise_floor};
use enterprise::state::{AssetMode, CandleContext, ConvictionMode, EnterpriseState, ExitAtoms, SizingMode};

// ─── Constants ───────────────────────────────────────────────────────────────

const BATCH_SIZE: usize = 256;
const THREADS: usize = 10;
/// Decay adjustment: subtracted from CLI decay during adaptation.
const DECAY_ADJUSTMENT: f64 = 0.004;
/// Floor for adaptive decay — never forget faster than this.
const DECAY_MINIMUM: f64 = 0.990;
/// Maximum fraction of equity in a single position.
const MAX_SINGLE_POSITION: f64 = 0.20;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "enterprise", about = "Self-organizing BTC trading enterprise")]
struct Args {
    /// Source candle database (pre-computed indicators). Used when --parquet is not set.
    #[arg(long, default_value = "data/candles.db")]
    db_path: PathBuf,

    /// Raw OHLCV parquet file. When set, indicators are computed on the fly
    /// via streaming fold — no pre-computed SQLite database needed.
    #[arg(long)]
    parquet: Option<PathBuf>,

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
    #[arg(long, value_enum, default_value_t = ConvictionMode::Quantile)]
    conviction_mode: ConvictionMode,

    /// Minimum acceptable win rate for trading. This is the ONE economic input.
    /// The system finds the conviction threshold where flipped accuracy >= this value.
    /// Higher = fewer trades, higher accuracy. Lower = more trades, thinner edge.
    /// The conviction-accuracy curve is continuous and monotonic — this parameter
    /// sets the operating point. 0.55 = balanced, 0.60 = selective, 0.65 = sniper.
    #[arg(long, default_value_t = 0.55)]
    min_edge: f64,

    /// "legacy" = phase-based with 5% cap. "kelly" = half-Kelly from calibration curve.
    #[arg(long, value_enum, default_value_t = SizingMode::Legacy)]
    sizing: SizingMode,

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
    #[arg(long, value_enum, default_value_t = AssetMode::Hold)]
    asset_mode: AssetMode,

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
    let base_asset = Asset::new(&args.base_asset);
    let quote_asset = Asset::new(&args.quote_asset);

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
    let flip_desc = match args.conviction_mode {
        ConvictionMode::Auto => format!("auto(min_edge={:.2})", args.min_edge),
        ConvictionMode::Quantile => format!("q{:.0}", args.conviction_quantile * 100.0),
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

    // ─ Load candles ─
    let t0 = Instant::now();
    let candles = if let Some(ref parquet_path) = args.parquet {
        eprintln!("\n  Streaming indicators from parquet {:?}...", parquet_path);
        // Indicators computed on the fly — no pre-computed SQLite needed.
        // Collected into Vec because parallel batch encoding needs random access.
        // True per-candle streaming requires per-desk window buffers (future).
        let stream = enterprise::indicators::ParquetCandleStream::open(parquet_path);
        let candles: Vec<_> = stream.collect();
        candles
    } else {
        eprintln!("\n  Loading pre-computed candles from {:?}...", args.db_path);
        load_candles(&args.db_path, "label_oracle_10")
    };
    eprintln!("  {} candles in {:.1}s", candles.len(), t0.elapsed().as_secs_f64());

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
    let exit_scalar = holon::ScalarEncoder::new(args.dims);
    let exit_atoms = ExitAtoms::new(&vm);

    // ─ Observer/manager atoms (immutable) ─
    let observer_names = enterprise::market::OBSERVER_LENSES;
    let observer_atoms: Vec<Vector> = observer_names.iter()
        .map(|lens| vm.get_vector(lens.as_str()))
        .collect();
    let generalist_atom = vm.get_vector("generalist");
    let min_opinion_magnitude: f64 = noise_floor(args.dims);

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
            ("conviction_mode",       &args.conviction_mode.to_string()),
            ("min_edge",        &args.min_edge.to_string()),
            ("decay",           &args.decay.to_string()),
            ("observe_period",  &args.observe_period.to_string()),
            ("recalib_interval",&args.recalib_interval.to_string()),
            ("min_conviction",  &args.min_conviction.to_string()),
            ("conviction_quantile",   &args.conviction_quantile.to_string()),
            ("max_candles",     &args.max_candles.to_string()),
            ("swap_fee",        &args.swap_fee.to_string()),
            ("slippage",        &args.slippage.to_string()),
            ("sizing",          &args.sizing.to_string()),
        ] {
            stmt.execute(params![k, v]).ok();
        }
    }
    eprintln!("  Run database: {}", ledger_path);

    // ─ Config constants (immutable after setup) ─
    // Adaptive decay: fast forgetting during regime transitions, slow during stable periods.
    let decay_stable   = args.decay;          // CLI value (default 0.999)
    let decay_adapting = (args.decay - DECAY_ADJUSTMENT).max(DECAY_MINIMUM);
    let highconv_rolling_cap = 200usize;
    let max_single_position: f64 = MAX_SINGLE_POSITION;

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
        &base_asset,
        args.max_positions,
        args.max_utilization,
        start_idx,
        args.window,
    );

    // Seed treasury 50/50: half USDC, half WBTC at starting price.
    // "I don't know which way the market will go — hold both."
    let seed_price = candles[args.window - 1].close;
    {
        let half = args.initial_equity / 2.0;
        let actual = state.treasury.withdraw(&base_asset, half);
        let seed_quote = actual / seed_price;
        state.treasury.deposit(&quote_asset, seed_quote);
    }

    ledger.execute_batch("BEGIN").ok();

    eprintln!("\n  Walk-forward: {} candles from index {}...", loop_count, start_idx);

    // ─ Immutable context for on_candle ─
    let ctx = CandleContext {
        dims: args.dims,
        horizon: args.horizon,
        move_threshold: args.move_threshold,
        atr_multiplier: args.atr_multiplier,
        decay: args.decay,
        recalib_interval: args.recalib_interval,
        min_conviction: args.min_conviction,
        conviction_quantile: args.conviction_quantile,
        conviction_mode: args.conviction_mode,
        min_edge: args.min_edge,
        sizing: args.sizing,
        max_drawdown: args.max_drawdown,
        swap_fee: args.swap_fee,
        slippage: args.slippage,
        asset_mode: args.asset_mode,
        base_asset: &base_asset,
        quote_asset: &quote_asset,
        initial_equity: args.initial_equity,
        diagnostics: args.diagnostics,
        k_stop,
        k_trail,
        k_tp,
        exit_horizon,
        exit_observe_interval,
        decay_stable,
        decay_adapting,
        highconv_rolling_cap,
        max_single_position,
        conviction_warmup,
        conviction_window,
        vm: &vm,
        mgr_atoms: &mgr_atoms,
        mgr_scalar: &mgr_scalar,
        exit_scalar: &exit_scalar,
        exit_atoms: &exit_atoms,
        risk_scalar: &risk_scalar,
        observer_atoms: &observer_atoms,
        generalist_atom: &generalist_atom,
        min_opinion_magnitude,
        codebook_labels: &codebook_labels,
        codebook_vecs: &codebook_vecs,
        bnh_entry,
        loop_count,
        progress_every,
        t_start,
    };

    while state.cursor < end_idx {
        if kill_file.exists() {
            eprintln!("\n  Kill file — aborting.");
            std::fs::remove_file(kill_file).ok();
            break;
        }

        let batch_end = (state.cursor + BATCH_SIZE).min(end_idx);
        // ── Parallel: each observer encodes at their own sampled window ────
        // rune:scry(scaffolding) — desks[0] references throughout the binary are
        // single-desk backtest scaffolding. With N desks, each desk gets its own
        // candle stream and encoding batch. Wired when streaming lands.
        let desk = &state.desks[0];
        let n_observers = desk.observers.len();

        // Expert samplers are not Send, so collect windows first
        let observer_windows: Vec<Vec<usize>> = desk.observers.iter()
            .map(|exp| {
                (state.cursor..batch_end).map(|i| exp.window_sampler.sample(i).min(i + 1)).collect()
            }).collect();

        let batch_start = state.cursor;
        let tht_vecs: Vec<(usize, Vec<String>, Vec<Vector>)> = (batch_start..batch_end)
            .into_par_iter()
            .map(|i| {
                let bi = i - batch_start; // batch index

                // Primary "generalist" encoding at fixed window
                // observer (index 5) and provides fact_labels for diagnostics.
                let w_start = i.saturating_sub(args.window - 1);
                let window  = &candles[w_start..=i];
                let full = thought_encoder.encode_thought(window, &vm, enterprise::market::Lens::Generalist);

                // Each observer encodes at their own sampled window.
                // The generalist (index 5) reuses the full encoding above
                // to avoid double-encoding the same view.
                let observer_vecs: Vec<Vector> = (0..n_observers)
                    .map(|ei| {
                        if observer_names[ei] == enterprise::market::Lens::Generalist {
                            full.thought.clone()
                        } else {
                            let ew = observer_windows[ei][bi];
                            let ew_start = i.saturating_sub(ew - 1);
                            let exp_window = &candles[ew_start..=i];
                            thought_encoder.encode_thought(exp_window, &vm, observer_names[ei]).thought

                        }
                    })
                    .collect();
                (i, full.fact_labels, observer_vecs)
            })
            .collect();

        // ── Sequential: predict + buffer + learn + expire ────────────────────
        for (i, fact_labels, observer_vecs) in tht_vecs {
            let event = enterprise::event::EnrichedEvent::Candle {
                candle: candles[i].clone(),
                fact_labels,
                observer_vecs,
            };
            state.on_event(event, &ctx);
        }

        // Flush log entries accumulated during this batch.
        enterprise::ledger::flush_logs(&state.desks[0].pending_logs, &ledger);
        state.desks[0].pending_logs.clear();
    }

    // Final treasury equity for post-loop reporting
    let final_price = candles[end_idx - 1].close;
    let prices = state.treasury.price_map(&[(&quote_asset, final_price)]);
    let treasury_equity = state.treasury.total_value(&prices);

    // ─ Drain remaining pending entries (log, no further learning) ────────────
    {
        let desk = &mut state.desks[0];
        let treasury = &state.treasury;
        while let Some(entry) = desk.pending.pop_front() {
            let final_out: Option<Label> = entry.crossing.as_ref().map(|c| c.label);
            if final_out.is_none() { desk.noise_count += 1; } else { desk.labeled_count += 1; }

            desk.log_candle(&entry, final_out, treasury_equity, treasury, &ctx);
        }
    }

    // Flush any remaining log entries, then commit.
    enterprise::ledger::flush_logs(&state.desks[0].pending_logs, &ledger);
    state.desks[0].pending_logs.clear();
    ledger.execute_batch("COMMIT").ok();

    // ─ Final summary ─────────────────────────────────────────────────────────
    let total_time = t_start.elapsed().as_secs_f64();
    let ret        = (treasury_equity - args.initial_equity) / args.initial_equity * 100.0;
    let bnh_final  = (candles[end_idx - 1].close - bnh_entry) / bnh_entry * 100.0;

    eprintln!("\n═══════════════════════════════════════════════════════════");
    eprintln!("  enterprise complete — {} candles in {:.1}s ({:.0}/s)",
        state.desks[0].encode_count, total_time, state.desks[0].encode_count as f64 / total_time);
    eprintln!("  Orchestration: {}", "enterprise");
    if args.swap_fee > 0.0 || args.slippage > 0.0 {
        let rt = 2.0 * (args.swap_fee + args.slippage) * 100.0;
        eprintln!("  Venue costs: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip",
            args.swap_fee * 10000.0, args.slippage * 10000.0, rt);
    }
    eprintln!("  Exit: ATR-scaled (K_stop={} K_trail={} K_tp={})", k_stop, k_trail, k_tp);
    eprintln!("  Labeled: {}  Noise: {} ({:.1}% noise rate)",
        state.desks[0].labeled_count, state.desks[0].noise_count,
        state.desks[0].noise_count as f64 / (state.desks[0].labeled_count + state.desks[0].noise_count).max(1) as f64 * 100.0);
    eprintln!();
    eprintln!("  Equity: ${:.2} ({:+.2}%) | B&H: {:+.2}%",
        treasury_equity, ret, bnh_final);
    eprintln!("  Trades taken: {}  Won: {}  Win rate: {:.1}%",
        state.portfolio.trades_taken, state.portfolio.trades_won, state.portfolio.win_rate());
    eprintln!("  Treasury: ${:.2} available  ${:.2} deployed  {:.1}% utilization  fees=${:.2}  slip=${:.2}",
        state.treasury.balance(&base_asset), state.treasury.deployed(&base_asset),
        state.treasury.utilization(&prices) * 100.0,
        state.treasury.total_fees_paid, state.treasury.total_slippage);
    eprintln!();
    {
        let gen = &state.desks[0].observers[enterprise::state::GENERALIST_IDX];
        let gen_buy = gen.primary_label;
        let gen_sell = gen.journal.labels()[1];
        eprintln!("  Thought journal — buy_obs={} sell_obs={} cos_raw={:.4} disc_strength={:.4} recalibs={}",
            gen.journal.label_count(gen_buy), gen.journal.label_count(gen_sell),
            gen.journal.last_cos_raw(), gen.journal.last_disc_strength(), gen.journal.recalib_count());
    }
    eprintln!();

    let gen_resolved = &state.desks[0].observers[enterprise::state::GENERALIST_IDX].resolved;
    let tht_acc = if gen_resolved.is_empty() { 0.0 }
        else { gen_resolved.iter().filter(|(_, c)| *c).count() as f64 / gen_resolved.len() as f64 * 100.0 };
    eprintln!("  Rolling accuracy (last {}): thought={:.1}%",
        rolling_cap, tht_acc);
    eprintln!();

    // Observer panel summary.
    if !state.desks[0].observers.is_empty() {
        eprintln!("  Observer panel:");
        for observer in &state.desks[0].observers {
            eprintln!("    {}: recalibs={} disc_str={:.4} buy={} sell={}",
                observer.lens.as_str(),
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

    eprintln!("  Run DB: {} ({} rows)", ledger_path, state.desks[0].log_step);
    eprintln!("═══════════════════════════════════════════════════════════");
}
