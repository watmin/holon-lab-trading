/// Phase types — streaming state machine for phase labeling.
/// Proposal 049: replaces pivot tracker (proposals 045/047/048).
///
/// Labels every candle as valley, peak, or transition based on
/// price movement relative to ATR smoothing.

use std::collections::VecDeque;

/// What phase the market is in at this candle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhaseLabel {
    Valley,
    Peak,
    Transition,
}

impl std::fmt::Display for PhaseLabel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PhaseLabel::Valley => write!(f, "valley"),
            PhaseLabel::Peak => write!(f, "peak"),
            PhaseLabel::Transition => write!(f, "transition"),
        }
    }
}

/// Direction of movement within a phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhaseDirection {
    Up,
    Down,
    None,
}

impl std::fmt::Display for PhaseDirection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PhaseDirection::Up => write!(f, "up"),
            PhaseDirection::Down => write!(f, "down"),
            PhaseDirection::None => write!(f, "none"),
        }
    }
}

/// A completed phase — pushed to history when a phase closes.
#[derive(Clone, Debug)]
pub struct PhaseRecord {
    pub label: PhaseLabel,
    pub direction: PhaseDirection,
    pub start_candle: usize,
    pub end_candle: usize,
    pub duration: usize,
    pub close_min: f64,
    pub close_max: f64,
    pub close_avg: f64,
    pub close_open: f64,
    pub close_final: f64,
    pub volume_avg: f64,
}

/// Internal tracking state — what the machine is currently measuring.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TrackingState {
    Rising,  // tracking the running high
    Falling, // tracking the running low
}

/// Streaming state machine for phase labeling.
/// Lives on the IndicatorBank. Steps once per candle.
#[derive(Clone, Debug)]
pub struct PhaseState {
    tracking: TrackingState,
    pub current_label: PhaseLabel,
    pub current_direction: PhaseDirection,
    extreme: f64,              // the running high (Rising) or low (Falling)
    extreme_candle: usize,
    // Current phase accumulation (for PhaseRecords when phase changes)
    current_phase_label: PhaseLabel, // the label at the START of this phase
    pub current_start: usize,
    pub close_sum: f64,
    pub volume_sum: f64,
    pub high: f64,
    pub low: f64,
    pub open_close: f64,
    pub last_close: f64,
    pub count: usize,
    pub phase_history: VecDeque<PhaseRecord>,
    /// Generation counter — incremented on every close_phase.
    pub generation: u64,
}

const PHASE_HISTORY_CAPACITY: usize = 20;

impl PhaseState {
    pub fn new() -> Self {
        Self {
            tracking: TrackingState::Falling,
            current_label: PhaseLabel::Valley,
            current_direction: PhaseDirection::None,
            extreme: 0.0,
            extreme_candle: 0,
            current_phase_label: PhaseLabel::Valley,
            current_start: 0,
            close_sum: 0.0,
            volume_sum: 0.0,
            high: f64::NEG_INFINITY,
            low: f64::MAX,
            open_close: 0.0,
            last_close: 0.0,
            count: 0,
            phase_history: VecDeque::with_capacity(PHASE_HISTORY_CAPACITY),
            generation: 0,
        }
    }

