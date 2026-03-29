/// trader3 — Clean-slate BTC walk-forward trader.
///
/// Two named journals (visual + thought) each learn to predict direction
/// independently. An orchestration layer combines their signals.
///
/// Visual journal: learns from raster-encoded OHLCV grids.
/// Thought journal: learns from PELT segment narrative vectors.
///
/// All measurement lives in the run SQLite DB — no verbose log spam.
/// Use the DB to understand what the system is doing.
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use rusqlite::params;
use holon::{Primitives, ScalarMode, Similarity, VectorManager, Vector};
use holon::memory::OnlineSubspace;

use btc_walk::db::load_candles;
use btc_walk::journal::{Journal, Outcome, Prediction};
use btc_walk::thought::{ThoughtEncoder, ThoughtVocab, IndicatorStreams};
use btc_walk::treasury::Treasury;
use btc_walk::portfolio::{Trader, Phase, YearStats};
use btc_walk::sizing::kelly_frac;
use btc_walk::position::{Pending, ExitReason};
use btc_walk::orchestration::{orchestrate, signal_weight};
use btc_walk::run_db::init_run_db;
// Visual encoding removed — proven zero outcome clustering (cosine gap = 0.0004).
// The visual raster is an artifact of Chapter 1. Charts don't predict; thoughts predict.

// ─── Constants ───────────────────────────────────────────────────────────────

const BATCH_SIZE: usize = 256;
const THREADS: usize = 10;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "trader3", about = "BTC walk-forward trader (visual + thought journals)")]
struct Args {
    /// Source candle database (pre-computed indicators).
    #[arg(long, default_value = "../data/analysis.db")]
    db_path: PathBuf,

    /// Vector dimension. Higher = more expressive, slower.
    #[arg(long, default_value_t = 10000)]
    dims: usize,

    /// Number of candles in the visual grid (columns).
    #[arg(long, default_value_t = 48)]
    window: usize,

    /// Pixel rows per panel in the visual grid.
    #[arg(long, default_value_t = 25)]
    px_rows: usize,

    /// Candles to wait before measuring price outcome (lookahead window).
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
    /// Ignored when flip_mode = "auto".
    #[arg(long, default_value_t = 0.85)]
    flip_quantile: f64,

    /// "quantile" = use flip_quantile percentile. "auto" = find the conviction
    /// level where cumulative win rate from the top first drops below min_edge.
    #[arg(long, default_value = "quantile")]
    flip_mode: String,

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

    /// Risk gate: scale position by portfolio state.
    /// "off" = no adjustment. "binary" = trade only at peak equity.
    /// "graduated" = scale down by drawdown depth.
    #[arg(long, default_value = "off")]
    risk_gate: String,

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

    /// Trade management mode. "legacy" = exit at first threshold crossing (fire-and-forget).
    /// "managed" = trailing stop + take profit, active management each candle.
    /// Managed mode self-calibrates from the ledger: wide defaults during cold boot,
    /// tightens from MFE/MAE experience after enough trades.
    #[arg(long, default_value = "legacy")]
    exit_mode: String,

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

    /// visual-only | thought-only | agree-only | meta-boost | weighted | thought-led | thought-contrarian
    #[arg(long, default_value = "meta-boost")]
    orchestration: String,

    /// Comma-separated desk configurations: "window:horizon,window:horizon,..."
    /// Each desk runs its own thought encoder at its own time scale.
    /// Example: "48:36,200:144,1000:576" for fast/medium/slow desks.
    /// Empty string = single desk using --window and --horizon (legacy mode).
    #[arg(long, default_value = "")]
    desks: String,

    /// Output SQLite database for this run. Auto-generated if omitted.
    #[arg(long)]
    run_db: Option<PathBuf>,

    /// Enable heavy diagnostic tables (trade_facts, trade_vectors, expert_log).
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

    eprintln!("trader3: visual+thought journals, discriminant prediction");
    let thresh_desc = if args.atr_multiplier > 0.0 {
        format!("{}×ATR", args.atr_multiplier)
    } else {
        format!("{:.3}%", args.move_threshold * 100.0)
    };
    let flip_desc = match args.flip_mode.as_str() {
        "auto" => format!("auto(min_edge={:.2})", args.min_edge),
        _ => format!("q{:.0}", args.flip_quantile * 100.0),
    };
    eprintln!("  {}D  window={}  horizon={}  threshold={}  decay={}  flip={}",
        args.dims, args.window, args.horizon, thresh_desc, args.decay, flip_desc);
    eprintln!("  observe={}  recalib_interval={}  orchestration={}  min_conviction={:.3}",
        args.observe_period, args.recalib_interval, args.orchestration, args.min_conviction);
    if args.swap_fee > 0.0 || args.slippage > 0.0 {
        eprintln!("  venue: {:.1}bps fee + {:.1}bps slippage per swap ({:.2}% round trip)",
            args.swap_fee * 10000.0, args.slippage * 10000.0,
            2.0 * (args.swap_fee + args.slippage) * 100.0);
    }

    // ─ Load candles ─
    eprintln!("\n  Loading candles from {:?}...", args.db_path);
    let t0 = Instant::now();
    let candles = load_candles(&args.db_path, "label_oracle_10");
    eprintln!("  Loaded {} candles in {:.1}s", candles.len(), t0.elapsed().as_secs_f64());

    let vm = VectorManager::new(args.dims);

    // ─ Pre-warm VM vector cache ─
    for tok in &["null","gs","rs","gw","rw","dj","yl","rl","gl","wu","wl",
                 "vg","vr","rb","ro","rn","ml","ms","mhg","mhr","dp","dm","ax","set_indicator"] {
        vm.get_vector(tok);
    }
    let max_pos = args.window;
    for p in 0..max_pos as i64 { vm.get_position_vector(p); }

    // ─ Adaptive window sampler ─
    use btc_walk::window_sampler::WindowSampler;
    let window_sampler = WindowSampler::new(args.dims as u64, 12, 2016);
    // Pre-warm position vectors for the max possible window
    for p in 0..2016_i64 { vm.get_position_vector(p); }

    // ─ Visual encoding setup ─
    // Visual encoding removed. Null vector kept for Pending struct compatibility.
    let null_vec = Vector::zeros(args.dims);

    // ─ Multi-desk setup ──────────────────────────────────────────────────
    // Each desk is a business unit with its own time scale.
    // Parse --desks flag, or fall back to single desk from --window/--horizon.
    use btc_walk::desk::{Desk, DeskConfig, DeskResolved};
    let desk_configs: Vec<(usize, usize)> = if args.desks.is_empty() {
        vec![(args.window, args.horizon)]
    } else {
        args.desks.split(',').map(|s| {
            let parts: Vec<&str> = s.split(':').collect();
            let w: usize = parts[0].parse().expect("bad desk window");
            let h: usize = parts[1].parse().expect("bad desk horizon");
            (w, h)
        }).collect()
    };
    let all_profiles: Vec<&'static str> = vec!["momentum", "structure", "volume", "narrative", "regime"];
    let mut desks: Vec<Desk> = desk_configs.iter().enumerate().map(|(di, &(w, h))| {
        let name = format!("desk-{}c", w);
        let config = DeskConfig {
            name,
            window: w,
            horizon: h,
            expert_profiles: all_profiles.clone(),
        };
        // Pre-warm position vectors for this desk's window size
        for p in 0..w as i64 { vm.get_position_vector(p); }
        Desk::new(config, args.dims, args.recalib_interval, &vm)
    }).collect();
    eprintln!("  Desks: {}", desks.iter().map(|d| format!("{}(w={},h={})", d.config.name, d.window(), d.horizon())).collect::<Vec<_>>().join(", "));

    // ─ Primary desk thought encoding (legacy — uses args.window) ─
    let thought_vocab   = ThoughtVocab::new(&vm);
    let thought_encoder = ThoughtEncoder::new(thought_vocab);
    let (codebook_labels, codebook_vecs) = thought_encoder.fact_codebook();
    let thought_streams = IndicatorStreams::new(args.dims, args.window + 48);

    // ─ Named journals ─
    // Visual journal removed — Chapter 1 artifact. See BOOK.md.
    // Stub journal kept for DB logging compatibility (vis_cos/vis_pred columns).
    let mut vis_journal = Journal::new("visual-stub", args.dims, args.recalib_interval);
    let mut tht_journal = Journal::new("thought", args.dims, args.recalib_interval);

    // ─ Manager journal: thinks in expert opinions, not candle data ────
    // The manager's vocabulary = its experts. Each expert is an atom.
    // The manager's thought = bundle(bind(expert_atom, scalar(conviction))).
    // The manager's discriminant learns which expert configurations predict.
    let mut mgr_journal = Journal::new("manager", args.dims, args.recalib_interval);
    let mgr_scalar = holon::ScalarEncoder::new(args.dims);
    let mut prev_mgr_thought: Option<Vector> = None; // for difference computation
    let mgr_delta_atom = vm.get_vector("panel-delta"); // what changed since last candle
    // Temporal atoms: when is this happening?
    let hour_atom = vm.get_vector("hour-of-day");
    let day_atom = vm.get_vector("day-of-week");
    // Coherence atom: how concentrated is the panel?
    let coherence_atom = vm.get_vector("panel-coherence");

    // ─ Visual pattern memory: auto-clustering engram groups ─────────────
    // Each group is an OnlineSubspace that learns a cluster of similar visual
    // patterns from winning flip-zone trades. New groups auto-discovered when
    // a winning visual vector doesn't match any existing group.
    // Visual pattern grouping removed — visual encoding proven zero signal.
    // The old code accumulated unbounded PatternGroups with zero-vector centroids
    // (since vis_vec is always null), causing O(n_groups × dims) per flipped trade.

