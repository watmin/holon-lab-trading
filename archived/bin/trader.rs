use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::PathBuf;
use std::time::Instant;

use clap::Parser;
use rayon::prelude::*;
use rusqlite::{Connection, params};
use holon::{Accumulator, Primitives, VectorManager, Vector};

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

    /// Global scale factor for all accumulator writes (raw adds, corrections, confusers)
    #[arg(long, default_value_t = 1.0)]
    learning_rate: f64,

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

    /// Path for run database (absolute). Auto-generated if not provided.
    #[arg(long)]
    run_db: Option<PathBuf>,
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

/// Cosine similarity between two float vectors.
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

/// Cosine similarity between a float prototype (from normalize_f64) and a bipolar input vector.
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

/// Float-space column unbinding: multiply each f64 dim by position's +1/-1.
/// Bipolar bind is self-inverse, so this extracts column content from a continuous prototype.
fn unbind_f64(pos: &Vector, proto_f64: &[f64]) -> Vec<f64> {
    proto_f64.iter().zip(pos.data().iter())
        .map(|(&p, &v)| p * (v as f64))
        .collect()
}

/// Cosine between two bipolar vectors using integer dot product.
/// Both vectors must be bipolar (elements in {-1, 0, 1}).
/// cosine = dot / (norm_a * norm_b), where norm = sqrt(nnz) for bipolar.
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

