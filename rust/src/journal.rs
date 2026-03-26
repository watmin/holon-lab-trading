use holon::{Accumulator, Vector};

// ─── Outcome ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    Buy,
    Sell,
    Noise,
}

impl std::fmt::Display for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Outcome::Buy   => write!(f, "Buy"),
            Outcome::Sell  => write!(f, "Sell"),
            Outcome::Noise => write!(f, "Noise"),
        }
    }
}

// ─── Prediction ─────────────────────────────────────────────────────────────

/// The result of asking a Journal what it thinks will happen next.
///
/// `raw_cos` is the signed cosine of the input against the discriminant:
///   - positive → Buy signal
///   - negative → Sell signal
///   - magnitude → how confidently (use as trade gate threshold)
#[derive(Clone, Default)]
pub struct Prediction {
    pub raw_cos:    f64,
    pub conviction: f64,           // |raw_cos|
    pub direction:  Option<Outcome>, // None until a discriminant has been trained
}

// ─── Journal ────────────────────────────────────────────────────────────────

/// A named learning agent for one encoding modality.
///
/// ## How it works
///
/// Two accumulators collect evidence: `buy` for candles that preceded upward
/// price moves, `sell` for downward moves. Periodically the journal computes a
/// *discriminant* — the normalized vector pointing from the sell centroid to the
/// buy centroid. This is the direction in vector space that most separates the
/// two classes.
///
/// Prediction is one cosine against the discriminant:
///   cos > 0 → predict Buy, cos < 0 → predict Sell, |cos| = conviction.
///
/// The same struct handles both the visual raster encoding and the thought
/// narrative encoding — the encoding modality is external to the journal.
pub struct Journal {
    pub name: &'static str,
    pub buy:  Accumulator,
    pub sell: Accumulator,
    dims: usize,
    updates: usize,
    recalib_interval: usize,
    /// Normalized discriminant in float space. None until first recalibration.
    discriminant: Option<Vec<f64>>,
    /// Mean of buy/sell prototypes at last recalibration. Subtracted from input
    /// at prediction time to strip shared structure before the cosine comparison.
    mean_proto: Option<Vec<f64>>,

    // Diagnostics — updated at each recalibration, read by main for DB logging.
    pub last_cos_raw:       f64,  // cos(buy_proto, sell_proto) — how blurred are the classes?
    pub last_disc_strength: f64,  // norm(buy−sell)/sqrt(D) — available separating signal (0..1)
    pub recalib_count:      usize,
}

impl Journal {
    pub fn new(name: &'static str, dims: usize, recalib_interval: usize) -> Self {
        Self {
            name,
            buy:  Accumulator::new(dims),
            sell: Accumulator::new(dims),
            dims,
            updates: 0,
            recalib_interval,
            discriminant:       None,
            mean_proto:         None,
            last_cos_raw:       0.0,
            last_disc_strength: 0.0,
            recalib_count:      0,
        }
    }

    /// True once a discriminant has been trained (first recalibration happened).
    pub fn is_ready(&self) -> bool {
        self.discriminant.is_some()
    }

    /// Record a price outcome for a previously encoded candle.
    ///
    /// `weight` scales observation strength — use a value proportional to the
    /// magnitude of the price move so larger moves teach more strongly.
    ///
    /// Recalibrates (recomputes the discriminant) every `recalib_interval` calls.
    /// Score-first: the discriminant is updated from the existing state *before*
    /// the new observation is incorporated.
    pub fn observe(&mut self, vec: &Vector, outcome: Outcome, weight: f64) {
        if outcome == Outcome::Noise { return; }
        self.updates += 1;
        if self.updates % self.recalib_interval == 0 {
            self.recalibrate();
        }
        match outcome {
            Outcome::Buy  => self.buy.add_weighted(vec, weight),
            Outcome::Sell => self.sell.add_weighted(vec, weight),
            Outcome::Noise => {}
        }
    }