    // ─ Risk branch: five specialized subspaces ─────────────────────────
    // Each measures health in its own domain. The worst residual drives
    // the risk multiplier. Gated updates: only learn from healthy states.
    // Template 2 (REACTION) applied five times.
    struct RiskBranch {
        name: &'static str,
        subspace: OnlineSubspace,
    }
    // Each risk branch operates at full dimensionality — named wat vectors.
    // Atoms bound with scalar magnitudes, bundled per branch, fed to subspace.
    let mut risk_branches: Vec<RiskBranch> = vec![
        RiskBranch { name: "drawdown",    subspace: OnlineSubspace::with_params(args.dims, 8, 2.0, 0.01, 3.5, 100) },
        RiskBranch { name: "accuracy",    subspace: OnlineSubspace::with_params(args.dims, 8, 2.0, 0.01, 3.5, 100) },
        RiskBranch { name: "volatility",  subspace: OnlineSubspace::with_params(args.dims, 8, 2.0, 0.01, 3.5, 100) },
        RiskBranch { name: "correlation", subspace: OnlineSubspace::with_params(args.dims, 8, 2.0, 0.01, 3.5, 100) },
        RiskBranch { name: "panel",       subspace: OnlineSubspace::with_params(args.dims, 8, 2.0, 0.01, 3.5, 100) },
    ];

    // Risk scalar encoder — separate from thought encoder's scalar encoder
    let risk_scalar = holon::ScalarEncoder::new(args.dims);
    let mut cached_risk_mult: f64 = 0.5;
    // Cached curve params — recomputed at recalib intervals, not per trade.
    let mut cached_curve_a: f64 = 0.0;
    let mut cached_curve_b: f64 = 0.0;
    let mut curve_valid = false;
    let mut mgr_curve_valid = false;  // manager must prove its own edge
    let mut mgr_resolved: VecDeque<(f64, bool)> = VecDeque::new();
    // Band-based proof: the conviction range where the manager has proven edge.
    // The manager acts only when conviction falls in this band.
    let mut mgr_proven_band: (f64, f64) = (0.0, 0.0); // (low, high) — empty when not proven

    // ─ Expert panel: N traders, each with own vocabulary and own window ─
    // Each expert thinks different thoughts at their own time scale.
    // The manager aggregates their predictions — it does not encode.
    // Each expert discovers their optimal window through experience.
    struct Expert {
        name: &'static str,
        profile: &'static str,
        journal: Journal,
        resolved: VecDeque<(f64, bool)>,  // (conviction, correct)
        good_state_subspace: OnlineSubspace,
        recalib_wins: u32,
        recalib_total: u32,
        last_recalib_count: usize,
        window_sampler: WindowSampler,
        conviction_history: VecDeque<f64>,
        flip_threshold: f64,
        // Proof gate: the expert must prove direction accuracy before
        // its opinion flows upstream. Silence, not noise.
        curve_valid: bool,
    }
    let expert_profiles = ["momentum", "structure", "volume", "narrative", "regime"];
    let mut experts: Vec<Expert> = expert_profiles.iter().enumerate().map(|(ei, &profile)| {
        Expert {
            name: profile,
            profile,
            journal: Journal::new(profile, args.dims, args.recalib_interval),
            resolved: VecDeque::new(),
            good_state_subspace: OnlineSubspace::new(args.dims, 8),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            // Each expert gets a different seed: they explore independently.
            window_sampler: WindowSampler::new(
                args.dims as u64 + ei as u64 * 7919,
                12, 2016,
            ),
            conviction_history: VecDeque::new(),
            flip_threshold: 0.0,
            curve_valid: false,
        }
    }).collect();

    // ─ Dual thought journals: slow (deep memory) + fast (regime-adaptive) ─
    // Both learn from the same input. An OnlineSubspace monitors thought vector
    // residuals to blend between them: low residual → trust slow, high → trust fast.
    let mut tht_fast    = Journal::new("thought-fast", args.dims, args.recalib_interval);
    let decay_fast      = (args.decay - 0.004).max(0.990); // 0.995 for default 0.999

    // Thought manifold: OnlineSubspace (CCIPCA) learns the structure of thought
    // vectors over time. k=32 captures the intrinsic dimensionality of ~120 facts.
    // Fed on EVERY candle (not just trades) to learn the full manifold.
    // Residual = how novel this candle's thought pattern is.
    let mut tht_subspace = OnlineSubspace::new(args.dims, 32);
    let mut subspace_baseline_residual: f64 = 1.0;

    // Layer 2: Panel state engram — learns the manifold of "good panel configurations."
    // Encodes each expert's (signed conviction) as a feature vector.
    // Dimensionality = number of experts. Fed after each recalib if accuracy was good.
    // Manager's vocabulary = its experts + generalist + panel-level concepts.
    let expert_atoms: Vec<Vector> = expert_profiles.iter()
        .map(|&name| vm.get_vector(name))
        .collect();
    let generalist_atom = vm.get_vector("generalist");
    // Action atoms: named directions, not permutation tricks.
    let buy_atom = vm.get_vector("buy");
    let sell_atom = vm.get_vector("sell");
    // Minimum magnitude to emit an opinion. Below this, the cosine
    // projection is indistinguishable from random alignment — noise.
    // Derived from dimensionality: 3σ where σ = 1/sqrt(dims).
    // At 20k dims: 3/141.4 ≈ 0.021. Not a magic number — a property
    // of the hyperspace.
    let min_opinion_magnitude: f64 = 3.0 / (args.dims as f64).sqrt();
    // Panel-level atoms: emergent properties of the expert collective.
    let agreement_atom = vm.get_vector("panel-agreement");     // how aligned are the experts?
    let panel_energy_atom = vm.get_vector("panel-energy");     // how loud is everyone?
    let divergence_atom = vm.get_vector("panel-divergence");   // do they agree on intensity?
    // Per-expert quality atoms: HOW proven, not just proven/not.
    let reliability_atom = vm.get_vector("expert-reliability"); // accuracy level of this expert
    let tenure_atom = vm.get_vector("expert-tenure");           // how long proven
    // Context atoms: market state visible to the manager.
    let volatility_atom = vm.get_vector("market-volatility");  // ATR right now
    let disc_strength_atom = vm.get_vector("disc-strength");   // generalist's signal quality
    let panel_dim = expert_profiles.len() + 1; // experts + generalist
    let mut panel_engram = OnlineSubspace::with_params(panel_dim, 4, 2.0, 0.01, 3.5, 100);
    let mut panel_recalib_wins: u32 = 0;
    let mut panel_recalib_total: u32 = 0;

    // Curve stability: track (a, b) parameters across recalibs.
    // Trade only when both parameters stabilize (<10% change, 3 consecutive recalibs).
    let mut curve_a_history: VecDeque<f64> = VecDeque::new();
    let mut curve_b_history: VecDeque<f64> = VecDeque::new();
    let mut curve_stable = false;


    // ─ Run database ─
    let run_db_path = match &args.run_db {
        Some(p) => {
            if let Some(parent) = p.parent() { std::fs::create_dir_all(parent).ok(); }
            p.display().to_string()
        }
        None => {
            let ts = chrono::Utc::now().format("%Y%m%d_%H%M%S");
            std::fs::create_dir_all("runs").ok();
            format!("runs/trader3_{}.db", ts)
        }
    };
    let run_db = init_run_db(&run_db_path);
    {
        let mut stmt = run_db.prepare("INSERT INTO meta (key,value) VALUES (?1,?2)").unwrap();
        for (k, v) in &[
            ("binary",          "trader3"),
            ("orchestration",   args.orchestration.as_str()),
            ("dims",            &args.dims.to_string()),
            ("window",          &args.window.to_string()),
            ("horizon",         &args.horizon.to_string()),
            ("move_threshold",  &args.move_threshold.to_string()),
            ("atr_multiplier",  &args.atr_multiplier.to_string()),
            ("flip_mode",       &args.flip_mode),
            ("min_edge",        &args.min_edge.to_string()),
            ("decay",           &args.decay.to_string()),
            ("observe_period",  &args.observe_period.to_string()),
            ("recalib_interval",&args.recalib_interval.to_string()),
            ("min_conviction",  &args.min_conviction.to_string()),
            ("flip_quantile",   &args.flip_quantile.to_string()),
            ("max_candles",     &args.max_candles.to_string()),
            ("swap_fee",        &args.swap_fee.to_string()),
            ("slippage",        &args.slippage.to_string()),
            ("sizing",          &args.sizing),
        ] {
            stmt.execute(params![k, v]).ok();
        }
    }
    eprintln!("  Run database: {}", run_db_path);

    // ─ Trader and tracking ─
    let mut tht_attention: Option<Vec<f64>> = None; // thought discriminant for weighted bundling

    // Adaptive decay: fast forgetting during regime transitions, slow during stable periods.
    // STABLE (0.999): rolling flip-zone accuracy >= 50% — preserve what works.
    // ADAPTING (0.995): accuracy dropped below 50% — flush stale patterns.
    // Hysteresis: need >55% to return to STABLE (prevents oscillation).
    let decay_stable   = args.decay;          // CLI value (default 0.999)
    let decay_adapting = (args.decay - 0.004).max(0.990); // 0.995 for default
    let mut adaptive_decay = args.decay;
    let mut in_adaptation = false;
    let mut flip_zone_wins: VecDeque<bool> = VecDeque::new();
    let flip_zone_rolling_cap = 200usize;

    // Fire-rate suppression: track how often each cached fact fires.
    // Facts firing >90% of the time carry <0.15 bits and waste bundle capacity.
    let fire_rate_window = 500usize; // assess over last N candles
    let fire_rate_threshold = 0.90;
    let mut fire_counts: HashMap<String, usize> = HashMap::new();
    let mut fire_total: usize = 0;
    let mut suppressed_facts: HashSet<String> = HashSet::new();
    let mut trader    = Trader::new(args.initial_equity, args.observe_period);
    let mut treasury  = Treasury::new("USDC", args.initial_equity, args.max_positions, args.max_utilization);
    let mut pending:    VecDeque<Pending> = VecDeque::new();

