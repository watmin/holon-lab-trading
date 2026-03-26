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
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use rusqlite::{Connection, params};
use holon::{VectorManager, Vector};

use btc_walk::db::load_candles;
use btc_walk::journal::{Journal, Outcome, Prediction};
use btc_walk::thought::{ThoughtEncoder, ThoughtVocab, IndicatorStreams};
use btc_walk::viewport::{
    render_viewport, build_viewport, build_null_template,
    raster_encode, raster_encode_cached, VisualCache,
};

// ─── Constants ───────────────────────────────────────────────────────────────

const BATCH_SIZE: usize = 256;
const THREADS: usize = 8;

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

    /// Minimum cumulative win rate (from the top) to keep expanding the flip zone.
    /// Only used when flip_mode = "auto". 0.52 = need at least 52% accuracy.
    #[arg(long, default_value_t = 0.52)]
    min_edge: f64,

    /// "legacy" = phase-based with 5% cap. "kelly" = half-Kelly from calibration curve.
    #[arg(long, default_value = "legacy")]
    sizing: String,

    /// visual-only | thought-only | agree-only | meta-boost | weighted | thought-led | thought-contrarian
    #[arg(long, default_value = "meta-boost")]
    orchestration: String,

    /// Output SQLite database for this run. Auto-generated if omitted.
    #[arg(long)]
    run_db: Option<PathBuf>,
}

// ─── Trader (phase + equity) ─────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum Phase { Observe, Tentative, Confident }

impl fmt::Display for Phase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Phase::Observe   => write!(f, "OBSERVE"),
            Phase::Tentative => write!(f, "TENTATIVE"),
            Phase::Confident => write!(f, "CONFIDENT"),
        }
    }
}

struct Trader {
    equity:          f64,
    initial_equity:  f64,
    phase:           Phase,
    observe_left:    usize,
    trades_taken:    usize,
    trades_won:      usize,
    trades_skipped:  usize,
    rolling:         VecDeque<bool>,   // recent trade outcomes
    rolling_cap:     usize,
    by_year:         HashMap<i32, YearStats>,
}

#[derive(Default)]
struct YearStats { trades: usize, wins: usize, pnl: f64 }

impl Trader {
    fn new(initial_equity: f64, observe_period: usize) -> Self {
        Self {
            equity: initial_equity,
            initial_equity,
            phase: Phase::Observe,
            observe_left: observe_period,
            trades_taken: 0,
            trades_won: 0,
            trades_skipped: 0,
            rolling: VecDeque::new(),
            rolling_cap: 500,
            by_year: HashMap::new(),
        }
    }

    fn rolling_acc(&self) -> f64 {
        if self.rolling.is_empty() { return 0.5; }
        self.rolling.iter().filter(|&&x| x).count() as f64 / self.rolling.len() as f64
    }

    fn win_rate(&self) -> f64 {
        if self.trades_taken == 0 { return 0.0; }
        self.trades_won as f64 / self.trades_taken as f64 * 100.0
    }

    /// Return a position fraction if conditions allow a trade.
    ///
    /// `flip_threshold`: the dynamic conviction quantile threshold. When
    /// `conviction >= flip_threshold` the prediction has been flipped (reversal
    /// signal) and we scale the position proportionally — higher conviction means
    /// a stronger reversal, so we bet more. Below the threshold, use base sizing.
    fn position_frac(&self, conviction: f64, min_conviction: f64, flip_threshold: f64) -> Option<f64> {
        if self.phase == Phase::Observe  { return None; }
        if conviction < min_conviction   { return None; }
        let base = match self.phase {
            Phase::Tentative => 0.005,
            Phase::Confident => {
                let conf = (self.rolling_acc() - 0.5).max(0.0);
                if conf < 0.05      { 0.005 }
                else if conf < 0.10 { 0.01  }
                else                { (conf * 0.10).min(0.02) }
            }
            Phase::Observe => return None,
        };
        // Only trade in the flip zone — below the threshold there is no reliable
        // signal (near-random accuracy). Once the threshold is established, skip
        // low-conviction candles entirely rather than bleeding on noise.
        if flip_threshold > 0.0 && conviction < flip_threshold {
            return None;
        }
        // Scale position by how far conviction exceeds the threshold.
        // conviction / flip_threshold = 1.0 at boundary, grows above.
        // Cap at 0.05 (5%) to bound risk.
        let frac = if flip_threshold > 0.0 {
            (base * (conviction / flip_threshold)).min(0.05)
        } else {
            base
        };
        Some(frac)
    }

