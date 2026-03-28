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
use std::fmt;
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use rusqlite::{Connection, params};
use holon::{Primitives, VectorManager, Vector};
use holon::memory::OnlineSubspace;

use btc_walk::db::load_candles;
use btc_walk::journal::{Journal, Outcome, Prediction};
use btc_walk::thought::{ThoughtEncoder, ThoughtResult, ThoughtVocab, IndicatorStreams};
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
    peak_equity:     f64,
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
            peak_equity: initial_equity,
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
        if self.equity > self.peak_equity { self.peak_equity = self.equity; }
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

    /// Encode portfolio state + expert state as risk thought atoms.
    fn risk_facts(&self, vm: &VectorManager, expert_preds: Option<&[Prediction]>, generalist_pred: Option<&Prediction>, recent_trade_count: usize, candle_count: usize) -> (Vec<Vector>, Vec<String>) {
        let mut facts = Vec::with_capacity(8);
        let mut labels = Vec::with_capacity(8);

        // Drawdown
        let dd = if self.peak_equity > 0.0 {
            (self.peak_equity - self.equity) / self.peak_equity
        } else { 0.0 };
        let dd_zone = if dd < 0.001 { "drawdown-at-peak" }
            else if dd < 0.01 { "drawdown-shallow" }
            else if dd < 0.03 { "drawdown-moderate" }
            else { "drawdown-deep" };
        let dd_vec = Primitives::bind(
            &vm.get_vector("at"),
            &Primitives::bind(&vm.get_vector("drawdown"), &vm.get_vector(dd_zone)),
        );
        facts.push(dd_vec);
        labels.push(format!("(at drawdown {})", dd_zone));

        // Streak
        if !self.rolling.is_empty() {
            let last = *self.rolling.back().unwrap();
            let mut streak_len = 0usize;
            for &outcome in self.rolling.iter().rev() {
                if outcome == last { streak_len += 1; } else { break; }
            }
            let streak_dir = if last { "streak-winning" } else { "streak-losing" };
            let streak_size = if streak_len >= 5 { "streak-long" } else { "streak-short" };
            let s_vec = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(
                    &vm.get_vector("streak"),
                    &Primitives::bind(&vm.get_vector(streak_dir), &vm.get_vector(streak_size)),
                ),
            );
            facts.push(s_vec);
            labels.push(format!("(at streak {} {})", streak_dir, streak_size));
        }

        // Recent accuracy
        if self.rolling.len() >= 10 {
            let recent_acc = self.rolling.iter().filter(|&&x| x).count() as f64
                / self.rolling.len() as f64;
            let acc_zone = if recent_acc > 0.60 { "accuracy-hot" }
                else if recent_acc < 0.45 { "accuracy-cold" }
                else { "accuracy-normal" };
            let a_vec = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("recent-accuracy"), &vm.get_vector(acc_zone)),
            );
            facts.push(a_vec);
            labels.push(format!("(at recent-accuracy {})", acc_zone));
        }

        // Equity curve direction (compare equity to initial)
        let eq_pct = (self.equity - self.initial_equity) / self.initial_equity;
        let eq_zone = if eq_pct > 0.01 { "equity-rising" }
            else if eq_pct < -0.01 { "equity-falling" }
            else { "equity-flat" };
        let e_vec = Primitives::bind(
            &vm.get_vector("at"),
            &Primitives::bind(&vm.get_vector("equity-curve"), &vm.get_vector(eq_zone)),
        );
        facts.push(e_vec);
        labels.push(format!("(at equity-curve {})", eq_zone));

        // Expert state: how are the market experts doing?
        if let Some(gen) = generalist_pred {
            let conv_zone = if gen.conviction > 0.20 { "conviction-extreme" }
                else if gen.conviction > 0.12 { "conviction-moderate" }
                else { "conviction-weak" };
            let cv = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("market-conviction"), &vm.get_vector(conv_zone)),
            );
            facts.push(cv);
            labels.push(format!("(at market-conviction {})", conv_zone));
        }

        if let Some(eps) = expert_preds {
            // Expert agreement: do they agree on direction?
            let dirs: Vec<Option<Outcome>> = eps.iter().map(|p| p.direction).collect();
            let buy_count = dirs.iter().filter(|d| **d == Some(Outcome::Buy)).count();
            let sell_count = dirs.iter().filter(|d| **d == Some(Outcome::Sell)).count();
            let agree_zone = if buy_count >= 4 || sell_count >= 4 { "experts-agree" }
                else { "experts-disagree" };
            let ag = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("expert-agreement"), &vm.get_vector(agree_zone)),
            );
            facts.push(ag);
            labels.push(format!("(at expert-agreement {})", agree_zone));

            // Highest expert conviction
            let max_conv = eps.iter().map(|p| p.conviction).fold(0.0_f64, f64::max);
            let exp_zone = if max_conv > 0.15 { "expert-confident" } else { "expert-uncertain" };
            let ec = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("expert-agreement"), &vm.get_vector(exp_zone)),
            );
            facts.push(ec);
            labels.push(format!("(at expert-state {})", exp_zone));
        }

        // Trade density: am I overtrading?
        if candle_count > 100 {
            let density = self.trades_taken as f64 / candle_count as f64;
            let den_zone = if density > 0.05 { "density-high" }
                else if density < 0.01 { "density-low" }
                else { "density-normal" };
            let dv = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("trade-density"), &vm.get_vector(den_zone)),
            );
            facts.push(dv);
            labels.push(format!("(at trade-density {})", den_zone));
        }

        (facts, labels)
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