    // ─ Exit parameters (managed mode) ──────────────────────────────────
    // No averaging. No percentiles. Each trade gets its own stop from the
    // market state AT ENTRY TIME. ATR tells you how much this market is
    // moving right now. The stop breathes with the market.
    //
    // Stop = K_stop × ATR_ratio at entry. Wide when volatile, tight when quiet.
    // Trail = K_trail × ATR_ratio at entry. Same principle.
    // Take profit = K_tp × ATR_ratio at entry. Capture proportional to volatility.
    //
    // During cold boot (observe period): legacy exits. "I don't know" = don't act.
    // After observe: each trade's parameters come from its own entry candle.
    let k_stop:  f64 = 3.0;  // stop at 3× ATR — "the market moved 3× its normal range against me"
    let k_trail: f64 = 1.5;  // trail at 1.5× ATR — lock in gains, give room for normal retracement
    let k_tp:    f64 = 6.0;  // take profit at 6× ATR — let winners run to meaningful moves
    let min_exit_samples = 50usize; // for ledger tracking (not used for param calibration anymore)
    let mut exit_mfe_history: VecDeque<f64> = VecDeque::new();
    let mut exit_mae_history: VecDeque<f64> = VecDeque::new();
    let exit_history_cap = 500usize;
    let mut vis_rolling: VecDeque<bool>  = VecDeque::new();
    let mut tht_rolling: VecDeque<bool>  = VecDeque::new();
    let rolling_cap = 1000usize;

    // ─ Hold-mode state: which asset does the treasury hold? ────────────
    // Starts in USDC. BUY signal = swap to WBTC. SELL signal = swap to USDC.
    // Position persists between signals. WBTC appreciates with the market.
    #[derive(Clone, Copy, PartialEq)]
    enum HoldState { InUsdc, InWbtc }
    let mut hold_state = HoldState::InUsdc;
    let mut last_swap_candle: usize = 0;
    let mut last_swap_price: f64 = 0.0;
    let mut hold_swaps: usize = 0;
    let mut hold_wins: usize = 0;

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
    let mut encode_count  = 0usize;
    let mut labeled_count = 0usize;
    let mut noise_count   = 0usize;
    let mut move_sum      = 0.0_f64;
    let mut move_count    = 0usize;
    let mut log_step      = 0i64;
    let mut db_batch      = 0usize;
    let t_start = Instant::now();

    // Dynamic flip threshold: derived from the conviction distribution.
    // Updated every recalib_interval candles after a warmup window.
    // Represents the args.flip_quantile percentile of recent meta_conviction values.
    // Rolling conviction history for dynamic threshold computation.
    // Window = ~3 months of 5m candles: large enough to be stable across
    // week-to-week regime noise, small enough to adapt to structural shifts.
    let flip_warmup = args.recalib_interval * 2;
    // Conviction window: starts at 2000 (statistically robust minimum).
    // Shrinks when curve is stable, grows when unstable.
    // The curve stability tracking we built decides the window size.
    let mut conviction_window: usize = 2000;
    let mut conviction_history: VecDeque<f64> = VecDeque::new();
    let mut flip_threshold: f64 = 0.0; // 0 until warmup complete

    // Auto flip mode: track resolved predictions to build calibration curve.
    // Each entry records (conviction, was_the_flipped_prediction_correct).
    let mut resolved_preds: VecDeque<(f64, bool)> = VecDeque::new();

    // Self-derived min_edge: track flip-zone win rate per recalib window.
    // min_edge = 0.50 + 2σ where σ = stddev of recent window win rates.
    let mut window_win_rates: VecDeque<f64> = VecDeque::new();
    let mut window_wins: u32 = 0;
    let mut window_total: u32 = 0;
    let mut derived_min_edge: f64 = args.min_edge; // start with CLI value

    let kill_file = std::path::Path::new("trader-stop");
    let mut cursor = start_idx;

    run_db.execute_batch("BEGIN").ok();

    eprintln!("\n  Walk-forward: {} candles from index {}...", loop_count, start_idx);