    /// Advance the state machine by one candle.
    /// Called AFTER ATR is computed so smoothing is available.
    ///
    /// Two tracking states (Rising/Falling), three labels derived from position:
    /// - Peak: Rising and close is near the tracked high
    /// - Valley: Falling and close is near the tracked low
    /// - Transition: moving between extremes
    pub fn step(&mut self, close: f64, volume: f64, candle_num: usize, smoothing: f64) {
        // First candle: initialize
        if self.count == 0 {
            self.tracking = TrackingState::Falling;
            self.extreme = close;
            self.extreme_candle = candle_num;
            self.current_start = candle_num;
            self.open_close = close;
            self.high = close;
            self.low = close;
            self.close_sum = close;
            self.volume_sum = volume;
            self.last_close = close;
            self.count = 1;
            self.current_label = PhaseLabel::Valley;
            self.current_direction = PhaseDirection::None;
            self.current_phase_label = PhaseLabel::Valley;
            return;
        }

        // Update running stats
        self.close_sum += close;
        self.volume_sum += volume;
        self.last_close = close;
        self.count += 1;
        if close > self.high {
            self.high = close;
        }
        if close < self.low {
            self.low = close;
        }

        // Check for state transition
        match self.tracking {
            TrackingState::Rising => {
                if close > self.extreme {
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                }
                if self.extreme - close > smoothing {
                    // Price fell from the high — switch to Falling
                    self.tracking = TrackingState::Falling;
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                }
            }
            TrackingState::Falling => {
                if close < self.extreme {
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                }
                if close - self.extreme > smoothing {
                    // Price rose from the low — switch to Rising
                    self.tracking = TrackingState::Rising;
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                }
            }
        }

        // Derive label from state + position
        let half_smooth = smoothing / 2.0;
        let (new_label, new_direction) = match self.tracking {
            TrackingState::Rising => {
                if close >= self.extreme - half_smooth {
                    (PhaseLabel::Peak, PhaseDirection::None)
                } else {
                    (PhaseLabel::Transition, PhaseDirection::Up)
                }
            }
            TrackingState::Falling => {
                if close <= self.extreme + half_smooth {
                    (PhaseLabel::Valley, PhaseDirection::None)
                } else {
                    (PhaseLabel::Transition, PhaseDirection::Down)
                }
            }
        };

        // If label changed, close the old phase and start a new one
        if new_label != self.current_phase_label {
            self.close_phase(candle_num);
            self.begin_phase(new_label, new_direction, close, volume, candle_num);
            self.current_phase_label = new_label;
        }

        self.current_label = new_label;
        self.current_direction = new_direction;
    }

    /// Close the current phase into a PhaseRecord and push to history.
    fn close_phase(&mut self, end_candle: usize) {
        let duration = self.count;
        let avg_close = if duration > 0 {
            self.close_sum / duration as f64
        } else {
            0.0
        };
        let avg_volume = if duration > 0 {
            self.volume_sum / duration as f64
        } else {
            0.0
        };
        let record = PhaseRecord {
            label: self.current_label,
            direction: self.current_direction,
            start_candle: self.current_start,
            end_candle,
            duration,
            close_min: self.low,
            close_max: self.high,
            close_avg: avg_close,
            close_open: self.open_close,
            close_final: self.last_close,
            volume_avg: avg_volume,
        };

        if self.phase_history.len() >= PHASE_HISTORY_CAPACITY {
            self.phase_history.pop_front();
        }
        self.phase_history.push_back(record);
        self.generation += 1;
    }

    /// Begin a new phase.
    fn begin_phase(
        &mut self,
        label: PhaseLabel,
        direction: PhaseDirection,
        close: f64,
        volume: f64,
        candle_num: usize,
    ) {
        self.current_label = label;
        self.current_direction = direction;
        self.current_start = candle_num;
        self.close_sum = close;
        self.volume_sum = volume;
        self.high = close;
        self.low = close;
        self.open_close = close;
        self.last_close = close;
        self.count = 1;
    }

    /// How long the current phase has been running.
    pub fn current_duration(&self) -> usize {
        self.count
    }