    /// Decay both accumulators so old memories fade.
    /// Call once per candle regardless of whether an outcome was observed.
    pub fn decay(&mut self, factor: f64) {
        self.buy.decay(factor);
        self.sell.decay(factor);
    }

    /// Predict market direction for an encoded candle vector.
    ///
    /// If a mean prototype is available (post-recalibration), it is subtracted
    /// from the input in float space before the cosine is computed. This strips
    /// the shared candle structure (~90% of the encoding) that blurs the classes,
    /// leaving only the deviation that is informative for direction prediction.
    pub fn predict(&self, vec: &Vector) -> Prediction {
        let Some(disc) = &self.discriminant else {
            return Prediction::default();
        };
        let cos = if let Some(mean) = &self.mean_proto {
            // Convert input to float, subtract the shared mean, then compare.
            let stripped: Vec<f64> = vec.data().iter()
                .zip(mean.iter())
                .map(|(&v, &m)| v as f64 - m)
                .collect();
            cosine_f64(&stripped, disc)
        } else {
            cosine_proto_vs_vec(disc, vec)
        };
        Prediction {
            raw_cos:    cos,
            conviction: cos.abs(),
            direction:  Some(if cos > 0.0 { Outcome::Buy } else { Outcome::Sell }),
        }
    }

    fn recalibrate(&mut self) {
        if self.buy.count() == 0 || self.sell.count() == 0 { return; }

        let buy_f  = self.buy.normalize_f64();
        let sell_f = self.sell.normalize_f64();

        // Diagnostic: how similar are the raw class prototypes before discrimination?
        self.last_cos_raw = cosine_f64(&buy_f, &sell_f);

        // Cache mean prototype for input stripping at prediction time.
        self.mean_proto = Some(buy_f.iter().zip(sell_f.iter())
            .map(|(b, s)| (b + s) / 2.0)
            .collect());

        // Discriminant = normalized(buy_proto − sell_proto).
        //
        // This is the linear direction that maximally separates the two class
        // centroids in float space. A cosine of +1 against this vector means
        // "identical to the pure buy prototype"; -1 means "identical to pure sell".
        let disc: Vec<f64> = buy_f.iter().zip(sell_f.iter())
            .map(|(b, s)| b - s)
            .collect();

        let norm: f64 = disc.iter().map(|x| x * x).sum::<f64>().sqrt();

        // Strength: how much separating signal exists, relative to dimension count.
        // Near 0 = classes are nearly identical (bad). Near 1 = well separated (good).
        self.last_disc_strength = norm / (self.dims as f64).sqrt();

        if norm > 1e-10 {
            self.discriminant = Some(disc.into_iter().map(|x| x / norm).collect());
        }
        self.recalib_count += 1;
    }
}

// ─── Float-space cosine helpers ─────────────────────────────────────────────

/// Cosine similarity between two float vectors.
pub fn cosine_f64(a: &[f64], b: &[f64]) -> f64 {
    let mut dot = 0.0_f64;
    let mut na  = 0.0_f64;
    let mut nb  = 0.0_f64;
    for (&x, &y) in a.iter().zip(b.iter()) {
        dot += x * y;
        na  += x * x;
        nb  += y * y;
    }
    let denom = (na * nb).sqrt();
    if denom < 1e-10 { 0.0 } else { dot / denom }
}

/// Cosine between a float-space prototype (e.g., a discriminant) and a bipolar Vector.
fn cosine_proto_vs_vec(proto: &[f64], vec: &Vector) -> f64 {
    let data = vec.data();
    let mut dot = 0.0_f64;
    let mut np  = 0.0_f64;
    let mut nv  = 0.0_f64;
    for (&p, &v) in proto.iter().zip(data.iter()) {
        let vf = v as f64;
        dot += p * vf;
        np  += p * p;
        nv  += vf * vf;
    }
    let denom = (np * nv).sqrt();
    if denom < 1e-10 { 0.0 } else { dot / denom }
}