    /// `outcome_pct`: signed price return from entry to first threshold crossing
    ///   (positive = price went up, negative = price went down).
    /// `direction`: the prediction we made (Buy or Sell).
    ///
    /// Long (Buy): profit when price goes up (outcome_pct > 0).
    /// Short (Sell): profit when price goes down (outcome_pct < 0), i.e. -outcome_pct > 0.
    fn record_trade(&mut self, outcome_pct: f64, frac: f64, direction: Outcome, year: i32) {
        let directional_return = match direction {
            Outcome::Buy   =>  outcome_pct,
            Outcome::Sell  => -outcome_pct,
            Outcome::Noise => return,
        };
        let pnl = self.equity * frac * directional_return;
        let won = directional_return > 0.0;
        self.equity += pnl;
        self.trades_taken += 1;
        if won { self.trades_won += 1; }
        self.rolling.push_back(won);
        if self.rolling.len() > self.rolling_cap { self.rolling.pop_front(); }
        let ys = self.by_year.entry(year).or_default();
        ys.trades += 1;
        if won { ys.wins += 1; }
        ys.pnl += pnl;
        self.check_phase();
    }

    fn tick_observe(&mut self) {
        if self.phase == Phase::Observe && self.observe_left > 0 {
            self.observe_left -= 1;
            if self.observe_left == 0 { self.phase = Phase::Tentative; }
        }
    }

    fn check_phase(&mut self) {
        let n = self.rolling.len();
        let acc = self.rolling_acc();
        match self.phase {
            Phase::Tentative => { if n >= 500 && acc > 0.52 { self.phase = Phase::Confident; } }
            Phase::Confident => { if n >= 200 && acc < 0.50 { self.phase = Phase::Tentative; } }
            Phase::Observe   => {}
        }
    }
}

/// Half-Kelly position sizing from the empirical calibration curve.
/// Estimates win rate at the given conviction by looking at all resolved
/// predictions with conviction >= this level, then sizes by half-Kelly.
/// Returns None if insufficient data or no edge.
fn kelly_frac(conviction: f64, resolved: &VecDeque<(f64, bool)>, min_sample: usize) -> Option<f64> {
    if resolved.len() < min_sample { return None; }
    let mut wins = 0u32;
    let mut total = 0u32;
    for &(conv, correct) in resolved.iter() {
        if conv >= conviction {
            total += 1;
            if correct { wins += 1; }
        }
    }
    if total < min_sample as u32 { return None; }
    let win_rate = wins as f64 / total as f64;
    let kelly = 2.0 * win_rate - 1.0; // even-money Kelly
    if kelly <= 0.0 { return None; }
    Some((kelly / 2.0).min(0.15)) // half-Kelly, cap at 15%
}

// ─── Pending entry ───────────────────────────────────────────────────────────

struct Pending {
    candle_idx:    usize,
    year:          i32,
    vis_vec:       Vector,
    tht_vec:       Vector,
    vis_pred:      Prediction,
    tht_pred:      Prediction,
    raw_meta_dir:  Option<Outcome>,  // un-flipped direction (for auto calibration)
    meta_dir:      Option<Outcome>,
    was_flipped:   bool,             // true if flip was active when this entry was created
    meta_conviction: f64,
    position_frac: Option<f64>,
    first_outcome: Option<Outcome>, // set on first threshold crossing; drives learning
    outcome_pct:   f64,             // price change at first crossing (for DB)
    peak_abs_pct:  f64,             // max |price change| seen while pending (for P&L)
}

// ─── Orchestration ───────────────────────────────────────────────────────────