    /// Clone the recent history as a Vec (bounded).
    pub fn history_snapshot(&self) -> Vec<PhaseRecord> {
        self.phase_history.iter().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_phase_state_new() {
        let state = PhaseState::new();
        assert_eq!(state.current_label, PhaseLabel::Valley);
        assert_eq!(state.count, 0);
        assert!(state.phase_history.is_empty());
    }

    #[test]
    fn test_phase_label_display() {
        assert_eq!(PhaseLabel::Valley.to_string(), "valley");
        assert_eq!(PhaseLabel::Peak.to_string(), "peak");
        assert_eq!(PhaseLabel::Transition.to_string(), "transition");
    }

    #[test]
    fn test_single_step() {
        let mut state = PhaseState::new();
        state.step(100.0, 50.0, 1, 5.0);
        assert_eq!(state.count, 1);
        // First candle: Falling state, close == extreme → Valley
        assert_eq!(state.current_label, PhaseLabel::Valley);
    }

    #[test]
    fn test_valley_to_transition_to_peak() {
        let mut state = PhaseState::new();
        let smoothing = 5.0;

        // Start in valley (Falling state, near low)
        state.step(100.0, 50.0, 1, smoothing);
        state.step(98.0, 50.0, 2, smoothing); // new low
        state.step(97.0, 50.0, 3, smoothing); // new low, extreme=97
        assert_eq!(state.current_label, PhaseLabel::Valley);
        assert_eq!(state.tracking, TrackingState::Falling);

        // Rise by more than smoothing (97 + 5 = 102, need close > 102)
        // This switches tracking to Rising, extreme=103
        // close=103, extreme=103, 103 >= 103 - 2.5 → Peak (near the new high)
        state.step(103.0, 50.0, 4, smoothing);
        assert_eq!(state.tracking, TrackingState::Rising);
        assert_eq!(state.current_label, PhaseLabel::Peak);
        assert_eq!(state.current_direction, PhaseDirection::None);
        // Valley phase was closed
        assert_eq!(state.phase_history.len(), 1);
        assert_eq!(state.phase_history[0].label, PhaseLabel::Valley);
    }

    #[test]
    fn test_full_cycle() {
        let mut state = PhaseState::new();
        let smoothing = 5.0;

        // Valley — Falling state, near low
        state.step(100.0, 50.0, 1, smoothing);
        state.step(95.0, 50.0, 2, smoothing); // extreme=95
        assert_eq!(state.current_label, PhaseLabel::Valley);

        // Rise past smoothing from low (95 + 5 = 100, need > 100)
        // Switches to Rising, extreme=101
        // close=101, extreme=101, 101 >= 101-2.5 → Peak
        state.step(101.0, 50.0, 3, smoothing);
        assert_eq!(state.tracking, TrackingState::Rising);
        assert_eq!(state.current_label, PhaseLabel::Peak);

        // Continue up — still Peak, extreme tracks higher
        state.step(105.0, 50.0, 4, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Peak);

        // Price eases slightly — still near extreme (105 - 2.5 = 102.5)
        state.step(103.0, 50.0, 5, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Peak); // 103 >= 105 - 2.5

        // Price drops further — no longer near extreme but not past smoothing
        // 100 < 105 - 2.5 = 102.5 → Transition-up
        // But 105 - 100 = 5, not > 5, so still Rising
        state.step(100.0, 50.0, 6, smoothing);
        assert_eq!(state.tracking, TrackingState::Rising);
        assert_eq!(state.current_label, PhaseLabel::Transition);
        assert_eq!(state.current_direction, PhaseDirection::Up);

        // Price drops past smoothing from extreme (105 - 99 = 6 > 5)
        // Switches to Falling, extreme=99
        // close=99, extreme=99, 99 <= 99 + 2.5 → Valley
        state.step(99.0, 50.0, 7, smoothing);
        assert_eq!(state.tracking, TrackingState::Falling);
        assert_eq!(state.current_label, PhaseLabel::Valley);
    }

    #[test]
    fn test_peak_at_high_valley_at_low() {
        // The core correctness property: peaks are near highs, valleys near lows.
        let mut state = PhaseState::new();
        let smoothing = 10.0;

        // Start low
        state.step(100.0, 50.0, 1, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Valley);

        // Rise to 115 (100 + 10 = 110, 115 > 110 → switch to Rising)
        // extreme=115, close=115, 115 >= 115-5 → Peak at HIGH price
        state.step(115.0, 50.0, 2, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Peak);

        // Stay near the high — still Peak
        state.step(112.0, 50.0, 3, smoothing); // 112 >= 115-5=110 → Peak
        assert_eq!(state.current_label, PhaseLabel::Peak);

        // Drop below half_smooth from extreme but not past smoothing
        state.step(108.0, 50.0, 4, smoothing); // 108 < 115-5=110 → Transition-up
        assert_eq!(state.current_label, PhaseLabel::Transition);

        // Drop past smoothing from extreme (115 - 104 = 11 > 10)
        // Switch to Falling, extreme=104
        // close=104, extreme=104, 104 <= 104+5 → Valley at LOW price
        state.step(104.0, 50.0, 5, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Valley);
        assert_eq!(state.tracking, TrackingState::Falling);

        // Verify: Peak was labeled at 115 and 112 (HIGH prices)
        // Valley is labeled at 104 (LOW price relative to the move)
        // This is the correct behavior — peaks at highs, valleys at lows.
    }

    #[test]
    fn test_history_bounded() {
        let mut state = PhaseState::new();
        let smoothing = 1.0;

        // Force many transitions by oscillating
        for i in 0..100 {
            let close = if i % 4 < 2 { 100.0 + (i as f64) * 0.01 } else { 90.0 };
            state.step(close, 50.0, i, smoothing);
        }

        assert!(state.phase_history.len() <= PHASE_HISTORY_CAPACITY);
    }
}