/// Kelly position sizing from the exponential conviction-accuracy curve.
///
/// Uses the fitted curve `accuracy = 0.50 + a × exp(b × conviction)` to
/// estimate win rate at any conviction level — no per-level sample minimum.
/// The curve generalizes from ALL resolved predictions.
///
/// Falls back to cumulative estimate if curve fit not available.
/// Returns (position_frac, curve_a, curve_b) or None.
fn kelly_frac(
    conviction: f64,
    resolved: &VecDeque<(f64, bool)>,
    min_sample: usize,
    move_threshold: f64,
) -> Option<(f64, f64, f64)> {
    if resolved.len() < 500 { return None; }

    // Fit the exponential curve from resolved predictions (binned).
    let n_bins = 20usize;
    let mut sorted: Vec<(f64, bool)> = resolved.iter().copied().collect();
    sorted.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let bin_size = sorted.len() / n_bins;
    if bin_size < 10 { return None; }

    let mut points: Vec<(f64, f64)> = Vec::new();
    for bi in 0..n_bins {
        let start = bi * bin_size;
        let end = if bi == n_bins - 1 { sorted.len() } else { (bi + 1) * bin_size };
        let slice = &sorted[start..end];
        let mean_c = slice.iter().map(|(c, _)| c).sum::<f64>() / slice.len() as f64;
        let acc = slice.iter().filter(|(_, w)| *w).count() as f64 / slice.len() as f64;
        if acc > 0.505 {
            if let Some(ln_excess) = Some((acc - 0.50).ln()) {
                if ln_excess.is_finite() {
                    points.push((mean_c, ln_excess));
                }
            }
        }
    }

    // Log-linear regression: ln(acc - 0.50) = ln(a) + b * conviction
    let (win_rate, curve_a, curve_b) = if points.len() >= 3 {
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
            let wr = (0.50 + a * (b * conviction).exp()).min(0.95);
            (wr, a, b)
        } else { return None; }
    } else { return None; };

    let edge = 2.0 * win_rate - 1.0;
    if edge <= 0.0 { return None; }
    let half_kelly_risk = edge / 2.0;
    let position = half_kelly_risk / move_threshold;
    Some((position, curve_a, curve_b))
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
    expert_vecs:   Vec<Vector>,       // per-expert thought vectors
    expert_preds:  Vec<Prediction>,   // per-expert predictions at entry time
    fact_labels:   Vec<String>,      // thought facts present at this candle
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

        -- Top fact contributions to discriminant at each recalibration.
        CREATE TABLE IF NOT EXISTS disc_decode (
            step          INTEGER,  -- recalib step
            journal       TEXT,
            rank          INTEGER,  -- 1 = most influential
            fact_label    TEXT,
            cosine        REAL      -- +buy / -sell
        );

        -- Facts present for each traded candle (flip zone trades only).
        CREATE TABLE IF NOT EXISTS trade_facts (
            step          INTEGER,  -- candle_log step
            fact_label    TEXT
        );

        -- Thought subspace state at each recalibration.
        CREATE TABLE IF NOT EXISTS subspace_log (
            step            INTEGER,
            residual        REAL,     -- current candle's thought residual
            threshold       REAL,     -- adaptive anomaly threshold
            explained       REAL,     -- fraction of variance explained
            top_eigenvalues TEXT      -- JSON array of top-5 eigenvalues
        );

        -- Per-expert predictions logged at entry expiry.
        CREATE TABLE IF NOT EXISTS expert_log (
            step          INTEGER,
            expert        TEXT,
            conviction    REAL,
            direction     TEXT,     -- raw (un-flipped) prediction
            correct       INTEGER   -- 1 if flipped prediction matches actual
        );

        -- Risk state at each trade resolution.
        CREATE TABLE IF NOT EXISTS risk_log (
            step          INTEGER,
            drawdown_pct  REAL,
            streak_len    INTEGER,
            streak_dir    TEXT,     -- 'winning' | 'losing'
            recent_acc    REAL,
            equity_pct    REAL,     -- equity change from initial
            won           INTEGER
        );

        -- Visual + thought vectors for flip-zone trades (for engram analysis).
        CREATE TABLE IF NOT EXISTS trade_vectors (
            step          INTEGER PRIMARY KEY,
            won           INTEGER,  -- 1 if trade was correct
            vis_data      BLOB,     -- bipolar visual vector (i8 array)
            tht_data      BLOB      -- bipolar thought vector (i8 array)
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
    let max_pos = args.window;
    for p in 0..max_pos as i64 { vm.get_position_vector(p); }

    // ─ Visual encoding setup ─
    // Visual encoding removed. Null vector kept for Pending struct compatibility.
    let null_vec = Vector::zeros(args.dims);

    // ─ Thought encoding setup ─
    let thought_vocab   = ThoughtVocab::new(&vm);
    let thought_encoder = ThoughtEncoder::new(thought_vocab);
    let (codebook_labels, codebook_vecs) = thought_encoder.fact_codebook();
    // IndicatorStreams parameter is unused by encode_view (v10+), but kept for API compat.
    let thought_streams = IndicatorStreams::new(args.dims, args.window + 48);

    // ─ Named journals ─
    // Visual journal removed — Chapter 1 artifact. See BOOK.md.
    // Stub journal kept for DB logging compatibility (vis_cos/vis_pred columns).
    let mut vis_journal = Journal::new("visual-stub", args.dims, args.recalib_interval);
    let mut tht_journal = Journal::new("thought", args.dims, args.recalib_interval);

    // ─ Visual pattern memory: auto-clustering engram groups ─────────────
    // Each group is an OnlineSubspace that learns a cluster of similar visual
    // patterns from winning flip-zone trades. New groups auto-discovered when
    // a winning visual vector doesn't match any existing group.
    struct PatternGroup {
        centroid: Vec<f64>,   // running mean of visual vectors in this group
        count: usize,
        wins: usize,
        losses: usize,
    }
    impl PatternGroup {
        fn cosine(&self, x: &[f64]) -> f64 {
            let dot: f64 = self.centroid.iter().zip(x.iter()).map(|(a, b)| a * b).sum();
            let na: f64 = self.centroid.iter().map(|a| a * a).sum::<f64>().sqrt();
            let nb: f64 = x.iter().map(|b| b * b).sum::<f64>().sqrt();
            if na > 1e-10 && nb > 1e-10 { dot / (na * nb) } else { 0.0 }
        }
        fn add(&mut self, x: &[f64]) {
            let n = self.count as f64;
            for (c, &v) in self.centroid.iter_mut().zip(x.iter()) {
                *c = (*c * n + v) / (n + 1.0);
            }
            self.count += 1;
        }
    }
    let mut visual_groups: Vec<PatternGroup> = Vec::new();
    let group_cos_threshold = 0.35; // minimum cosine to join an existing group

    // ─ Risk expert: separate journal that learns from portfolio state ───
    // Sees ONLY risk thoughts (drawdown, streak, accuracy, equity curve).
    // Learns which portfolio states precede winning vs losing trades.
    // Its conviction = "how confident am I about the portfolio state?"
    // Its curve = "does portfolio state predict trade quality?"
    let mut risk_journal = Journal::new("risk", args.dims, args.recalib_interval);
    let mut risk_resolved: VecDeque<(f64, bool)> = VecDeque::new();

    // ─ Expert panel: N journals with different vocabulary profiles ──────
    // Each expert thinks different thoughts about the same candles.
    // The orchestrator selects the expert with highest conviction × curve quality.
    struct Expert {
        name: &'static str,
        profile: &'static str,
        journal: Journal,
        resolved: VecDeque<(f64, bool)>,
        // Engram memory: subspace of "good discriminant states."
        // When the current discriminant matches this subspace (low residual),
        // this expert is likely in a good state.
        good_state_subspace: OnlineSubspace,
        // Track accuracy since last recalib for engram gating.
        recalib_wins: u32,
        recalib_total: u32,
        last_recalib_count: usize,
    }
    let expert_profiles = ["momentum", "structure", "volume", "narrative", "regime"];
    let mut experts: Vec<Expert> = expert_profiles.iter().map(|&profile| {
        Expert {
            name: profile,
            profile,
            journal: Journal::new(profile, args.dims, args.recalib_interval),
            resolved: VecDeque::new(),
            good_state_subspace: OnlineSubspace::new(args.dims, 8),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
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

        // ── Parallel: thought encode (full + expert profiles) ────────────────
        let sup_ref = if suppressed_facts.is_empty() { None } else { Some(&suppressed_facts) };
        let n_experts = experts.len();
        let tht_vecs: Vec<(usize, Vector, Vec<String>, Vec<Vector>)> = (cursor..batch_end)
            .into_par_iter()
            .map(|i| {
                let w_start = i.saturating_sub(args.window - 1);
                let window  = &candles[w_start..=i];
                let full = thought_encoder.encode_view(window, &thought_streams, 0, 0, &vm, None, sup_ref, "full");
                // Encode for each expert profile
                let expert_vecs: Vec<Vector> = expert_profiles.iter()
                    .map(|&profile| {
                        thought_encoder.encode_view(window, &thought_streams, 0, 0, &vm, None, None, profile).thought
                    })
                    .collect();
                (i, full.thought, full.fact_labels, expert_vecs)
            })
            .collect();

        // ── Sequential: predict + buffer + learn + expire ────────────────────
        for (i, tht_vec, tht_facts, expert_vecs) in tht_vecs {
            encode_count += 1;

            // Expert panel: predict from each expert
            let expert_preds: Vec<Prediction> = expert_vecs.iter().enumerate()
                .map(|(ei, vec)| experts[ei].journal.predict(vec))
                .collect();

            let vis_vec = null_vec.clone(); // stub for Pending compatibility
            let vis_pred = Prediction::default();

            // ── Expert selection: (max-by curve-quality experts) ─────────
            // The generalist predicts. Then each expert competes.
            // Winner = expert whose estimated flipped accuracy at their
            // current conviction is highest. Falls back to generalist
            // if no expert has enough data.
            let tht_pred = tht_journal.predict(&tht_vec);
            let mut best_pred = tht_pred.clone();
            let mut best_source = "generalist";
            let min_expert_resolved = 500usize;

            // Estimate generalist ROLLING accuracy (last 200 resolved)
            let rolling_window = 200usize;
            let gen_acc = {
                let recent: Vec<&(f64, bool)> = resolved_preds.iter().rev()
                    .take(rolling_window).collect();
                let above: usize = recent.iter()
                    .filter(|(c, _)| *c >= tht_pred.conviction).count();
                let wins: usize = recent.iter()
                    .filter(|(c, w)| *c >= tht_pred.conviction && *w).count();
                if above >= 20 { wins as f64 / above as f64 } else { 0.50 }
            };

            // Generalist drives direction. No expert overrides.
            // Panel engram modulates SIZING confidence (Layer 2).
            // Encode panel state: each expert's signed conviction.
            let mut panel_state: Vec<f64> = vec![tht_pred.raw_cos]; // generalist
            for ep in &expert_preds {
                panel_state.push(ep.raw_cos);
            }
            // Query panel engram: does this configuration match a known good one?
            let panel_familiar = if panel_engram.n() >= 10 {
                let residual = panel_engram.residual(&panel_state);
                let threshold = panel_engram.threshold();
                residual < threshold // true = familiar good config
            } else {
                false
            };
            let tht_pred = best_pred;

            let vis_roll_acc = if vis_rolling.is_empty() { 0.5 }
                else { vis_rolling.iter().filter(|&&x| x).count() as f64 / vis_rolling.len() as f64 };
            let tht_roll_acc = if tht_rolling.is_empty() { 0.5 }
                else { tht_rolling.iter().filter(|&&x| x).count() as f64 / tht_rolling.len() as f64 };

            let (mut raw_meta_dir, mut meta_conviction) = orchestrate(
                &args.orchestration,
                &vis_pred, &tht_pred,
                vis_roll_acc, tht_roll_acc,
            );

            // Expert panel: observe only, don't override predictions.
            // Experts build their curves independently. Selection comes later
            // once we understand their conviction scales and regime strengths.
            // The generalist drives all trading decisions.

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

            // Position sizing: Kelly from the curve × drawdown cap.
            // The curve handles selectivity. The drawdown cap handles survival.
            // Nothing else. No graduated gate, no stability gate, no phase gate.
            // Risk expert: encode portfolio state, predict, get conviction.
            let (risk_vecs, _risk_labels) = trader.risk_facts(&vm, Some(&expert_preds), Some(&tht_pred), trader.trades_taken, encode_count);
            let risk_vec = if risk_vecs.is_empty() {
                Vector::zeros(args.dims)
            } else {
                let refs: Vec<&Vector> = risk_vecs.iter().collect();
                Primitives::bundle(&refs)
            };
            let risk_pred = risk_journal.predict(&risk_vec);
            risk_journal.decay(args.decay);

            // Kelly from curve × risk expert sizing multiplier.
            // Risk conviction → risk curve → estimated accuracy of portfolio state
            // → Kelly multiplier. High risk conviction + favorable = scale up.
            // High risk conviction + unfavorable = scale down.
            let risk_mult = if risk_resolved.len() >= 500 {
                // Estimate risk accuracy at current conviction
                let above: usize = risk_resolved.iter()
                    .filter(|(c, _)| *c >= risk_pred.conviction).count();
                let wins: usize = risk_resolved.iter()
                    .filter(|(c, w)| *c >= risk_pred.conviction && *w).count();
                if above >= 20 {
                    let risk_acc = wins as f64 / above as f64;
                    (risk_acc * 2.0 - 1.0).max(0.0).min(2.0)
                } else { 0.25 } // insufficient data at this conviction → cautious
            } else { 0.25 }; // "I don't know yet" → be careful, not full speed

            // The flip zone gate stays — below the threshold, the direction
            // isn't flipped, so it's WRONG. Kelly can't fix wrong direction.
            let position_frac = if meta_dir.is_some()
                && trader.phase != Phase::Observe
                && (flip_threshold <= 0.0 || meta_conviction >= flip_threshold)
            {
                let mt = if args.atr_multiplier > 0.0 {
                    args.atr_multiplier * candles[i].atr_r
                } else { args.move_threshold };

                match args.sizing.as_str() {
                    "kelly" => {
                        match kelly_frac(meta_conviction, &resolved_preds, 50, mt) {
                            Some((frac, a, b)) => {
                                // Track curve params (for logging/diagnostics)
                                if curve_a_history.is_empty()
                                    || curve_a_history.back() != Some(&a) {
                                    curve_a_history.push_back(a);
                                    curve_b_history.push_back(b);
                                    if curve_a_history.len() > 10 { curve_a_history.pop_front(); }
                                    if curve_b_history.len() > 10 { curve_b_history.pop_front(); }
                                }
                                // Drawdown cap: the only risk gate.
                                let dd = if trader.peak_equity > 0.0 {
                                    (trader.peak_equity - trader.equity) / trader.peak_equity
                                } else { 0.0 };
                                let dd_room = (args.max_drawdown - dd).max(0.0);
                                let cap = (dd_room / (4.0 * mt)).min(1.0);
                                let sized = frac.min(cap) * risk_mult;
                                if sized < 1e-6 { None } else { Some(sized) }
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
                peak_abs_pct:  0.0,
            });

            // Decay once per candle.
            vis_journal.decay(adaptive_decay);
            tht_journal.decay(adaptive_decay);
            tht_fast.decay(decay_fast);
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
                        tht_fast.observe(&entry.tht_vec, o, sw);
                        // Expert panel: each expert observes, tracks curve, and feeds engrams
                        for (ei, expert_vec) in entry.expert_vecs.iter().enumerate() {
                            experts[ei].journal.observe(expert_vec, o, sw);
                            // Track accuracy since last recalib for engram gating
                            if let Some(raw_dir) = entry.expert_preds[ei].direction {
                                let flipped = match raw_dir {
                                    Outcome::Buy => Outcome::Sell,
                                    Outcome::Sell => Outcome::Buy,
                                    Outcome::Noise => Outcome::Noise,
                                };
                                experts[ei].recalib_total += 1;
                                if flipped == o { experts[ei].recalib_wins += 1; }
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
                            if let Some(raw_dir) = entry.expert_preds[ei].direction {
                                let flipped = match raw_dir {
                                    Outcome::Buy  => Outcome::Sell,
                                    Outcome::Sell => Outcome::Buy,
                                    Outcome::Noise => Outcome::Noise,
                                };
                                let correct = flipped == o;
                                experts[ei].resolved.push_back(
                                    (entry.expert_preds[ei].conviction, correct));
                                if experts[ei].resolved.len() > conviction_window {
                                    experts[ei].resolved.pop_front();
                                }
                                // Log for post-hoc analysis
                                run_db.execute(
                                    "INSERT INTO expert_log (step,expert,conviction,direction,correct)
                                     VALUES (?1,?2,?3,?4,?5)",
                                    params![
                                        log_step,
                                        experts[ei].name,
                                        entry.expert_preds[ei].conviction,
                                        raw_dir.to_string(),
                                        correct as i32,
                                    ],
                                ).ok();
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
                            // Risk expert learns from this trade's outcome.
                            // It observes the risk vec that was present at entry time.
                            // (We use current risk state as proxy — close enough since
                            // entries resolve within horizon=36 candles.)
                            {
                                let (rv, _) = trader.risk_facts(&vm, None, None, trader.trades_taken, encode_count);
                                if !rv.is_empty() {
                                    let rvec = Primitives::bundle(&rv.iter().collect::<Vec<_>>());
                                    risk_journal.observe(&rvec, final_out, 1.0);
                                    // Track risk curve
                                    let rpred = risk_journal.predict(&rvec);
                                    if let Some(rd) = rpred.direction {
                                        let flipped_rd = match rd {
                                            Outcome::Buy => Outcome::Sell,
                                            Outcome::Sell => Outcome::Buy,
                                            Outcome::Noise => Outcome::Noise,
                                        };
                                        risk_resolved.push_back((rpred.conviction, flipped_rd == final_out));
                                        if risk_resolved.len() > conviction_window {
                                            risk_resolved.pop_front();
                                        }
                                    }
                                }
                            }

                            // Track panel accuracy for engram gating
                            panel_recalib_total += 1;
                            if dir == final_out { panel_recalib_wins += 1; }

                            // Log risk state at trade resolution
                            {
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
                                run_db.execute(
                                    "INSERT INTO risk_log (step,drawdown_pct,streak_len,streak_dir,recent_acc,equity_pct,won)
                                     VALUES (?1,?2,?3,?4,?5,?6,?7)",
                                    params![log_step, dd, streak_len, streak_dir, recent_acc, eq_pct, won],
                                ).ok();
                            }
                            // Route visual vector to pattern groups.
                            // Score against all groups, assign to best match or create new.
                            if entry.was_flipped {
                                let vis_f64: Vec<f64> = entry.vis_vec.data().iter()
                                    .map(|&v| v as f64).collect();
                                let won = dir == final_out;

                                // Find best matching group by cosine to centroid.
                                let mut best_idx: Option<usize> = None;
                                let mut best_cos = group_cos_threshold;
                                for (gi, group) in visual_groups.iter().enumerate() {
                                    let cos = group.cosine(&vis_f64);
                                    if cos > best_cos {
                                        best_cos = cos;
                                        best_idx = Some(gi);
                                    }
                                }
                                match best_idx {
                                    Some(gi) => {
                                        visual_groups[gi].add(&vis_f64);
                                        if won { visual_groups[gi].wins += 1; }
                                        else   { visual_groups[gi].losses += 1; }
                                    }
                                    None => {
                                        // No match — new pattern type discovered.
                                        visual_groups.push(PatternGroup {
                                            centroid: vis_f64.clone(),
                                            count: 1,
                                            wins: if won { 1 } else { 0 },
                                            losses: if won { 0 } else { 1 },
                                        });
                                    }
                                }
                            }

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
                                run_db.execute(
                                    "INSERT INTO trade_facts (step, fact_label) VALUES (?1, ?2)",
                                    params![log_step, label],
                                ).ok();
                            }
                            // Store visual + thought vectors for engram analysis.
                            if entry.was_flipped {
                                let won = (dir == final_out) as i32;
                                let vis_bytes: Vec<u8> = entry.vis_vec.data().iter()
                                    .map(|&v| v as u8).collect();
                                let tht_bytes: Vec<u8> = entry.tht_vec.data().iter()
                                    .map(|&v| v as u8).collect();
                                run_db.execute(
                                    "INSERT INTO trade_vectors (step, won, vis_data, tht_data)
                                     VALUES (?1, ?2, ?3, ?4)",
                                    params![
                                        log_step, won,
                                        vis_bytes,
                                        tht_bytes,
                                    ],
                                ).ok();
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
                    "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | vis={:.1}% tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) vs B&H {:+.1}% | flip@{:.3} {}",
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
    if !visual_groups.is_empty() {
        eprintln!();
        eprintln!("  Visual pattern groups: {} discovered", visual_groups.len());
        for (i, g) in visual_groups.iter().enumerate() {
            let total = g.wins + g.losses;
            let wr = if total > 0 { g.wins as f64 / total as f64 * 100.0 } else { 0.0 };
            eprintln!("    Group {}: {} obs, {} trades ({}W/{}L = {:.1}%)",
                i, g.count, total, g.wins, g.losses, wr);
        }
    }
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