fn orchestrate(
    mode: &str,
    vis: &Prediction,
    tht: &Prediction,
    vis_roll_acc: f64,
    tht_roll_acc: f64,
) -> (Option<Outcome>, f64) {
    let vd = vis.direction;
    let td = tht.direction;

    match mode {
        "visual-only"  => (vd, vis.conviction),
        "thought-only" => (td, tht.conviction),

        "agree-only" => match (vd, td) {
            (Some(v), Some(t)) if v == t =>
                (Some(v), (vis.conviction + tht.conviction) / 2.0),
            _ => (None, 0.0),
        },

        "meta-boost" => match (vd, td) {
            (Some(v), Some(t)) => {
                if v == t {
                    // Both agree — average conviction with a small boost.
                    (Some(v), (vis.conviction + tht.conviction) / 2.0 * 1.1)
                } else {
                    // Disagree — go with higher conviction at half strength.
                    if vis.conviction >= tht.conviction {
                        (Some(v), vis.conviction * 0.5)
                    } else {
                        (Some(t), tht.conviction * 0.5)
                    }
                }
            }
            (Some(v), None) => (Some(v), vis.conviction * 0.8),
            (None, Some(t)) => (Some(t), tht.conviction * 0.8),
            (None, None)    => (None, 0.0),
        },

        "weighted" => {
            // Weight each journal by how much better than chance it has been recently.
            let vw = (vis_roll_acc - 0.5).max(0.01);
            let tw = (tht_roll_acc - 0.5).max(0.01);
            let total = vw + tw;
            match (vd, td) {
                (Some(v), Some(t)) => {
                    if v == t {
                        (Some(v), vis.conviction * vw / total + tht.conviction * tw / total)
                    } else if vis.conviction * vw >= tht.conviction * tw {
                        (Some(v), vis.conviction * vw / total)
                    } else {
                        (Some(t), tht.conviction * tw / total)
                    }
                }
                (Some(v), None) => (Some(v), vis.conviction * 0.8),
                (None, Some(t)) => (Some(t), tht.conviction * 0.8),
                (None, None)    => (None, 0.0),
            }
        }

        // Thought sets direction and conviction (preserving its high flip threshold).
        // Visual acts as a binary veto: if visual has a direction and disagrees, skip.
        "thought-led" => match td {
            None => (None, 0.0),
            Some(t) => match vd {
                Some(v) if v != t => (None, 0.0), // visual veto
                _ => (Some(t), tht.conviction),
            },
        },

        // Thought direction, conviction amplified by visual conviction magnitude.
        // Visual strength confirms trend clarity regardless of direction.
        "thought-visual-amp" => match td {
            None => (None, 0.0),
            Some(t) => (Some(t), tht.conviction * (1.0 + vis.conviction)),
        },

        // Thought's flip zone, but ONLY when visual explicitly disagrees.
        // Visual disagreement = visual sees a strong trend; thought sees exhaustion.
        // Empirically: vis-disagree trades win 54.1% vs 52.7% when visual agrees.
        "thought-contrarian" => match (td, vd) {
            (Some(t), Some(v)) if v != t => (Some(t), tht.conviction),
            _ => (None, 0.0),
        },

        other => panic!("unknown orchestration mode: {}", other),
    }
}

// ─── Signal weight ───────────────────────────────────────────────────────────

/// Scale an observation by how large the triggering move was vs the running average.
/// Bigger moves teach more strongly than typical moves.
fn signal_weight(abs_pct: f64, move_sum: &mut f64, move_count: &mut usize) -> f64 {
    *move_sum += abs_pct;
    *move_count += 1;
    abs_pct / (*move_sum / *move_count as f64)
}

// ─── DB setup ────────────────────────────────────────────────────────────────

