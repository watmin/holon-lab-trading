/// Pivot types — detection mechanics for the pivot tracker program.
/// Compiled from proposals 045 (mechanics), 047 (program), 048 (handles).

use crate::types::enums::Direction;

/// What the market observer sends to the pivot tracker on every candle.
#[derive(Clone, Debug)]
pub struct PivotObservation {
    pub market_idx: usize,
    pub conviction: f64,
    pub direction: Direction,
    pub candle_num: usize,
    pub close: f64,
    pub volume: f64,
}

/// Is this a high-conviction pivot or a low-conviction gap?
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeriodKind {
    Pivot,
    Gap,
}

impl std::fmt::Display for PeriodKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PeriodKind::Pivot => write!(f, "pivot"),
            PeriodKind::Gap => write!(f, "gap"),
        }
    }
}

/// The period currently being tracked (open, not yet closed).
#[derive(Clone, Debug)]
pub struct CurrentPeriod {
    pub kind: PeriodKind,
    pub direction: Option<Direction>,
    pub start_candle: usize,
    pub last_candle: usize,
    pub close_sum: f64,
    pub volume_sum: f64,
    pub high: f64,
    pub low: f64,
    pub conviction_sum: f64,
    pub count: usize,
    pub below_count: usize,
}

impl CurrentPeriod {
    /// Start a new period from an observation.
    pub fn new(kind: PeriodKind, direction: Option<Direction>, obs: &PivotObservation) -> Self {
        Self {
            kind,
            direction,
            start_candle: obs.candle_num,
            last_candle: obs.candle_num,
            close_sum: obs.close,
            volume_sum: obs.volume,
            high: obs.close,
            low: obs.close,
            conviction_sum: obs.conviction,
            count: 1,
            below_count: 0,
        }
    }

    /// Extend the current period with a new observation.
    pub fn extend(&mut self, obs: &PivotObservation) {
        self.last_candle = obs.candle_num;
        self.close_sum += obs.close;
        self.volume_sum += obs.volume;
        if obs.close > self.high { self.high = obs.close; }
        if obs.close < self.low { self.low = obs.close; }
        self.conviction_sum += obs.conviction;
        self.count += 1;
    }

    /// Convert to a closed PivotRecord.
    pub fn to_record(&self) -> PivotRecord {
        let count = self.count.max(1) as f64;
        PivotRecord {
            kind: self.kind,
            direction: self.direction,
            candle_start: self.start_candle,
            candle_end: self.last_candle,
            duration: self.count,
            close_avg: self.close_sum / count,
            volume_avg: self.volume_sum / count,
            high: self.high,
            low: self.low,
            conviction_avg: self.conviction_sum / count,
        }
    }
}

/// A completed period — either a pivot or a gap.
#[derive(Clone, Debug)]
pub struct PivotRecord {
    pub kind: PeriodKind,
    pub direction: Option<Direction>,
    pub candle_start: usize,
    pub candle_end: usize,
    pub duration: usize,
    pub close_avg: f64,
    pub volume_avg: f64,
    pub high: f64,
    pub low: f64,
    pub conviction_avg: f64,
}

/// A snapshot of the tracker state — returned to exit observers on query.
#[derive(Clone, Debug)]
pub struct PivotSnapshot {
    pub records: Vec<PivotRecord>,
    pub current_period: CurrentPeriod,
}