    while cursor < end_idx {
        if kill_file.exists() {
            eprintln!("\n  Kill file — aborting.");
            std::fs::remove_file(kill_file).ok();
            break;
        }

        let batch_end = (cursor + BATCH_SIZE).min(end_idx);
        let _batch_len = batch_end - cursor;

        // ── Parallel: each expert encodes at their own sampled window ────
        // The manager doesn't encode — it reads expert predictions.
        // Each expert samples their own window from [12, 2016] per candle.
        // Their discriminant learns which scale's patterns predict for their
        // vocabulary. A "full" encoding at args.window is kept for the primary
        // journal (tht_journal) which still drives flip threshold + sizing.
        let sup_ref = if suppressed_facts.is_empty() { None } else { Some(&suppressed_facts) };
        let n_experts = experts.len();

        // Expert samplers are not Send, so collect windows first
        let expert_windows: Vec<Vec<usize>> = experts.iter()
            .map(|exp| {
                (cursor..batch_end).map(|i| exp.window_sampler.sample(i).min(i + 1)).collect()
            }).collect();

        let tht_vecs: Vec<(usize, Vector, Vec<String>, Vec<Vector>)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let bi = i - cursor; // batch index

                // Primary encoding at fixed window — drives the main journal + flip threshold.
                let w_start = i.saturating_sub(args.window - 1);
                let window  = &candles[w_start..=i];
                let full = thought_encoder.encode_view(window, &thought_streams, 0, 0, &vm, None, sup_ref, "full");

                // Each expert encodes at their own sampled window.
                let expert_vecs: Vec<Vector> = (0..n_experts)
                    .map(|ei| {
                        let ew = expert_windows[ei][bi];
                        let ew_start = i.saturating_sub(ew - 1);
                        let exp_window = &candles[ew_start..=i];
                        thought_encoder.encode_view(exp_window, &thought_streams, 0, 0, &vm, None, None, expert_profiles[ei]).thought
                    })
                    .collect();
                (i, full.thought, full.fact_labels, expert_vecs)
            })
            .collect();
        // The desk_predictions table logs which window was used, so the
        // ledger builds the window→accuracy curve from experience.

        // ── Sequential: predict + buffer + learn + expire ────────────────────
        for (i, tht_vec, tht_facts, expert_vecs) in tht_vecs {
            encode_count += 1;

            // ── Expert predictions: each expert speaks ─────────────────
            // No flip. The discriminant learns what predicts — including reversals.
            // The flip was a hack for a single journal. The enterprise lets each
            // expert's discriminant encode the full pattern naturally.
            let expert_preds: Vec<Prediction> = expert_vecs.iter().enumerate()
                .map(|(ei, vec)| experts[ei].journal.predict(vec))
                .collect();

            let vis_vec = null_vec.clone(); // stub for Pending compatibility
            let vis_pred = Prediction::default();

            // The generalist still encodes for backward compatibility
            // (flip threshold, resolved_preds tracking, DB logging).
            // But direction and conviction now come from the expert panel.
            let tht_pred = tht_journal.predict(&tht_vec);

            // ── Manager: encodes expert SIGNED convictions ──────────────
            // The expert's full opinion: direction + intensity.
            // (bind expert-atom (encode-log |conviction|)) for BUY
            // (bind (permute expert-atom) (encode-log |conviction|)) for SELL
            // The sign makes BUY@0.25 orthogonal to SELL@0.25 in hyperspace.
            // The manager learns which SHAPES of signed opinion precede
            // up-moves vs down-moves. The flip emerges in the discriminant:
            // "when momentum says BUY at high conviction, the price goes DOWN"
            // becomes a geometric property of the Sell prototype.
            // Only include proven experts. Silence, not noise.
            // Unproven experts keep learning on paper but don't pollute
            // the manager's input. The gate opens when the expert's
            // conviction-accuracy curve validates.
            let mut mgr_facts: Vec<Vector> = Vec::new();
            for (ei, ep) in expert_preds.iter().enumerate() {
                if !experts[ei].curve_valid { continue; } // gate closed

                // Fact 1: expert × action × magnitude
                // bind(expert, bind(buy|sell, encode-linear(magnitude, 0.5)))
                // Linear scale 0.5: cosine 0.0 and 0.5 are orthogonal.
                // Expert cosines range 0-0.3; this gives full separation.
                let abs_cos = ep.raw_cos.abs();
                if abs_cos >= min_opinion_magnitude {
                    let magnitude = mgr_scalar.encode(abs_cos, ScalarMode::Linear { scale: 1.0 });
                    let action = if ep.raw_cos >= 0.0 { &buy_atom } else { &sell_atom };
                    let opinion = Primitives::bind(action, &magnitude);
                    mgr_facts.push(Primitives::bind(&expert_atoms[ei], &opinion));
                }

                // Fact 2: reliability — how accurate is this expert?
                // Linear scale 0.3: accuracy excess 0.0-0.15 gets full separation.
                if experts[ei].resolved.len() >= 20 {
                    let acc = experts[ei].resolved.iter()
                        .filter(|(_, c)| *c).count() as f64
                        / experts[ei].resolved.len() as f64;
                    let rel_vec = mgr_scalar.encode((acc - 0.4).max(0.0), ScalarMode::Linear { scale: 1.0 });
                    mgr_facts.push(Primitives::bind(
                        &Primitives::bind(&expert_atoms[ei], &reliability_atom), &rel_vec));
                }

                // Fact 3: tenure — how many resolved predictions?
                // Log scale IS right here: 100 vs 1000 is a meaningful ratio.
                let tenure = experts[ei].resolved.len() as f64;
                if tenure >= 50.0 {
                    let ten_vec = mgr_scalar.encode_log(tenure);
                    mgr_facts.push(Primitives::bind(
                        &Primitives::bind(&expert_atoms[ei], &tenure_atom), &ten_vec));
                }
            }
            // Generalist: gated like every other voice.
            if curve_valid && tht_pred.raw_cos.abs() >= min_opinion_magnitude {
                let gen_magnitude = mgr_scalar.encode(tht_pred.raw_cos.abs(), ScalarMode::Linear { scale: 1.0 });
                let gen_action = if tht_pred.raw_cos >= 0.0 { &buy_atom } else { &sell_atom };
                let gen_opinion = Primitives::bind(gen_action, &gen_magnitude);
                mgr_facts.push(Primitives::bind(&generalist_atom, &gen_opinion));
            }

            // Panel-level facts: emergent properties of the expert collective.
            // These tell the manager about the SHAPE of agreement, not just who said what.
            {
                let proven_preds: Vec<&Prediction> = expert_preds.iter().enumerate()
                    .filter(|(ei, _)| experts[*ei].curve_valid)
                    .map(|(_, ep)| ep)
                    .collect();

                if proven_preds.len() >= 2 {
                    // Agreement: what fraction of proven experts agree on direction?
                    let buys = proven_preds.iter().filter(|p| p.raw_cos > 0.0).count();
                    let total = proven_preds.len();
                    let agreement = (buys.max(total - buys) as f64) / total as f64; // 0.5 = split, 1.0 = unanimous
                    // Agreement: linear scale 1.0 (range 0.5-1.0)
                    mgr_facts.push(Primitives::bind(&agreement_atom,
                        &mgr_scalar.encode(agreement, ScalarMode::Linear { scale: 1.0 })));

                    // Energy: linear scale 0.5 (mean conviction, range 0-0.3)
                    let mean_conv = proven_preds.iter().map(|p| p.conviction).sum::<f64>() / total as f64;
                    mgr_facts.push(Primitives::bind(&panel_energy_atom,
                        &mgr_scalar.encode(mean_conv, ScalarMode::Linear { scale: 1.0 })));

                    // Divergence: linear scale 0.3 (conviction spread, range 0-0.15)
                    let variance = proven_preds.iter()
                        .map(|p| (p.conviction - mean_conv).powi(2))
                        .sum::<f64>() / total as f64;
                    mgr_facts.push(Primitives::bind(&divergence_atom,
                        &mgr_scalar.encode(variance.sqrt(), ScalarMode::Linear { scale: 1.0 })));
                }

                // Context: market state the manager should know about.
                let atr = candles[i].atr_r;
                mgr_facts.push(Primitives::bind(&volatility_atom,
                    &mgr_scalar.encode_log(atr.max(1e-10))));

                // Generalist's discriminant strength: how much signal does the holistic view have?
                mgr_facts.push(Primitives::bind(&disc_strength_atom,
                    &mgr_scalar.encode_log(tht_journal.last_disc_strength.max(1e-10))));

                // Temporal: circular encoding. Hour 23 is near hour 0. Sunday near Monday.
                let hour: f64 = candles[i].ts.get(11..13)
                    .and_then(|s| s.parse().ok()).unwrap_or(12.0);
                let day_of_week: f64 = {
                    let y: i32 = candles[i].ts[..4].parse().unwrap_or(2019);
                    let m: i32 = candles[i].ts[5..7].parse().unwrap_or(1);
                    let d: i32 = candles[i].ts[8..10].parse().unwrap_or(1);
                    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
                    let y2 = if m < 3 { y - 1 } else { y };
                    ((y2 + y2/4 - y2/100 + y2/400 + t[(m-1) as usize] + d) % 7) as f64
                };
                mgr_facts.push(Primitives::bind(&hour_atom,
                    &mgr_scalar.encode(hour, ScalarMode::Circular { period: 24.0 })));
                mgr_facts.push(Primitives::bind(&day_atom,
                    &mgr_scalar.encode(day_of_week, ScalarMode::Circular { period: 7.0 })));

                // Coherence: geometric measure of panel concentration.
                // Compute pairwise cosine between proven expert thought vectors.
                if proven_preds.len() >= 2 {
                    let proven_vecs: Vec<&Vector> = expert_vecs.iter().enumerate()
                        .filter(|(ei, _)| experts[*ei].curve_valid)
                        .map(|(_, v)| v)
                        .collect();
                    let mut pair_sum = 0.0_f64;
                    let mut pair_count = 0usize;
                    for a in 0..proven_vecs.len() {
                        for b in (a+1)..proven_vecs.len() {
                            pair_sum += holon::Similarity::cosine(proven_vecs[a], proven_vecs[b]);
                            pair_count += 1;
                        }
                    }
                    let coherence = if pair_count > 0 { pair_sum / pair_count as f64 } else { 0.0 };
                    // Coherence: linear scale 1.0 (cosine range -1 to 1, abs 0-1)
                    mgr_facts.push(Primitives::bind(&coherence_atom,
                        &mgr_scalar.encode(coherence.abs(), ScalarMode::Linear { scale: 1.0 })));
                }
            }

            // Difference: what changed since last candle?
            // The manager sees motion, not just position.
            let mgr_refs: Vec<&Vector> = mgr_facts.iter().collect();
            let mgr_pred = if mgr_refs.is_empty() {
                Prediction::default()
            } else {
                let mgr_thought = Primitives::bundle(&mgr_refs);

                // Compute delta from previous thought and add it
                let final_thought = if let Some(ref prev) = prev_mgr_thought {
                    let delta = Primitives::difference(prev, &mgr_thought);
                    let delta_bound = Primitives::bind(&mgr_delta_atom, &delta);
                    // Bundle the snapshot thought with the delta thought
                    Primitives::bundle(&[&mgr_thought, &delta_bound])
                } else {
                    mgr_thought.clone()
                };
                prev_mgr_thought = Some(mgr_thought);
                mgr_journal.predict(&final_thought)
            };

            // Panel state for engram (Template 2 — reaction layer)
            let mut panel_state: Vec<f64> = expert_preds.iter()
                .map(|ep| ep.raw_cos).collect();
            panel_state.push(tht_pred.raw_cos); // generalist's voice
            let panel_familiar = if panel_engram.n() >= 10 {
                let residual = panel_engram.residual(&panel_state);
                let threshold = panel_engram.threshold();
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
            conviction_history.push_back(meta_conviction);
            if conviction_history.len() > conviction_window {
                conviction_history.pop_front();
            }
            // Recompute flip threshold every recalib_interval candles, after warmup.
            if conviction_history.len() >= flip_warmup
                && encode_count % args.recalib_interval == 0
            {
                match args.flip_mode.as_str() {
                    "quantile" if args.flip_quantile > 0.0 => {
                        let mut sorted: Vec<f64> = conviction_history.iter().copied().collect();
                        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                        let idx = ((sorted.len() as f64 * args.flip_quantile) as usize)
                            .min(sorted.len() - 1);
                        flip_threshold = sorted[idx];
                    }
                    "auto" if resolved_preds.len() >= flip_warmup * 5 => {
                        // Need 5× warmup (~5000 resolved) for stable exponential fit.
                        // Fit the exponential conviction-accuracy curve:
                        //   accuracy = 0.50 + a × exp(b × conviction)
                        // Then solve for threshold: conv = ln((min_edge - 0.50) / a) / b
                        //
                        // Bin resolved predictions, compute per-bin accuracy,
                        // log-linear regression on bins where accuracy > 0.50.
                        let n_bins = 20usize;
                        let mut sorted: Vec<(f64, bool)> = resolved_preds.iter().copied().collect();
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
                                                flip_threshold = new_thresh;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Fallback: during auto warmup, use quantile if available.
                    "auto" if args.flip_quantile > 0.0
                        && conviction_history.len() >= flip_warmup => {
                        let mut sorted: Vec<f64> = conviction_history.iter().copied().collect();
                        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                        let idx = ((sorted.len() as f64 * args.flip_quantile) as usize)
                            .min(sorted.len() - 1);
                        flip_threshold = sorted[idx];
                    }
                    _ => {}
                }
            }

            // No flip. The enterprise doesn't invert its own decisions.
            // The experts' discriminants learn the full pattern — including reversals.
            // The manager reads their opinions and decides whether to deploy.
            // If reversal behavior emerges, it emerges from the experts' learning.
            let meta_dir = raw_meta_dir;

            // ── Hold mode: swap when signal changes position ─────────
            // BUY signal + currently in USDC = swap USDC→WBTC.
            // SELL signal + currently in WBTC = swap WBTC→USDC.
            // The position persists between signals. WBTC appreciates.
            // Hold mode: only swap when conviction is in the proven band.
            // The band is where the manager has demonstrated >51% accuracy.
            // Outside the band, hold current position. "I don't know" = don't act.
            let in_proven_band = meta_conviction >= mgr_proven_band.0
                && meta_conviction < mgr_proven_band.1;
            if args.asset_mode == "hold" && trader.phase != Phase::Observe
                && mgr_curve_valid && in_proven_band
            {
                let btc_price = candles[i].close;
                let fee_rate = args.swap_fee + args.slippage;
                match (meta_dir, hold_state) {
                    (Some(Outcome::Buy), HoldState::InUsdc) => {
                        // Swap all available USDC → WBTC
                        let usdc_available = treasury.balance("USDC");
                        if usdc_available > 1.0 {
                            let (spent, received) = treasury.swap("USDC", "WBTC", usdc_available, btc_price, fee_rate);
                            hold_state = HoldState::InWbtc;
                            last_swap_candle = i;
                            last_swap_price = btc_price;
                            hold_swaps += 1;
                            run_db.execute(
                                "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,position_usd,swap_fee_pct,exit_reason)
                                 VALUES (?1,?2,?3,'Buy',?4,?5,?6,'Swap')",
                                rusqlite::params![log_step, i as i64, &candles[i].ts, btc_price, spent, fee_rate * 100.0],
                            ).ok();
                        }
                    }
                    (Some(Outcome::Sell), HoldState::InWbtc) => {
                        // Swap all WBTC → USDC
                        let wbtc_available = treasury.balance("WBTC");
                        if wbtc_available > 0.0 {
                            let wbtc_value_usdc = wbtc_available * btc_price;
                            let (spent_wbtc, received_usdc) = treasury.swap("WBTC", "USDC", wbtc_available, 1.0 / btc_price, fee_rate);
                            hold_state = HoldState::InUsdc;
                            let hold_return = (btc_price - last_swap_price) / last_swap_price;
                            let hold_candles = i - last_swap_candle;
                            if hold_return > 0.0 { hold_wins += 1; }
                            hold_swaps += 1;
                            run_db.execute(
                                "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,exit_price,gross_return_pct,net_return_pct,position_usd,swap_fee_pct,horizon_candles,won,exit_reason)
                                 VALUES (?1,?2,?3,'Sell',?4,?5,?6,?7,?8,?9,?10,?11,'Swap')",
                                rusqlite::params![
                                    log_step, i as i64, &candles[i].ts,
                                    last_swap_price, btc_price,
                                    hold_return * 100.0,
                                    (hold_return - 2.0 * fee_rate) * 100.0, // approximate net
                                    wbtc_value_usdc,
                                    fee_rate * 100.0,
                                    hold_candles as i64,
                                    (hold_return > 2.0 * fee_rate) as i32,
                                    ],
                            ).ok();
                        }
                    }
                    _ => {} // signal matches current position — hold
                }
            }

            // Position sizing: Kelly from the curve × drawdown cap.
            // The curve handles selectivity. The drawdown cap handles survival.
            // Nothing else. No graduated gate, no stability gate, no phase gate.
            // Risk branch: compute only at recalib intervals (not every candle).
            // Between recalibs, reuse the last risk_mult.
            if encode_count % args.recalib_interval == 0 || encode_count < 100 {
                let branch_features = trader.risk_branch_wat(&vm, &risk_scalar);
                let mut worst_ratio = 1.0_f64;
                let healthy = trader.is_healthy() && trader.trades_taken >= 20;
                for (bi, branch) in risk_branches.iter_mut().enumerate() {
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
                cached_risk_mult = if risk_branches[0].subspace.n() >= 10 {
                    worst_ratio
                } else { 0.5 };
            }
            let risk_mult = cached_risk_mult;

            // The treasury doesn't move until the trader has proven edge.
            // Two requirements:
            // 1. Past the observe period (enough data to form a discriminant)
            // 2. Curve is valid (the conviction-accuracy relationship exists)
            // Before both are met, predictions are hypothetical — recorded in the
            // ledger but the treasury withholds capital.
            let trader_proven = trader.phase != Phase::Observe && mgr_curve_valid;
            let position_frac = if meta_dir.is_some()
                && trader_proven
                && (flip_threshold <= 0.0 || meta_conviction >= flip_threshold)
            {
                let mt = if args.atr_multiplier > 0.0 {
                    args.atr_multiplier * candles[i].atr_r
                } else { args.move_threshold };

                match args.sizing.as_str() {
                    "kelly" => {
                        // Fast path: evaluate cached curve params. No sorting.
                        let kelly_result = if curve_valid && cached_curve_b > 0.0 {
                            let win_rate = (0.50 + cached_curve_a * (cached_curve_b * meta_conviction).exp()).min(0.95);
                            let edge = 2.0 * win_rate - 1.0;
                            if edge > 0.0 {
                                let half_kelly_risk = edge / 2.0;
                                Some(half_kelly_risk / mt)
                            } else { None }
                        } else { None };
                        match kelly_result {
                            Some(frac) => {
                                let frac = frac.min(1.0);
                                let dd = if trader.peak_equity > 0.0 {
                                    (trader.peak_equity - trader.equity) / trader.peak_equity
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
                        if flip_threshold > 0.0 && meta_conviction < flip_threshold {
                            None
                        } else {
                            trader.position_frac(meta_conviction, args.min_conviction, flip_threshold)
                        }
                    }
                }
            } else { None };

            // Treasury allocation: reserve capital for this position.
            let deployed_usd = if let Some(frac) = position_frac {
                treasury.open_position(treasury.allocatable() * frac)
            } else {
                0.0
            };

            pending.push_back(Pending {
                candle_idx:    i,
                year:          candles[i].year,
                vis_vec,
                tht_vec,
                vis_pred:      vis_pred.clone(),
                tht_pred:      tht_pred.clone(),
                raw_meta_dir:  raw_meta_dir,
                meta_dir,
                was_flipped:   flip_threshold > 0.0 && meta_conviction >= flip_threshold,
                meta_conviction,
                position_frac,
                expert_vecs,
                expert_preds,
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
            vis_journal.decay(adaptive_decay);
            tht_journal.decay(adaptive_decay);
            tht_fast.decay(decay_fast);
            mgr_journal.decay(adaptive_decay);
            for expert in &mut experts {
                expert.journal.decay(args.decay);
            }

            // ── Event-driven learning ─────────────────────────────────────
            // Snapshot recalib counts before scanning so we can detect if
            // any recalibration fired during this candle's learning.
            let vis_recalib_before = vis_journal.recalib_count;
            let tht_recalib_before = tht_journal.recalib_count;

            let current_price = candles[i].close;
            for entry in pending.iter_mut() {
                let entry_price = candles[entry.candle_idx].close;
                let pct         = (current_price - entry_price) / entry_price;
                let abs_pct     = pct.abs();

                if abs_pct > entry.peak_abs_pct { entry.peak_abs_pct = abs_pct; }
                entry.path_candles = i - entry.candle_idx;

                // Track directional excursion relative to predicted direction.
                let directional_pct = match entry.meta_dir {
                    Some(Outcome::Buy)  =>  pct,
                    Some(Outcome::Sell) => -pct,
                    _ => pct.abs(), // no direction → track absolute
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
                // During observe period: legacy exits. "I don't know" = don't act.
                if args.exit_mode == "managed" && entry.exit_reason.is_none()
                    && entry.position_frac.is_some()
                    && trader.phase != Phase::Observe
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
                    let outcome = if pct > thresh       { Some(Outcome::Buy)  }
                                  else if pct < -thresh { Some(Outcome::Sell) }
                                  else                  { None };

                    if let Some(o) = outcome {
                        entry.crossing_candle = Some(i);
                        let sw = signal_weight(abs_pct, &mut move_sum, &mut move_count);
                        vis_journal.observe(&entry.vis_vec, o, sw);
                        tht_journal.observe(&entry.tht_vec, o, sw);
                        tht_fast.observe(&entry.tht_vec, o, sw);
                        // Manager does NOT learn here. Manager learns Win/Lose at trade
                        // resolution, not Buy/Sell at threshold crossing. The manager's
                        // question is "should I deploy?" not "which direction?"
                        // Expert panel: each expert observes, tracks curve, and feeds engrams
                        for (ei, expert_vec) in entry.expert_vecs.iter().enumerate() {
                            experts[ei].journal.observe(expert_vec, o, sw);
                            // Track accuracy since last recalib for engram gating
                            if let Some(pred_dir) = entry.expert_preds[ei].direction {
                                // No flip. Experts learn raw. Their discriminants encode
                                // the full pattern including reversals naturally.
                                experts[ei].recalib_total += 1;
                                if pred_dir == o { experts[ei].recalib_wins += 1; }
                            }
                            // When expert recalibrates: evaluate last period's accuracy.
                            // If good (>55%), snapshot discriminant as a "good state" engram.
                            if experts[ei].journal.recalib_count > experts[ei].last_recalib_count {
                                experts[ei].last_recalib_count = experts[ei].journal.recalib_count;
                                if experts[ei].recalib_total >= 20 {
                                    let acc = experts[ei].recalib_wins as f64
                                        / experts[ei].recalib_total as f64;
                                    if acc > 0.55 {
                                        if let Some(disc) = experts[ei].journal.discriminant() {
                                            let disc_owned = disc.to_vec();
                                            experts[ei].good_state_subspace.update(&disc_owned);
                                        }
                                    }
                                }
                                experts[ei].recalib_wins = 0;
                                experts[ei].recalib_total = 0;
                            }
                            if let Some(pred_dir) = entry.expert_preds[ei].direction {
                                // expert_preds are already flipped at prediction time.
                                // Check directly against outcome.
                                let correct = pred_dir == o;
                                experts[ei].resolved.push_back(
                                    (entry.expert_preds[ei].conviction, correct));
                                if experts[ei].resolved.len() > conviction_window {
                                    experts[ei].resolved.pop_front();
                                }
                                // Update per-expert conviction history + flip threshold
                                experts[ei].conviction_history.push_back(entry.expert_preds[ei].conviction);
                                if experts[ei].conviction_history.len() > 2000 {
                                    experts[ei].conviction_history.pop_front();
                                }
                                if experts[ei].conviction_history.len() >= 200
                                    && experts[ei].resolved.len() % 50 == 0
                                {
                                    let mut sorted: Vec<f64> = experts[ei].conviction_history.iter().copied().collect();
                                    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                                    let idx = ((sorted.len() as f64 * args.flip_quantile) as usize)
                                        .min(sorted.len() - 1);
                                    experts[ei].flip_threshold = sorted[idx];
                                }
                                // Proof gate: does this expert have direction edge?
                                // Check if accuracy at high conviction exceeds 52%.
                                if experts[ei].resolved.len() >= 100 {
                                    let high_conv: Vec<&(f64, bool)> = experts[ei].resolved.iter()
                                        .filter(|(c, _)| *c >= experts[ei].flip_threshold * 0.8)
                                        .collect();
                                    if high_conv.len() >= 20 {
                                        let acc = high_conv.iter().filter(|(_, c)| *c).count() as f64
                                            / high_conv.len() as f64;
                                        experts[ei].curve_valid = acc > 0.52;
                                    }
                                }
                                // Log for post-hoc analysis
                                if args.diagnostics { run_db.execute(
                                    "INSERT INTO expert_log (step,expert,conviction,direction,correct)
                                     VALUES (?1,?2,?3,?4,?5)",
                                    params![
                                        log_step,
                                        experts[ei].name,
                                        entry.expert_preds[ei].conviction,
                                        pred_dir.to_string(),
                                        correct as i32,
                                    ],
                                ).ok(); }
                            }
                        }
                        entry.first_outcome = Some(o);
                        entry.outcome_pct   = pct;
                    }
                }
            }

            // Log any recalibrations that fired during this candle's learning.
            if vis_journal.recalib_count != vis_recalib_before {
                run_db.execute(
                    "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count)
                     VALUES (?1,?2,?3,?4,?5,?6)",
                    params![
                        encode_count as i64, "visual",
                        vis_journal.last_cos_raw, vis_journal.last_disc_strength,
                        vis_journal.buy.count() as i64, vis_journal.sell.count() as i64,
                    ],
                ).ok();
            }
            if tht_journal.recalib_count != tht_recalib_before {
                tht_attention = tht_journal.discriminant().map(|d| d.to_vec());

                // Pre-compute curve params for Kelly — once per recalib, not per trade.
                // Uses the generalist's resolved_preds for the curve fit.
                if let Some((_, a, b)) = kelly_frac(0.15, &resolved_preds, 50,
                    if args.atr_multiplier > 0.0 { args.atr_multiplier * candles[i].atr_r } else { args.move_threshold }) {
                    cached_curve_a = a;
                    cached_curve_b = b;
                    curve_valid = true;
                }
                // Manager's own proof: band-based, not exponential.
                // Find the conviction band where accuracy > 51% with 500+ samples.
                // The sweet spot is at 5-10σ (geometric property of dims).
                // The manager acts only in its proven band.
                if mgr_resolved.len() >= 500 {
                    let sigma = 1.0 / (args.dims as f64).sqrt();
                    // Scan bands: [k*sigma, (k+2)*sigma] for k in 3..20
                    let mut best_acc = 0.5_f64;
                    let mut best_band = (0.0_f64, 0.0_f64);
                    let mut best_n = 0usize;
                    for k in (3..18).step_by(1) {
                        let lo = k as f64 * sigma;
                        let hi = (k + 4) as f64 * sigma; // 4σ wide bands
                        let in_band: Vec<&(f64, bool)> = mgr_resolved.iter()
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
                        mgr_curve_valid = true;
                        mgr_proven_band = best_band;
                    } else {
                        mgr_curve_valid = false;
                        mgr_proven_band = (0.0, 0.0);
                    }
                }

                // Feed panel engram: if recent panel accuracy was good, store current state.
                if panel_recalib_total >= 10 {
                    let acc = panel_recalib_wins as f64 / panel_recalib_total as f64;
                    if acc > 0.55 {
                        panel_engram.update(&panel_state);
                    }
                }
                panel_recalib_wins = 0;
                panel_recalib_total = 0;

                run_db.execute(
                    "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count)
                     VALUES (?1,?2,?3,?4,?5,?6)",
                    params![
                        encode_count as i64, "thought",
                        tht_journal.last_cos_raw, tht_journal.last_disc_strength,
                        tht_journal.buy.count() as i64, tht_journal.sell.count() as i64,
                    ],
                ).ok();

                // Decode thought discriminant against the fact codebook.
                let decoded = tht_journal.decode_discriminant(&codebook_vecs, &codebook_labels);
                for (rank, (label, cos)) in decoded.iter().take(20).enumerate() {
                    run_db.execute(
                        "INSERT INTO disc_decode (step,journal,rank,fact_label,cosine)
                         VALUES (?1,?2,?3,?4,?5)",
                        params![
                            encode_count as i64, "thought",
                            (rank + 1) as i64, label, cos,
                        ],
                    ).ok();
                }

                // Log thought subspace state.
                let eigs = tht_subspace.eigenvalues();
                let top5: Vec<String> = eigs.iter().take(5).map(|e| format!("{:.2}", e)).collect();
                run_db.execute(
                    "INSERT INTO subspace_log (step,residual,threshold,explained,top_eigenvalues)
                     VALUES (?1,?2,?3,?4,?5)",
                    params![
                        encode_count as i64,
                        0.0_f64, // residual — subspace monitoring disabled
                        tht_subspace.threshold(),
                        tht_subspace.explained_ratio(),
                        format!("[{}]", top5.join(",")),
                    ],
                ).ok();
            }

            // ── Resolve entries: managed exit OR horizon expiry ──────────
            // In legacy mode: horizon is the exit.
            // In managed mode: the market is the exit (stop/TP). The horizon
            // only controls learning labels. Trades live until the market
            // closes them. A safety max (10× horizon) prevents unbounded
            // queue growth for trades that drift sideways forever.
            let max_pending_age = if args.exit_mode == "managed" {
                args.horizon * 10 // safety valve — not an exit strategy
            } else {
                args.horizon
            };
            let mut resolved_indices: Vec<usize> = Vec::new();
            for (qi, entry) in pending.iter().enumerate() {
                let age = i - entry.candle_idx;
                let horizon_expired = age >= max_pending_age;
                let managed_exited = entry.exit_reason.is_some();
                // In legacy mode: also expire at normal horizon
                let legacy_expired = args.exit_mode != "managed" && age >= args.horizon;
                if horizon_expired || managed_exited || legacy_expired {
                    resolved_indices.push(qi);
                }
            }
            // Drain in reverse order to preserve indices.
            let mut resolved_entries: Vec<Pending> = Vec::new();
            for &qi in resolved_indices.iter().rev() {
                // VecDeque::remove returns Option, but we just found these indices
                if let Some(entry) = pending.remove(qi) {
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
                let final_out   = entry.first_outcome.unwrap_or(Outcome::Noise);
                let entry_candle = &candles[entry.candle_idx];

                match final_out {
                    Outcome::Noise => noise_count  += 1,
                    _              => labeled_count += 1,
                }

                // Rolling accuracy per journal (non-Noise only).
                if final_out != Outcome::Noise {
                    if let Some(vd) = entry.vis_pred.direction {
                        let ok = vd == final_out;
                        vis_rolling.push_back(ok);
                        if vis_rolling.len() > rolling_cap { vis_rolling.pop_front(); }
                    }
                    if let Some(td) = entry.tht_pred.direction {
                        let ok = td == final_out;
                        tht_rolling.push_back(ok);
                        if tht_rolling.len() > rolling_cap { tht_rolling.pop_front(); }
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
                            let buys = entry.expert_preds.iter()
                                .filter(|ep| ep.direction == Some(Outcome::Buy)).count();
                            let sells = entry.expert_preds.iter()
                                .filter(|ep| ep.direction == Some(Outcome::Sell)).count();
                            if buys > sells { Some(Outcome::Buy) }
                            else if sells > buys { Some(Outcome::Sell) }
                            else { None }
                        };
                        if let Some(majority_dir) = expert_majority {
                            let directional = match majority_dir {
                                Outcome::Buy  =>  entry.outcome_pct,
                                Outcome::Sell => -entry.outcome_pct,
                                _ => 0.0,
                            };
                            // Manager learns raw price direction from intensity patterns.
                            // Not "was the expert majority right?" but "did the price go up or down?"
                            // The manager maps intensity patterns → direction.
                            // Both sides are learned: the same intensity pattern that preceded UP
                            // teaches the Buy accumulator; the same pattern that preceded DOWN
                            // teaches the Sell accumulator. The discriminant separates.
                            let price_change = (current_price - candles[entry.candle_idx].close)
                                / candles[entry.candle_idx].close;
                            let mgr_label = if price_change > 0.0 { Outcome::Buy } else { Outcome::Sell };

                            // Signed conviction, gated — same encoding as prediction time.
                            // Only proven experts included. Silence, not noise.
                            let mut mgr_res_facts: Vec<Vector> = entry.expert_preds.iter().enumerate()
                                .filter_map(|(ei, ep)| {
                                    if !experts[ei].curve_valid { return None; }
                                    let intensity = mgr_scalar.encode(ep.raw_cos.abs().max(1e-10), ScalarMode::Linear { scale: 1.0 });
                                    let action = if ep.raw_cos >= 0.0 { &buy_atom } else { &sell_atom };
                                    let opinion = Primitives::bind(action, &intensity);
                                    Some(Primitives::bind(&expert_atoms[ei], &opinion))
                                }).collect();
                            // Generalist gated same as experts
                            if curve_valid {
                                let gen_intensity = mgr_scalar.encode(entry.tht_pred.raw_cos.abs().max(1e-10), ScalarMode::Linear { scale: 1.0 });
                                let gen_action = if entry.tht_pred.raw_cos >= 0.0 { &buy_atom } else { &sell_atom };
                                let gen_opinion = Primitives::bind(gen_action, &gen_intensity);
                                mgr_res_facts.push(Primitives::bind(&generalist_atom, &gen_opinion));
                            }
                            let mrefs: Vec<&Vector> = mgr_res_facts.iter().collect();
                            if !mrefs.is_empty() { // at least one proven expert
                                let mgr_vec = Primitives::bundle(&mrefs);
                                mgr_journal.observe(&mgr_vec, mgr_label, 1.0);
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
                            mgr_resolved.push_back((entry.meta_conviction, mgr_correct));
                            if mgr_resolved.len() > 5000 { mgr_resolved.pop_front(); }
                            resolved_preds.push_back((entry.meta_conviction, mgr_correct));
                            if resolved_preds.len() > conviction_window {
                                resolved_preds.pop_front();
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

                    let trade_pct = if args.exit_mode == "managed" {
                        entry.exit_pct
                    } else {
                        entry.outcome_pct
                    };
                    let has_resolution = if args.exit_mode == "managed" {
                        true
                    } else {
                        final_out != Outcome::Noise
                    };

                    if has_resolution {
                        // ── Accounting: compute P&L (real or hypothetical) ────
                        let gross_ret = match dir {
                            Outcome::Buy  =>  trade_pct,
                            Outcome::Sell => -trade_pct,
                            Outcome::Noise => 0.0,
                        };
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
                            else { trader.equity * frac }
                        } else { 0.0 };
                        let trade_pnl = pos_usd * net_ret;

                        // ── Manager learns Win/Lose at resolution ─────────
                        // The manager's question: "was this configuration profitable?"
                        // Win = net_ret > 0 (after costs). Lose = net_ret <= 0.
                        // The manager learns from ALL predictions — paper and live.
                        // The reversal pattern emerges: "experts confident + wrong direction
                        // = Lose" → manager learns to withhold when it sees that config.
                        {
                            let mgr_label = if net_ret > 0.0 { Outcome::Buy } else { Outcome::Sell };
                            // Buy = Win, Sell = Lose in the manager's space.
                            // Signed conviction — same encoding as prediction time.
                            let mut mgr_res_facts: Vec<Vector> = entry.expert_preds.iter().enumerate()
                                .map(|(ei, ep)| {
                                    let intensity = mgr_scalar.encode(ep.raw_cos.abs().max(1e-10), ScalarMode::Linear { scale: 1.0 });
                                    let action = if ep.raw_cos >= 0.0 { &buy_atom } else { &sell_atom };
                                    let opinion = Primitives::bind(action, &intensity);
                                    Primitives::bind(&expert_atoms[ei], &opinion)
                                }).collect();
                            // Generalist
                            {
                                let gen_intensity = mgr_scalar.encode(entry.tht_pred.raw_cos.abs().max(1e-10), ScalarMode::Linear { scale: 1.0 });
                                let gen_action = if entry.tht_pred.raw_cos >= 0.0 { &buy_atom } else { &sell_atom };
                                let gen_opinion = Primitives::bind(gen_action, &gen_intensity);
                                mgr_res_facts.push(Primitives::bind(&generalist_atom, &gen_opinion));
                            }
                            let mrefs: Vec<&Vector> = mgr_res_facts.iter().collect();
                            let mgr_vec = Primitives::bundle(&mrefs);
                            mgr_journal.observe(&mgr_vec, mgr_label, 1.0);
                        }

                        // ── Treasury: only moves money for live trades ───────
                        if is_live {
                            let trade_fees = pos_usd * (args.swap_fee * 2.0);
                            let trade_slip = pos_usd * (args.slippage * 2.0);
                            trader.record_trade(trade_pct, frac, dir, entry.year,
                                                args.swap_fee, args.slippage);
                            treasury.close_position(entry.deployed_usd,
                                pos_usd * gross_ret, trade_fees, trade_slip);
                        }

                        // ── Ledger: ALWAYS records. Paper trail for all. ─────
                        let exit_candle = entry.crossing_candle;
                        let exit_ts = exit_candle.map(|ci| candles[ci].ts.clone());
                        let exit_price = exit_candle.map(|ci| candles[ci].close)
                            .unwrap_or(candles[i].close);
                        let crossing_elapsed = entry.crossing_candle
                            .map(|ci| (ci - entry.candle_idx) as i64);
                        run_db.execute(
                            "INSERT INTO trade_ledger
                             (step,candle_idx,timestamp,exit_candle_idx,exit_timestamp,
                              direction,conviction,was_flipped,
                              entry_price,exit_price,position_frac,position_usd,
                              gross_return_pct,swap_fee_pct,slippage_pct,net_return_pct,
                              pnl_usd,equity_after,
                              max_favorable_pct,max_adverse_pct,
                              crossing_candles,horizon_candles,outcome,won,exit_reason)
                             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)",
                            params![
                                log_step, entry.candle_idx as i64, &entry_candle.ts,
                                exit_candle.map(|ci| ci as i64), exit_ts,
                                dir.to_string(), entry.meta_conviction,
                                entry.was_flipped as i32,
                                entry.entry_price, exit_price,
                                frac, pos_usd,
                                gross_ret * 100.0,
                                entry_cost_frac * 100.0,
                                exit_cost_frac * 100.0,
                                net_ret * 100.0, trade_pnl, trader.equity,
                                entry.max_favorable * 100.0, entry.max_adverse * 100.0,
                                crossing_elapsed, entry.path_candles as i64,
                                final_out.to_string(), (net_ret > 0.0) as i32,
                                match entry.exit_reason {
                                    Some(ExitReason::ThresholdCrossing) => "ThresholdCrossing",
                                    Some(ExitReason::TrailingStop) => "TrailingStop",
                                    Some(ExitReason::TakeProfit) => "TakeProfit",
                                    Some(ExitReason::HorizonExpiry) => "HorizonExpiry",
                                    None => "HorizonExpiry",
                                },
                            ],
                        ).ok();

                        // Feed ledger history for analysis.
                        exit_mfe_history.push_back(entry.max_favorable);
                        if exit_mfe_history.len() > exit_history_cap {
                            exit_mfe_history.pop_front();
                        }
                        exit_mae_history.push_back(entry.max_adverse.abs());
                        if exit_mae_history.len() > exit_history_cap {
                            exit_mae_history.pop_front();
                        }

                        // Panel tracking (all predictions, not just live)
                        panel_recalib_total += 1;
                        if dir == final_out { panel_recalib_wins += 1; }

                        // Manager profitability tracking: Win/Lose, not direction.
                        if entry.raw_meta_dir.is_some() {
                            let profitable = net_ret > 0.0;
                            resolved_preds.push_back((entry.meta_conviction, profitable));
                            // Don't double-push to mgr_resolved — it's already
                            // populated from the hypothetical block with direction accuracy.
                            if mgr_resolved.len() > 5000 { mgr_resolved.pop_front(); }
                            if resolved_preds.len() > conviction_window {
                                resolved_preds.pop_front();
                            }
                        }

                        // ── Risk/diagnostics: only for live trades ───────────
                        if is_live {
                                let dd = if trader.peak_equity > 0.0 {
                                    (trader.peak_equity - trader.equity) / trader.peak_equity * 100.0
                                } else { 0.0 };
                                let (streak_len, streak_dir) = {
                                    let mut len = 0i32;
                                    if let Some(&last) = trader.rolling.back() {
                                        for &o in trader.rolling.iter().rev() {
                                            if o == last { len += 1; } else { break; }
                                        }
                                    }
                                    let dir = if trader.rolling.back() == Some(&true) { "winning" } else { "losing" };
                                    (len, dir)
                                };
                                let recent_acc = if trader.rolling.len() >= 5 {
                                    trader.rolling.iter().filter(|&&x| x).count() as f64
                                        / trader.rolling.len() as f64
                                } else { 0.5 };
                                let eq_pct = (trader.equity - trader.initial_equity) / trader.initial_equity * 100.0;
                                let won = (dir == final_out) as i32;
                                if args.diagnostics { run_db.execute(
                                    "INSERT INTO risk_log (step,drawdown_pct,streak_len,streak_dir,recent_acc,equity_pct,won)
                                     VALUES (?1,?2,?3,?4,?5,?6,?7)",
                                    params![log_step, dd, streak_len, streak_dir, recent_acc, eq_pct, won],
                                ).ok(); }
                            // Track flip-zone trade outcomes.
                            if entry.was_flipped {
                                window_total += 1;
                                if dir == final_out { window_wins += 1; }

                                // Adaptive decay state machine.
                                let won = dir == final_out;
                                flip_zone_wins.push_back(won);
                                if flip_zone_wins.len() > flip_zone_rolling_cap {
                                    flip_zone_wins.pop_front();
                                }
                                if flip_zone_wins.len() >= 30 {
                                    let wr = flip_zone_wins.iter().filter(|&&w| w).count() as f64
                                           / flip_zone_wins.len() as f64;
                                    if !in_adaptation && wr < 0.50 {
                                        in_adaptation = true;
                                        adaptive_decay = decay_adapting;
                                    } else if in_adaptation && wr > 0.55 {
                                        in_adaptation = false;
                                        adaptive_decay = decay_stable;
                                    }
                                }
                            }
                            // Log which facts were present for this trade.
                            for label in &entry.fact_labels {
                                if args.diagnostics { run_db.execute(
                                    "INSERT INTO trade_facts (step, fact_label) VALUES (?1, ?2)",
                                    params![log_step, label],
                                ).ok(); }
                            }
                            // Store visual + thought vectors for engram analysis.
                            if entry.was_flipped {
                                let won = (dir == final_out) as i32;
                                let vis_bytes: Vec<u8> = entry.vis_vec.data().iter()
                                    .map(|&v| v as u8).collect();
                                let tht_bytes: Vec<u8> = entry.tht_vec.data().iter()
                                    .map(|&v| v as u8).collect();
                                if args.diagnostics { run_db.execute(
                                    "INSERT INTO trade_vectors (step, won, vis_data, tht_data)
                                     VALUES (?1, ?2, ?3, ?4)",
                                    params![
                                        log_step, won,
                                        vis_bytes,
                                        tht_bytes,
                                    ],
                                ).ok(); }
                            }
                        } // is_live
                    } // has_resolution
                } // if let Some(dir)

                // Log to DB.
                let agree = match (entry.vis_pred.direction, entry.tht_pred.direction) {
                    (Some(v), Some(t)) => Some((v == t) as i32),
                    _ => None,
                };
                run_db.execute(
                    "INSERT INTO candle_log
                     (step,candle_idx,timestamp,
                      vis_cos,vis_conviction,vis_pred,
                      tht_cos,tht_conviction,tht_pred,
                      agree,meta_pred,meta_conviction,
                      actual,traded,position_frac,equity,outcome_pct)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
                    params![
                        log_step, entry.candle_idx as i64, &entry_candle.ts,
                        entry.vis_pred.raw_cos, entry.vis_pred.conviction,
                        entry.vis_pred.direction.map(|d| d.to_string()),
                        entry.tht_pred.raw_cos, entry.tht_pred.conviction,
                        entry.tht_pred.direction.map(|d| d.to_string()),
                        agree,
                        entry.meta_dir.map(|d| d.to_string()),
                        entry.meta_conviction,
                        final_out.to_string(),
                        entry.position_frac.is_some() as i32,
                        entry.position_frac,
                        trader.equity,
                        entry.outcome_pct,
                    ],
                ).ok();
                log_step   += 1;
                db_batch   += 1;
                if db_batch >= 5_000 {
                    run_db.execute_batch("COMMIT; BEGIN").ok();
                    db_batch = 0;
                }

                trader.tick_observe();
            }

            // ── Progress line ─────────────────────────────────────────────
            if encode_count % progress_every == 0 {
                let elapsed = t_start.elapsed().as_secs_f64();
                let rate    = encode_count as f64 / elapsed;
                let eta     = (loop_count - encode_count) as f64 / rate;
                let vis_acc = if vis_rolling.is_empty() { 0.0 }
                    else { vis_rolling.iter().filter(|&&x| x).count() as f64 / vis_rolling.len() as f64 * 100.0 };
                let tht_acc = if tht_rolling.is_empty() { 0.0 }
                    else { tht_rolling.iter().filter(|&&x| x).count() as f64 / tht_rolling.len() as f64 * 100.0 };
                let ret = (trader.equity - trader.initial_equity) / trader.initial_equity * 100.0;
                let bnh = (candles[i].close - bnh_entry) / bnh_entry * 100.0;
                let exit_info = if args.exit_mode == "managed" {
                    let atr_now = candles[i].atr_r;
                    format!(" | ATR={:.2}% sl={:.2}% tp={:.2}% tr={:.2}% open={}",
                        atr_now * 100.0,
                        k_stop * atr_now * 100.0,
                        k_tp * atr_now * 100.0,
                        k_trail * atr_now * 100.0,
                        treasury.n_open)
                } else { String::new() };
                let desk_info = if desks.len() > 1 {
                    let di: Vec<String> = desks.iter().map(|d| {
                        format!("{}={:.1}%", d.config.name, d.rolling_accuracy(200) * 100.0)
                    }).collect();
                    format!(" | {}", di.join(" "))
                } else { String::new() };
                eprintln!(
                    "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | vis={:.1}% tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) vs B&H {:+.1}% | flip@{:.3} {}{}{}",
                    encode_count, loop_count, rate, eta,
                    &candles[i].ts[..10],
                    trader.phase,
                    vis_acc, tht_acc,
                    trader.trades_taken, trader.win_rate(),
                    trader.equity, ret, bnh,
                    flip_threshold,
                    if !curve_stable { "CALIBRATING" }
                    else if panel_familiar { "ENGRAM" }
                    else if in_adaptation { "ADAPT" }
                    else { "STABLE" },
                    exit_info,
                    desk_info,
                );
                if args.asset_mode == "hold" {
                    let mut prices = HashMap::new();
                    prices.insert("USDC".to_string(), 1.0);
                    prices.insert("WBTC".to_string(), candles[i].close);
                    let tv = treasury.total_value(&prices);
                    let tv_ret = (tv - args.initial_equity) / args.initial_equity * 100.0;
                    let state = if hold_state == HoldState::InWbtc { "WBTC" } else { "USDC" };
                    let mut proven: Vec<&str> = experts.iter()
                        .filter(|e| e.curve_valid).map(|e| e.name).collect();
                    if curve_valid { proven.push("generalist"); }
                    let proven_str = if proven.is_empty() { "none".to_string() }
                        else { proven.join(",") };
                    let band_str = if mgr_curve_valid {
                        format!(" band=[{:.3},{:.3}]", mgr_proven_band.0, mgr_proven_band.1)
                    } else { " band=none".to_string() };
                    eprintln!("    treasury: ${:.0} ({:+.1}%) in {} | swaps={} wins={} | proven=[{}]{}",
                        tv, tv_ret, state, hold_swaps, hold_wins, proven_str, band_str);
                }
            }
        }

        cursor = batch_end;
    }

    // ─ Drain remaining pending entries (log, no further learning) ────────────
    while let Some(entry) = pending.pop_front() {
        let final_out    = entry.first_outcome.unwrap_or(Outcome::Noise);
        let entry_candle = &candles[entry.candle_idx];
        match final_out { Outcome::Noise => noise_count += 1, _ => labeled_count += 1 }

        let agree = match (entry.vis_pred.direction, entry.tht_pred.direction) {
            (Some(v), Some(t)) => Some((v == t) as i32),
            _ => None,
        };
        run_db.execute(
            "INSERT INTO candle_log
             (step,candle_idx,timestamp,
              vis_cos,vis_conviction,vis_pred,
              tht_cos,tht_conviction,tht_pred,
              agree,meta_pred,meta_conviction,
              actual,traded,position_frac,equity,outcome_pct)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
            params![
                log_step, entry.candle_idx as i64, &entry_candle.ts,
                entry.vis_pred.raw_cos, entry.vis_pred.conviction,
                entry.vis_pred.direction.map(|d| d.to_string()),
                entry.tht_pred.raw_cos, entry.tht_pred.conviction,
                entry.tht_pred.direction.map(|d| d.to_string()),
                agree,
                entry.meta_dir.map(|d| d.to_string()),
                entry.meta_conviction,
                final_out.to_string(),
                entry.position_frac.is_some() as i32,
                entry.position_frac,
                trader.equity,
                entry.outcome_pct,
            ],
        ).ok();
        log_step += 1;
    }

    run_db.execute_batch("COMMIT").ok();

    // ─ Final summary ─────────────────────────────────────────────────────────
    let total_time = t_start.elapsed().as_secs_f64();
    let ret        = (trader.equity - trader.initial_equity) / trader.initial_equity * 100.0;
    let bnh_final  = (candles[end_idx - 1].close - bnh_entry) / bnh_entry * 100.0;

    eprintln!("\n═══════════════════════════════════════════════════════════");
    eprintln!("  trader3 complete — {} candles in {:.1}s ({:.0}/s)",
        encode_count, total_time, encode_count as f64 / total_time);
    eprintln!("  Orchestration: {}", args.orchestration);
    if args.swap_fee > 0.0 || args.slippage > 0.0 {
        let rt = 2.0 * (args.swap_fee + args.slippage) * 100.0;
        eprintln!("  Venue costs: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip",
            args.swap_fee * 10000.0, args.slippage * 10000.0, rt);
    }
    if args.exit_mode == "managed" {
        eprintln!("  Exit mode: managed (ATR-scaled per trade). K_stop={} K_trail={} K_tp={}",
            k_stop, k_trail, k_tp);
        eprintln!("  Ledger: {} trades observed (MFE/MAE tracked)", exit_mfe_history.len());
    }
    eprintln!("  Labeled: {}  Noise: {} ({:.1}% noise rate)",
        labeled_count, noise_count,
        noise_count as f64 / (labeled_count + noise_count).max(1) as f64 * 100.0);
    eprintln!();
    eprintln!("  Equity: ${:.2} ({:+.2}%) | B&H: {:+.2}%",
        trader.equity, ret, bnh_final);
    eprintln!("  Trades taken: {}  Won: {}  Win rate: {:.1}%  Skipped: {}",
        trader.trades_taken, trader.trades_won, trader.win_rate(), trader.trades_skipped);
    eprintln!("  Treasury: ${:.2} available  ${:.2} deployed  {:.1}% utilization  fees=${:.2}  slip=${:.2}",
        treasury.balance("USDC"), treasury.deployed("USDC"),
        treasury.utilization() * 100.0,
        treasury.total_fees_paid, treasury.total_slippage);
    eprintln!();
    eprintln!("  Visual journal  — buy_obs={} sell_obs={} cos_raw={:.4} disc_strength={:.4} recalibs={}",
        vis_journal.buy.count(), vis_journal.sell.count(),
        vis_journal.last_cos_raw, vis_journal.last_disc_strength, vis_journal.recalib_count);
    eprintln!("  Thought journal — buy_obs={} sell_obs={} cos_raw={:.4} disc_strength={:.4} recalibs={}",
        tht_journal.buy.count(), tht_journal.sell.count(),
        tht_journal.last_cos_raw, tht_journal.last_disc_strength, tht_journal.recalib_count);
    eprintln!();

    let vis_acc = if vis_rolling.is_empty() { 0.0 }
        else { vis_rolling.iter().filter(|&&x| x).count() as f64 / vis_rolling.len() as f64 * 100.0 };
    let tht_acc = if tht_rolling.is_empty() { 0.0 }
        else { tht_rolling.iter().filter(|&&x| x).count() as f64 / tht_rolling.len() as f64 * 100.0 };
    eprintln!("  Rolling accuracy (last {}): visual={:.1}% thought={:.1}%",
        rolling_cap, vis_acc, tht_acc);
    eprintln!();

    // Expert panel summary.
    if !experts.is_empty() {
        eprintln!("  Expert panel:");
        for expert in &experts {
            eprintln!("    {}: recalibs={} disc_str={:.4} buy={} sell={}",
                expert.name,
                expert.journal.recalib_count,
                expert.journal.last_disc_strength,
                expert.journal.buy.count(),
                expert.journal.sell.count());
        }
        eprintln!();
    }

    // Desk summary.
    if desks.len() > 1 {
        eprintln!("  Desks:");
        for desk in &desks {
            let acc = desk.rolling_accuracy(500) * 100.0;
            let resolved = desk.resolved_preds.len();
            eprintln!("    {}: acc={:.1}% resolved={} labeled={} noise={} recalibs={}",
                desk.config.name, acc, resolved, desk.labeled_count, desk.noise_count,
                desk.generalist.recalib_count);
        }
        eprintln!();
    }

    // By-year breakdown.
    let mut years: Vec<i32> = trader.by_year.keys().copied().collect();
    years.sort();
    if !years.is_empty() {
        eprintln!("  By year:");
        for y in years {
            let ys = &trader.by_year[&y];
            let wr = if ys.trades > 0 { ys.wins as f64 / ys.trades as f64 * 100.0 } else { 0.0 };
            eprintln!("    {}: {} trades  {:.1}% win  {:+.2}$ P&L", y, ys.trades, wr, ys.pnl);
        }
        eprintln!();
    }

    eprintln!("  Run DB: {} ({} rows)", run_db_path, log_step);
    eprintln!("═══════════════════════════════════════════════════════════");
}