fn init_run_db(path: &str) -> Connection {
    let db = Connection::open(path).expect("failed to open run DB");
    db.execute_batch("
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;

        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        );

        -- One row per expired pending entry.
        CREATE TABLE IF NOT EXISTS candle_log (
            step             INTEGER PRIMARY KEY,
            candle_idx       INTEGER,
            timestamp        TEXT,
            -- visual journal
            vis_cos          REAL,    -- signed cosine vs discriminant (+buy, -sell)
            vis_conviction   REAL,    -- |vis_cos|
            vis_pred         TEXT,    -- 'Buy' | 'Sell' | NULL
            -- thought journal
            tht_cos          REAL,
            tht_conviction   REAL,
            tht_pred         TEXT,
            -- agreement (NULL if either journal had no prediction yet)
            agree            INTEGER,
            -- orchestration output
            meta_pred        TEXT,
            meta_conviction  REAL,
            -- what actually happened
            actual           TEXT,    -- 'Buy' | 'Sell' | 'Noise'
            -- paper trading
            traded           INTEGER, -- 1 if a position was taken
            position_frac    REAL,
            equity           REAL,    -- equity after this trade resolved
            outcome_pct      REAL     -- price change at first threshold crossing
        );

        -- One row per journal recalibration.
        CREATE TABLE IF NOT EXISTS recalib_log (
            step          INTEGER,  -- candle index when recalib fired
            journal       TEXT,     -- 'visual' | 'thought'
            cos_raw       REAL,     -- cos(buy_proto, sell_proto) before discrimination
            disc_strength REAL,     -- separating signal available (0=none, 1=fully separated)
            buy_count     INTEGER,
            sell_count    INTEGER
        );
    ").expect("failed to init run DB");
    db
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
    let max_pos = args.window.max(args.px_rows * 4);
    for p in 0..max_pos as i64 { vm.get_position_vector(p); }

    // ─ Visual encoding setup ─
    let null_template = build_null_template(args.window, args.px_rows);
    let null_vec = raster_encode(&vm, &null_template, &Vector::zeros(args.dims));
    let visual_cache = VisualCache::new(&vm, args.window, args.px_rows);

    // ─ Thought encoding setup ─
    let thought_vocab   = ThoughtVocab::new(&vm);
    let thought_encoder = ThoughtEncoder::new(thought_vocab);
    // IndicatorStreams parameter is unused by encode_view (v10+), but kept for API compat.
    let thought_streams = IndicatorStreams::new(args.dims, args.window + 48);

    // ─ Named journals ─
    let mut vis_journal = Journal::new("visual",  args.dims, args.recalib_interval);
    let mut tht_journal = Journal::new("thought", args.dims, args.recalib_interval);


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
        ] {
            stmt.execute(params![k, v]).ok();
        }
    }
    eprintln!("  Run database: {}", run_db_path);

    // ─ Trader and tracking ─
    let mut trader    = Trader::new(args.initial_equity, args.observe_period);
    let mut pending:    VecDeque<Pending> = VecDeque::new();
    let mut vis_rolling: VecDeque<bool>  = VecDeque::new();
    let mut tht_rolling: VecDeque<bool>  = VecDeque::new();
    let rolling_cap = 1000usize;

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
    let conviction_window = args.recalib_interval * 100; // ~50k candles
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

        // ── Parallel: visual encode ──────────────────────────────────────────
        let vis_vecs: Vec<(usize, Vector)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let panels = render_viewport(&candles, i, args.window, args.px_rows);
                let vp     = build_viewport(&panels, args.window, args.px_rows);
                let vec    = raster_encode_cached(&visual_cache, &vp, &null_vec);
                (i, vec)
            })
            .collect();

        // ── Parallel: thought encode ─────────────────────────────────────────
        let tht_vecs: Vec<(usize, Vector)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let w_start = i.saturating_sub(args.window - 1);
                let window  = &candles[w_start..=i];
                let result  = thought_encoder.encode_view(window, &thought_streams, 0, 0, &vm);
                (i, result.thought)
            })
            .collect();

        // ── Sequential: predict + buffer + learn + expire ────────────────────
        for ((i, vis_vec), (_, tht_vec)) in vis_vecs.into_iter().zip(tht_vecs) {
            encode_count += 1;

            let vis_pred = vis_journal.predict(&vis_vec);
            let tht_pred = tht_journal.predict(&tht_vec);

            let vis_roll_acc = if vis_rolling.is_empty() { 0.5 }
                else { vis_rolling.iter().filter(|&&x| x).count() as f64 / vis_rolling.len() as f64 };
            let tht_roll_acc = if tht_rolling.is_empty() { 0.5 }
                else { tht_rolling.iter().filter(|&&x| x).count() as f64 / tht_rolling.len() as f64 };

            let (raw_meta_dir, meta_conviction) = orchestrate(
                &args.orchestration,
                &vis_pred, &tht_pred,
                vis_roll_acc, tht_roll_acc,
            );

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
                    "auto" if resolved_preds.len() >= flip_warmup => {
                        // Self-derived min_edge: disabled pending better cold start
                        // handling. Using fixed args.min_edge for now.
                        // TODO: track window win rates only from was_flipped trades,
                        // require >= 100 trades per window, >= 10 windows for stability.

                        // Sort by conviction descending, walk down accumulating
                        // flipped win rate. Find the deepest conviction where
                        // cumulative win rate exceeds derived_min_edge AND is
                        // statistically significant.
                        let mut sorted: Vec<(f64, bool)> = resolved_preds.iter().copied().collect();
                        sorted.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
                        let mut wins = 0u32;
                        let mut total = 0u32;
                        let mut best_threshold = f64::MAX;
                        let min_bucket = 50u32;
                        for &(conv, correct) in &sorted {
                            total += 1;
                            if correct { wins += 1; }
                            if total >= min_bucket {
                                let wr = wins as f64 / total as f64;
                                let ci = 1.96 / (total as f64).sqrt();
                                let floor = args.min_edge.max(0.50 + ci);
                                if wr >= floor {
                                    best_threshold = conv;
                                }
                            }
                        }
                        if best_threshold < f64::MAX {
                            flip_threshold = best_threshold;
                        }
                    }
                    _ => {} // quantile=0 or not enough data yet
                }
            }

            // Contrarian flip: high conviction = trend extreme = reversal likely.
            // Threshold is the data-driven flip_quantile percentile of recent convictions.
            let meta_dir = if flip_threshold > 0.0 && meta_conviction >= flip_threshold {
                raw_meta_dir.map(|d| match d {
                    Outcome::Buy  => Outcome::Sell,
                    Outcome::Sell => Outcome::Buy,
                    Outcome::Noise => Outcome::Noise,
                })
            } else {
                raw_meta_dir
            };

            let position_frac = if meta_dir.is_some() {
                match args.sizing.as_str() {
                    "kelly" => {
                        if trader.phase == Phase::Observe {
                            None
                        } else {
                            match kelly_frac(meta_conviction, &resolved_preds, 50) {
                                Some(frac) => Some(frac),
                                None => { trader.trades_skipped += 1; None }
                            }
                        }
                    }
                    _ => {
                        match trader.position_frac(meta_conviction, args.min_conviction, flip_threshold) {
                            Some(frac) => Some(frac),
                            None => { trader.trades_skipped += 1; None }
                        }
                    }
                }
            } else {
                None
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
                first_outcome: None,
                outcome_pct:   0.0,
                peak_abs_pct:  0.0,
            });

            // Decay once per candle.
            vis_journal.decay(args.decay);
            tht_journal.decay(args.decay);

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
                        let sw = signal_weight(abs_pct, &mut move_sum, &mut move_count);
                        vis_journal.observe(&entry.vis_vec, o, sw);
                        tht_journal.observe(&entry.tht_vec, o, sw);
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
                run_db.execute(
                    "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count)
                     VALUES (?1,?2,?3,?4,?5,?6)",
                    params![
                        encode_count as i64, "thought",
                        tht_journal.last_cos_raw, tht_journal.last_disc_strength,
                        tht_journal.buy.count() as i64, tht_journal.sell.count() as i64,
                    ],
                ).ok();
            }

            // ── Expire entries that have reached horizon age ───────────────
            while let Some(front) = pending.front() {
                if i - front.candle_idx < args.horizon { break; }

                let entry       = pending.pop_front().unwrap();
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

                    // Auto flip calibration: always evaluate the FLIPPED prediction
                    // so the calibration curve measures contrarian accuracy regardless
                    // of whether flipping is currently active.
                    if let Some(raw_dir) = entry.raw_meta_dir {
                        let flipped_dir = match raw_dir {
                            Outcome::Buy  => Outcome::Sell,
                            Outcome::Sell => Outcome::Buy,
                            Outcome::Noise => Outcome::Noise,
                        };
                        let correct = flipped_dir == final_out;
                        resolved_preds.push_back((entry.meta_conviction, correct));
                        if resolved_preds.len() > conviction_window {
                            resolved_preds.pop_front();
                        }
                    }
                }

                // Resolve paper trade.
                if let Some(frac) = entry.position_frac {
                    if let Some(dir) = entry.meta_dir {
                        if final_out != Outcome::Noise {
                            trader.record_trade(entry.outcome_pct, frac, dir, entry.year);
                            // Track flip-zone trade outcomes for self-derived min_edge.
                            // Only trades that were actually flipped at entry time.
                            if entry.was_flipped {
                                window_total += 1;
                                if dir == final_out { window_wins += 1; }
                            }
                        }
                    }
                }

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
                eprintln!(
                    "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | vis={:.1}% tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) vs B&H {:+.1}% | flip@{:.3} edge={:.3}",
                    encode_count, loop_count, rate, eta,
                    &candles[i].ts[..10],
                    trader.phase,
                    vis_acc, tht_acc,
                    trader.trades_taken, trader.win_rate(),
                    trader.equity, ret, bnh,
                    flip_threshold, derived_min_edge,
                );
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
    eprintln!("  Labeled: {}  Noise: {} ({:.1}% noise rate)",
        labeled_count, noise_count,
        noise_count as f64 / (labeled_count + noise_count).max(1) as f64 * 100.0);
    eprintln!();
    eprintln!("  Equity: ${:.2} ({:+.2}%) | B&H: {:+.2}%",
        trader.equity, ret, bnh_final);
    eprintln!("  Trades taken: {}  Won: {}  Win rate: {:.1}%  Skipped: {}",
        trader.trades_taken, trader.trades_won, trader.win_rate(), trader.trades_skipped);
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