/// Coverage-based prediction for visual disc atoms.
fn vis_disc_coverage(input: &Vector, atoms: &[VisDiscAtom], noise_floor: f64) -> (f64, usize, usize) {
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

// ─── Prediction Detail ──────────────────────────────────────────────────────

#[derive(Clone)]
struct PredictionDetail {
    prediction: Option<Outcome>,
    buy_coverage: f64,
    sell_coverage: f64,
    buy_atoms_found: usize,
    buy_atoms_total: usize,
    sell_atoms_found: usize,
    sell_atoms_total: usize,
    buy_sim: f64,
    sell_sim: f64,
}

impl Default for PredictionDetail {
    fn default() -> Self {
        Self {
            prediction: None,
            buy_coverage: 0.0,
            sell_coverage: 0.0,
            buy_atoms_found: 0,
            buy_atoms_total: 0,
            sell_atoms_found: 0,
            sell_atoms_total: 0,
            buy_sim: 0.0,
            sell_sim: 0.0,
        }
    }
}

// ─── Journaler ──────────────────────────────────────────────────────────────

struct VisDiscAtom {
    atom_vec: Vector,
    weight: f64,
    label: String,
}

struct Journaler {
    buy_good: Accumulator,
    sell_good: Accumulator,
    updates: usize,
    recalib_interval: usize,
    dims: usize,
    noise_floor: f64,
    codebook_vecs: Vec<Vector>,
    codebook_labels: Vec<String>,
    col_positions: Vec<Vector>,
    disc_buy_atoms: Vec<VisDiscAtom>,
    disc_sell_atoms: Vec<VisDiscAtom>,
    disc_proj_atoms: Vec<VisDiscAtom>,
    proj_used: usize,
    proj_skipped: usize,
}

impl Journaler {
    fn new(dims: usize, recalib_interval: usize, _use_grover: bool, _use_attend: bool) -> Self {
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
            col_positions: Vec::new(),
            disc_buy_atoms: Vec::new(),
            disc_sell_atoms: Vec::new(),
            disc_proj_atoms: Vec::new(),
            proj_used: 0,
            proj_skipped: 0,
        }
    }

    fn set_visual_codebook(&mut self, codebook_vecs: Vec<Vector>, codebook_labels: Vec<String>, col_positions: Vec<Vector>) {
        self.codebook_vecs = codebook_vecs;
        self.codebook_labels = codebook_labels;
        self.col_positions = col_positions;
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

        let has_buy = !self.disc_buy_atoms.is_empty();
        let has_sell = !self.disc_sell_atoms.is_empty();
        if !has_buy && !has_sell {
            return PredictionDetail::default();
        }

        let (buy_cov, buy_found, buy_total) = vis_disc_coverage(vec, &self.disc_buy_atoms, self.noise_floor);
        let (sell_cov, sell_found, sell_total) = vis_disc_coverage(vec, &self.disc_sell_atoms, self.noise_floor);

        let prediction = if has_buy && has_sell {
            if buy_cov > sell_cov { Some(Outcome::Buy) } else { Some(Outcome::Sell) }
        } else if has_buy && buy_cov > 0.0 {
            Some(Outcome::Buy)
        } else if has_sell && sell_cov > 0.0 {
            Some(Outcome::Sell)
        } else {
            None
        };

        PredictionDetail {
            prediction,
            buy_coverage: buy_cov,
            sell_coverage: sell_cov,
            buy_atoms_found: buy_found,
            buy_atoms_total: buy_total,
            sell_atoms_found: sell_found,
            sell_atoms_total: sell_total,
            buy_sim: buy_cov,
            sell_sim: sell_cov,
        }
    }

    fn decay_all(&mut self, decay: f64) {
        self.buy_good.decay(decay);
        self.sell_good.decay(decay);
    }

    fn observe(
        &mut self,
        vec: &Vector,
        outcome: Outcome,
        signal_weight: f64,
    ) {
        if outcome == Outcome::Noise { return; }

        self.updates += 1;
        if self.updates % self.recalib_interval == 0 {
            self.recalibrate();
        }

        let learn_vec = self.project_to_disc(vec);
        let target = learn_vec.as_ref().unwrap_or(vec);
        if learn_vec.is_some() { self.proj_used += 1; } else { self.proj_skipped += 1; }

        match outcome {
            Outcome::Buy => self.buy_good.add_weighted(target, signal_weight),
            Outcome::Sell => self.sell_good.add_weighted(target, signal_weight),
            _ => {}
        }
    }

    fn project_to_disc(&self, input: &Vector) -> Option<Vector> {
        if self.disc_proj_atoms.is_empty() { return None; }
        let input_data = input.data();
        let mut found: Vec<&Vector> = Vec::new();
        for atom in &self.disc_proj_atoms {
            if bipolar_cosine(input_data, atom.atom_vec.data()) > self.noise_floor {
                found.push(&atom.atom_vec);
            }
        }
        if found.is_empty() { return None; }
        Some(Primitives::bundle(&found))
    }

    fn recalibrate(&mut self) {
        if !self.is_ready() { return; }
        let buy_proto = self.buy_good.threshold();
        let sell_proto = self.sell_good.threshold();

        let buy_entropy = Primitives::entropy(&buy_proto);
        let sell_entropy = Primitives::entropy(&sell_proto);
        let min_entropy = buy_entropy.min(sell_entropy).max(0.01);
        let d_eff = self.dims as f64 * min_entropy;
        self.noise_floor = 1.0 / d_eff.sqrt();

        let source_buy_f64 = self.buy_good.normalize_f64();
        let source_sell_f64 = self.sell_good.normalize_f64();

        if self.codebook_vecs.is_empty() || self.col_positions.is_empty() { return; }

        let mut atom_buy_sims: HashMap<(usize, usize), f64> = HashMap::new();
        let mut atom_sell_sims: HashMap<(usize, usize), f64> = HashMap::new();

        for (ci, col_pos) in self.col_positions.iter().enumerate() {
            let buy_col = unbind_f64(col_pos, &source_buy_f64);
            let sell_col = unbind_f64(col_pos, &source_sell_f64);

            for (idx, sim) in invert_f64(&buy_col, &self.codebook_vecs, 20) {
                atom_buy_sims.insert((ci, idx), sim);
            }
            for (idx, sim) in invert_f64(&sell_col, &self.codebook_vecs, 20) {
                atom_sell_sims.insert((ci, idx), sim);
            }
        }

        let all_keys: HashSet<(usize, usize)> = atom_buy_sims.keys()
            .chain(atom_sell_sims.keys()).copied().collect();

        let mut new_buy_atoms: Vec<VisDiscAtom> = Vec::new();
        let mut new_sell_atoms: Vec<VisDiscAtom> = Vec::new();

        for &(ci, atom_idx) in &all_keys {
            let bs = atom_buy_sims.get(&(ci, atom_idx)).copied().unwrap_or(0.0);
            let ss = atom_sell_sims.get(&(ci, atom_idx)).copied().unwrap_or(0.0);
            let diff = bs - ss;
            let label_base = if atom_idx < self.codebook_labels.len() {
                &self.codebook_labels[atom_idx]
            } else {
                "?"
            };
            let label = format!("c{}-{}", ci, label_base);

            // Rebind column position into atom vec so it matches input structure
            let col_data = self.col_positions[ci].data();
            let atom_data = self.codebook_vecs[atom_idx].data();
            let bound: Vec<i8> = col_data.iter().zip(atom_data.iter())
                .map(|(&c, &a)| if c * a > 0 { 1i8 } else { -1i8 })
                .collect();
            let bound_vec = Vector::from_data(bound);

            if diff > 0.0 {
                new_buy_atoms.push(VisDiscAtom { atom_vec: bound_vec, weight: diff, label });
            } else if diff < 0.0 {
                new_sell_atoms.push(VisDiscAtom { atom_vec: bound_vec, weight: diff.abs(), label });
            }
        }

        self.disc_buy_atoms = new_buy_atoms;
        self.disc_sell_atoms = new_sell_atoms;

        // Build capped projection list: top atoms by weight covering 90% of total weight
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
            self.disc_proj_atoms.push(VisDiscAtom {
                atom_vec: (*vec).clone(),
                weight: *w,
                label: String::new(),
            });
            cum_w += w;
            kept += 1;
        }

        // Distribution diagnostic: how many atoms for 50/80/90/95%
        let pcts = [0.50, 0.80, 0.90, 0.95];
        let mut counts = [0usize; 4];
        cum_w = 0.0;
        for (pi, &frac) in pcts.iter().enumerate() {
            let target = total_w * frac;
            while cum_w < target && counts[pi] < all_proj.len() {
                cum_w += all_proj[counts[pi]].1;
                counts[pi] += 1;
            }
            if pi + 1 < pcts.len() {
                counts[pi + 1] = counts[pi];
            }
        }
        eprintln!("      vis weight dist: total={:.2} | 50%={} 80%={} 90%={} 95%={} of {} atoms → proj={}",
            total_w, counts[0], counts[1], counts[2], counts[3], all_proj.len(), kept);
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

fn compute_signal_weight(abs_move: f64, move_sum: &mut f64, move_count: &mut usize, learning_rate: f64) -> f64 {
    *move_sum += abs_move;
    *move_count += 1;
    let mean_move = *move_sum / *move_count as f64;
    (abs_move / mean_move) * learning_rate
}

struct PendingEntry {
    candle_idx: usize,
    vec: Vector,
    journaler_prediction: Option<Outcome>,
    trade_action: Option<TradeAction>,
    thought_vec: Vector,
    thought_prediction: Option<thought::Outcome>,
    thought_detail: thought::ThoughtPrediction,
    vis_detail: PredictionDetail,
    learn_count: usize,
    first_outcome: Option<Outcome>,
    peak_pct: f64,
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
    eprintln!("  Reward weight: {}, Correction weight: {}, Learning rate: {}", args.reward_weight, args.correction_weight, args.learning_rate);
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
    thought_journaler.set_codebook(&fact_codebook);
    eprintln!("  Thought system ready ({} fact codebook entries).", fact_codebook.labels.len());

    // Initialize run database for structured logging
    let run_db_path = if let Some(ref p) = args.run_db {
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        p.display().to_string()
    } else {
        let run_ts = chrono::Utc::now().format("%Y%m%d_%H%M%S").to_string();
        std::fs::create_dir_all("runs").ok();
        format!("runs/run_{}.db", run_ts)
    };
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
            -- visual prediction
            vis_pred          TEXT,
            vis_buy_coverage  REAL,
            vis_sell_coverage REAL,
            vis_buy_atoms_found  INTEGER,
            vis_buy_atoms_total  INTEGER,
            vis_sell_atoms_found INTEGER,
            vis_sell_atoms_total INTEGER,
            vis_buy_sim       REAL,
            vis_sell_sim      REAL,
            -- thought prediction
            thought_pred      TEXT,
            thought_buy_coverage  REAL,
            thought_sell_coverage REAL,
            thought_buy_atoms_found  INTEGER,
            thought_buy_atoms_total  INTEGER,
            thought_sell_atoms_found INTEGER,
            thought_sell_atoms_total INTEGER,
            thought_buy_sim   REAL,
            thought_sell_sim  REAL,
            -- agreement
            agree             INTEGER,
            -- outcome (filled when resolved)
            actual            TEXT,
            -- trader
            action            TEXT,
            equity            REAL,
            -- event-driven resolution
            learn_count       INTEGER,
            peak_pct          REAL
        );

        CREATE TABLE IF NOT EXISTS recalib_log (
            step          INTEGER,
            system        TEXT,
            cos_buy_sell  REAL,
            noise_floor   REAL,
            buy_count     INTEGER,
            sell_count    INTEGER,
            buy_purity    REAL,
            sell_purity   REAL,
            disc_buy_atoms   INTEGER,
            disc_sell_atoms  INTEGER,
            disc_buy_total_weight REAL,
            disc_sell_total_weight REAL,
            proj_used     INTEGER,
            proj_skipped  INTEGER,
            proj_atoms    INTEGER
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
    {
        let (vis_cb_vecs, vis_cb_labels) = visual_cache.build_codebook();
        let col_pos = visual_cache.col_positions().to_vec();
        eprintln!("  Visual codebook: {} cell atoms, {} columns", vis_cb_vecs.len(), col_pos.len());
        journaler.set_visual_codebook(vis_cb_vecs, vis_cb_labels, col_pos);
    }
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
    let mut agree_rolling: VecDeque<bool> = VecDeque::new();

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
    let mut move_sum: f64 = 0.0;
    let mut move_count: usize = 0;
    let t_start = Instant::now();

    eprintln!("\n  Starting walk-forward ({} candles, starting at index {})...",
        loop_count, start_idx);

    let kill_file = std::path::Path::new("trader-stop");
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
        if kill_file.exists() {
            eprintln!("\n  Kill file detected ({}) — aborting.", kill_file.display());
            std::fs::remove_file(kill_file).ok();
            break;
        }
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
            let conviction = (vis_detail.buy_coverage - vis_detail.sell_coverage).abs();

            let t_outcome = t_pred.outcome;
            let t_conviction = (t_pred.buy_coverage - t_pred.sell_coverage).abs();
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
                trade_action,
                thought_vec: thought_result.thought,
                thought_prediction: t_outcome,
                thought_detail: t_pred,
                vis_detail: vis_detail.clone(),
                learn_count: 0,
                first_outcome: None,
                peak_pct: 0.0,
            });

            // Decay once per candle (decoupled from learn event frequency)
            journaler.decay_all(args.decay);
            thought_journaler.decay_all(args.decay);

            // Phase 1: Event-driven learning — scan all pending entries
            let current_price = candles[i].close;
            for entry in pending.iter_mut() {
                let entry_price = candles[entry.candle_idx].close;
                let pct = (current_price - entry_price) / entry_price;
                let abs_pct = pct.abs();

                if abs_pct > entry.peak_pct { entry.peak_pct = abs_pct; }

                if pct > args.move_threshold {
                    let sw = compute_signal_weight(abs_pct, &mut move_sum, &mut move_count, args.learning_rate);
                    journaler.observe(&entry.vec, Outcome::Buy, sw);
                    thought_journaler.observe(&entry.thought_vec, thought::Outcome::Buy, sw);
                    entry.learn_count += 1;
                    if entry.first_outcome.is_none() { entry.first_outcome = Some(Outcome::Buy); }
                } else if pct < -args.move_threshold {
                    let sw = compute_signal_weight(abs_pct, &mut move_sum, &mut move_count, args.learning_rate);
                    journaler.observe(&entry.vec, Outcome::Sell, sw);
                    thought_journaler.observe(&entry.thought_vec, thought::Outcome::Sell, sw);
                    entry.learn_count += 1;
                    if entry.first_outcome.is_none() { entry.first_outcome = Some(Outcome::Sell); }
                }
            }

            // Phase 2: Expire entries that reached horizon age
            while let Some(front) = pending.front() {
                if i - front.candle_idx >= args.horizon {
                    let entry = pending.pop_front().unwrap();
                    let entry_candle = &candles[entry.candle_idx];

                    let final_outcome = entry.first_outcome.unwrap_or(Outcome::Noise);

                    match final_outcome {
                        Outcome::Noise => noise_count += 1,
                        _ => labeled_count += 1,
                    }

                    // Visual accuracy tracking (based on first crossing)
                    if let Some(pred) = entry.journaler_prediction {
                        if final_outcome != Outcome::Noise {
                            let is_correct = pred == final_outcome;
                            j_total += 1;
                            if is_correct { j_correct += 1; }
                            j_rolling.push_back(is_correct);
                            if j_rolling.len() > j_rolling_cap { j_rolling.pop_front(); }
                            let ye = j_by_year.entry(entry_candle.year).or_insert((0, 0));
                            ye.1 += 1;
                            if is_correct { ye.0 += 1; }
                        }
                    }

                    // Thought accuracy tracking
                    if let Some(t_pred) = entry.thought_prediction {
                        if final_outcome != Outcome::Noise {
                            let t_is_correct = (t_pred == thought::Outcome::Buy && final_outcome == Outcome::Buy)
                                || (t_pred == thought::Outcome::Sell && final_outcome == Outcome::Sell);
                            tj_total += 1;
                            if t_is_correct { tj_correct += 1; }
                            tj_rolling.push_back(t_is_correct);
                            if tj_rolling.len() > j_rolling_cap { tj_rolling.pop_front(); }
                        }
                    }

                    // Agreement accuracy
                    if let (Some(vp), Some(tp)) = (entry.journaler_prediction, entry.thought_prediction) {
                        if final_outcome != Outcome::Noise {
                            let v_buy = vp == Outcome::Buy;
                            let t_buy = tp == thought::Outcome::Buy;
                            if v_buy == t_buy {
                                let correct = (v_buy && final_outcome == Outcome::Buy)
                                    || (!v_buy && final_outcome == Outcome::Sell);
                                agree_rolling.push_back(correct);
                                if agree_rolling.len() > j_rolling_cap { agree_rolling.pop_front(); }
                            }
                        }
                    }

                    if let Some(ref action) = entry.trade_action {
                        if final_outcome != Outcome::Noise {
                            let pct_for_trade = if final_outcome == Outcome::Buy { entry.peak_pct } else { -entry.peak_pct };
                            trader.record_trade(pct_for_trade, action.position_frac, action.direction, entry_candle.year);
                        }
                    }

                    // Log to run DB at expiry
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
                    let actual_str = format!("{:?}", final_outcome);

                    let td = &entry.thought_detail;
                    run_db.execute(
                        "INSERT INTO candle_log (step, candle_idx, timestamp,
                            vis_pred, vis_buy_coverage, vis_sell_coverage,
                            vis_buy_atoms_found, vis_buy_atoms_total,
                            vis_sell_atoms_found, vis_sell_atoms_total,
                            vis_buy_sim, vis_sell_sim,
                            thought_pred, thought_buy_coverage, thought_sell_coverage,
                            thought_buy_atoms_found, thought_buy_atoms_total,
                            thought_sell_atoms_found, thought_sell_atoms_total,
                            thought_buy_sim, thought_sell_sim,
                            agree, actual, action, equity, learn_count, peak_pct)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27)",
                        params![
                            log_step, entry.candle_idx as i64, &entry_candle.ts,
                            vis_pred_str, vd.buy_coverage, vd.sell_coverage,
                            vd.buy_atoms_found as i64, vd.buy_atoms_total as i64,
                            vd.sell_atoms_found as i64, vd.sell_atoms_total as i64,
                            vd.buy_sim, vd.sell_sim,
                            thought_pred_str, td.buy_coverage, td.sell_coverage,
                            td.buy_atoms_found as i64, td.buy_atoms_total as i64,
                            td.sell_atoms_found as i64, td.sell_atoms_total as i64,
                            td.buy_sim, td.sell_sim,
                            agree.map(|a| a as i32), &actual_str, action_str, trader.equity,
                            entry.learn_count as i64, entry.peak_pct,
                        ],
                    ).ok();
                    log_step += 1;
                    db_batch_count += 1;
                    if db_batch_count >= 5000 {
                        run_db.execute_batch("COMMIT; BEGIN").ok();
                        db_batch_count = 0;
                    }

                    trader.tick_observe();
                } else {
                    break;
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
                let agree_acc = if agree_rolling.is_empty() {
                    0.0
                } else {
                    agree_rolling.iter().filter(|&&x| x).count() as f64 / agree_rolling.len() as f64 * 100.0
                };
                eprintln!(
                    "    {}/{} ({:.0}/s, ETA {:.0}s) | {} | {} | vis={:.1}% thought={:.1}% agree={:.0}%({:.1}%) | trades={} win={:.1}% | eq=${:.0} ({:+.1}%) vs bnh {:+.1}%",
                    encode_count, loop_count, rate, eta,
                    latest_ts,
                    trader.phase,
                    j_roll_acc, tj_roll_acc, agree_pct, agree_acc,
                    trader.trades_taken, trader.win_rate(),
                    trader.equity, trader_return, bnh_return,
                );

                // Disc atom diagnostics
                {
                    let vb_n = journaler.disc_buy_atoms.len();
                    let vs_n = journaler.disc_sell_atoms.len();
                    let vb_tw: f64 = journaler.disc_buy_atoms.iter().map(|a| a.weight).sum();
                    let vs_tw: f64 = journaler.disc_sell_atoms.iter().map(|a| a.weight).sum();
                    let tb_n = thought_journaler.disc_buy_atoms.len();
                    let ts_n = thought_journaler.disc_sell_atoms.len();
                    let tb_tw: f64 = thought_journaler.disc_buy_atoms.iter().map(|a| a.weight).sum();
                    let ts_tw: f64 = thought_journaler.disc_sell_atoms.iter().map(|a| a.weight).sum();
                    eprintln!("    disc atoms: vis(buy={} w={:.2}, sell={} w={:.2}) tht(buy={} w={:.2}, sell={} w={:.2})",
                        vb_n, vb_tw, vs_n, vs_tw, tb_n, tb_tw, ts_n, ts_tw);
                    let v_total = journaler.proj_used + journaler.proj_skipped;
                    let t_total = thought_journaler.proj_used + thought_journaler.proj_skipped;
                    eprintln!("    disc proj: vis={}/{} ({:.0}%) tht={}/{} ({:.0}%) | proj_atoms: vis={} tht={}",
                        journaler.proj_used, v_total,
                        if v_total > 0 { journaler.proj_used as f64 / v_total as f64 * 100.0 } else { 0.0 },
                        thought_journaler.proj_used, t_total,
                        if t_total > 0 { thought_journaler.proj_used as f64 / t_total as f64 * 100.0 } else { 0.0 },
                        journaler.disc_proj_atoms.len(), thought_journaler.disc_proj_atoms.len());
                }

                // Prototype convergence diagnostics
                if journaler.is_ready() {
                    let vb = journaler.buy_good.normalize_f64();
                    let vs = journaler.sell_good.normalize_f64();
                    let v_cos = cosine_f64(&vb, &vs);
                    let tb = thought_journaler.buy_good.normalize_f64();
                    let ts = thought_journaler.sell_good.normalize_f64();
                    let t_cos = cosine_f64(&tb, &ts);
                    eprintln!("    proto: vis(cos={:.4}) tht(cos={:.4})", v_cos, t_cos);
                }

                // Snapshot recalib state to DB
                if journaler.is_ready() {
                    let bp = journaler.buy_good.normalize_f64();
                    let sp = journaler.sell_good.normalize_f64();
                    let vis_buy_tw: f64 = journaler.disc_buy_atoms.iter().map(|a| a.weight).sum();
                    let vis_sell_tw: f64 = journaler.disc_sell_atoms.iter().map(|a| a.weight).sum();
                    run_db.execute(
                        "INSERT INTO recalib_log (step, system, cos_buy_sell, noise_floor, buy_count, sell_count, buy_purity, sell_purity, disc_buy_atoms, disc_sell_atoms, disc_buy_total_weight, disc_sell_total_weight, proj_used, proj_skipped, proj_atoms)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
                        params![
                            encode_count as i64, "visual",
                            cosine_f64(&bp, &sp),
                            journaler.noise_floor,
                            journaler.buy_good.count() as i64,
                            journaler.sell_good.count() as i64,
                            journaler.buy_good.purity(),
                            journaler.sell_good.purity(),
                            journaler.disc_buy_atoms.len() as i64,
                            journaler.disc_sell_atoms.len() as i64,
                            vis_buy_tw, vis_sell_tw,
                            journaler.proj_used as i64,
                            journaler.proj_skipped as i64,
                            journaler.disc_proj_atoms.len() as i64,
                        ],
                    ).ok();
                }
                if thought_journaler.is_ready() {
                    let bp = thought_journaler.buy_good.normalize_f64();
                    let sp = thought_journaler.sell_good.normalize_f64();
                    let tht_buy_tw: f64 = thought_journaler.disc_buy_atoms.iter().map(|a| a.weight).sum();
                    let tht_sell_tw: f64 = thought_journaler.disc_sell_atoms.iter().map(|a| a.weight).sum();
                    run_db.execute(
                        "INSERT INTO recalib_log (step, system, cos_buy_sell, noise_floor, buy_count, sell_count, buy_purity, sell_purity, disc_buy_atoms, disc_sell_atoms, disc_buy_total_weight, disc_sell_total_weight, proj_used, proj_skipped, proj_atoms)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
                        params![
                            encode_count as i64, "thought",
                            cosine_f64(&bp, &sp),
                            thought_journaler.noise_floor,
                            thought_journaler.buy_good.count() as i64,
                            thought_journaler.sell_good.count() as i64,
                            thought_journaler.buy_good.purity(),
                            thought_journaler.sell_good.purity(),
                            thought_journaler.disc_buy_atoms.len() as i64,
                            thought_journaler.disc_sell_atoms.len() as i64,
                            tht_buy_tw, tht_sell_tw,
                            thought_journaler.proj_used as i64,
                            thought_journaler.proj_skipped as i64,
                            thought_journaler.disc_proj_atoms.len() as i64,
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

    // Drain remaining pending entries (log only, no further learning)
    while let Some(entry) = pending.pop_front() {
        let entry_candle = &candles[entry.candle_idx];
        let final_outcome = entry.first_outcome.unwrap_or(Outcome::Noise);

        match final_outcome {
            Outcome::Noise => noise_count += 1,
            _ => labeled_count += 1,
        }

        if let Some(pred) = entry.journaler_prediction {
            if final_outcome != Outcome::Noise {
                let is_correct = pred == final_outcome;
                j_total += 1;
                if is_correct { j_correct += 1; }
                j_rolling.push_back(is_correct);
                if j_rolling.len() > j_rolling_cap { j_rolling.pop_front(); }
                let ye = j_by_year.entry(entry_candle.year).or_insert((0, 0));
                ye.1 += 1;
                if is_correct { ye.0 += 1; }
            }
        }

        if let Some(t_pred) = entry.thought_prediction {
            if final_outcome != Outcome::Noise {
                let t_is_correct = (t_pred == thought::Outcome::Buy && final_outcome == Outcome::Buy)
                    || (t_pred == thought::Outcome::Sell && final_outcome == Outcome::Sell);
                tj_total += 1;
                if t_is_correct { tj_correct += 1; }
                tj_rolling.push_back(t_is_correct);
                if tj_rolling.len() > j_rolling_cap { tj_rolling.pop_front(); }
            }
        }

        let vd = &entry.vis_detail;
        let td = &entry.thought_detail;
        let vis_pred_str = entry.journaler_prediction.map(|p| format!("{:?}", p));
        let thought_pred_str = entry.thought_prediction.map(|p| format!("{:?}", p));
        let agree = match (entry.journaler_prediction, entry.thought_prediction) {
            (Some(vp), Some(tp)) => Some((vp == Outcome::Buy) == (tp == thought::Outcome::Buy)),
            _ => None,
        };
        let action_str = entry.trade_action.as_ref().map(|a| format!("{:?}", a.direction));
        let actual_str = format!("{:?}", final_outcome);
        run_db.execute(
            "INSERT INTO candle_log (step, candle_idx, timestamp,
                vis_pred, vis_buy_coverage, vis_sell_coverage,
                vis_buy_atoms_found, vis_buy_atoms_total,
                vis_sell_atoms_found, vis_sell_atoms_total,
                vis_buy_sim, vis_sell_sim,
                thought_pred, thought_buy_coverage, thought_sell_coverage,
                thought_buy_atoms_found, thought_buy_atoms_total,
                thought_sell_atoms_found, thought_sell_atoms_total,
                thought_buy_sim, thought_sell_sim,
                agree, actual, action, equity, learn_count, peak_pct)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27)",
            params![
                log_step, entry.candle_idx as i64, &entry_candle.ts,
                vis_pred_str, vd.buy_coverage, vd.sell_coverage,
                vd.buy_atoms_found as i64, vd.buy_atoms_total as i64,
                vd.sell_atoms_found as i64, vd.sell_atoms_total as i64,
                vd.buy_sim, vd.sell_sim,
                thought_pred_str, td.buy_coverage, td.sell_coverage,
                td.buy_atoms_found as i64, td.buy_atoms_total as i64,
                td.sell_atoms_found as i64, td.sell_atoms_total as i64,
                td.buy_sim, td.sell_sim,
                agree.map(|a| a as i32), &actual_str, action_str, trader.equity,
                entry.learn_count as i64, entry.peak_pct,
            ],
        ).ok();
        log_step += 1;
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
    eprintln!("    buy_good:      count={}, purity={:.4}",
        journaler.buy_good.count(), journaler.buy_good.purity());
    eprintln!("    sell_good:     count={}, purity={:.4}",
        journaler.sell_good.count(), journaler.sell_good.purity());

    if journaler.is_ready() {
        let buy_f64 = journaler.buy_good.normalize_f64();
        let sell_f64 = journaler.sell_good.normalize_f64();
        eprintln!("    cos(buy_good, sell_good) = {:.4}", cosine_f64(&buy_f64, &sell_f64));
        let vb_tw: f64 = journaler.disc_buy_atoms.iter().map(|a| a.weight).sum();
        let vs_tw: f64 = journaler.disc_sell_atoms.iter().map(|a| a.weight).sum();
        eprintln!("    disc atoms: buy={} (w={:.2}), sell={} (w={:.2})",
            journaler.disc_buy_atoms.len(), vb_tw,
            journaler.disc_sell_atoms.len(), vs_tw);
        let v_total = journaler.proj_used + journaler.proj_skipped;
        eprintln!("    disc proj: {}/{} ({:.0}%) | proj_atoms={}",
            journaler.proj_used, v_total,
            if v_total > 0 { journaler.proj_used as f64 / v_total as f64 * 100.0 } else { 0.0 },
            journaler.disc_proj_atoms.len());
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
    eprintln!("    buy_good:      count={}, purity={:.4}",
        thought_journaler.buy_good.count(), thought_journaler.buy_good.purity());
    eprintln!("    sell_good:     count={}, purity={:.4}",
        thought_journaler.sell_good.count(), thought_journaler.sell_good.purity());

    if thought_journaler.is_ready() {
        let t_buy_f64 = thought_journaler.buy_good.normalize_f64();
        let t_sell_f64 = thought_journaler.sell_good.normalize_f64();
        eprintln!("    cos(buy_good, sell_good) = {:.4}", cosine_f64(&t_buy_f64, &t_sell_f64));
        let tb_tw: f64 = thought_journaler.disc_buy_atoms.iter().map(|a| a.weight).sum();
        let ts_tw: f64 = thought_journaler.disc_sell_atoms.iter().map(|a| a.weight).sum();
        eprintln!("    disc atoms: buy={} (w={:.2}), sell={} (w={:.2})",
            thought_journaler.disc_buy_atoms.len(), tb_tw,
            thought_journaler.disc_sell_atoms.len(), ts_tw);
        let t_total = thought_journaler.proj_used + thought_journaler.proj_skipped;
        eprintln!("    disc proj: {}/{} ({:.0}%) | proj_atoms={}",
            thought_journaler.proj_used, t_total,
            if t_total > 0 { thought_journaler.proj_used as f64 / t_total as f64 * 100.0 } else { 0.0 },
            thought_journaler.disc_proj_atoms.len());

        if args.debug_thoughts {
            let t_buy = thought_journaler.buy_good.threshold();
            let t_sell = thought_journaler.sell_good.threshold();
            eprintln!("\n  Thought buy prototype top facts:");
            for (label, sim) in fact_codebook.decode(&t_buy, 5, 0.05) {
                eprintln!("    {:.3}  {}", sim, label);
            }
            eprintln!("  Thought sell prototype top facts:");
            for (label, sim) in fact_codebook.decode(&t_sell, 5, 0.05) {
                eprintln!("    {:.3}  {}", sim, label);
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
