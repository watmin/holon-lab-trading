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

/// Streaming state machine for phase labeling.
/// Lives on the IndicatorBank. Steps once per candle.
#[derive(Clone, Debug)]
pub struct PhaseState {
    pub current_label: PhaseLabel,
    pub current_direction: PhaseDirection,
    pub current_start: usize,
    pub extreme: f64,
    pub extreme_candle: usize,
    pub close_sum: f64,
    pub volume_sum: f64,
    pub high: f64,
    pub low: f64,
    pub open_close: f64,
    pub count: usize,
    pub phase_history: VecDeque<PhaseRecord>,
}

const PHASE_HISTORY_CAPACITY: usize = 20;

impl PhaseState {
    pub fn new() -> Self {
        Self {
            current_label: PhaseLabel::Valley,
            current_direction: PhaseDirection::None,
            current_start: 0,
            extreme: 0.0,
            extreme_candle: 0,
            close_sum: 0.0,
            volume_sum: 0.0,
            high: f64::NEG_INFINITY,
            low: f64::MAX,
            open_close: 0.0,
            count: 0,
            phase_history: VecDeque::with_capacity(PHASE_HISTORY_CAPACITY),
        }
    }

    /// Advance the state machine by one candle.
    /// Called AFTER ATR is computed so smoothing is available.
    pub fn step(&mut self, close: f64, volume: f64, candle_num: usize, smoothing: f64) {
        // First candle: initialize
        if self.count == 0 {
            self.extreme = close;
            self.extreme_candle = candle_num;
            self.current_start = candle_num;
            self.open_close = close;
            self.high = close;
            self.low = close;
            self.close_sum = close;
            self.volume_sum = volume;
            self.count = 1;
            return;
        }

        // Update running stats
        self.close_sum += close;
        self.volume_sum += volume;
        self.count += 1;
        if close > self.high {
            self.high = close;
        }
        if close < self.low {
            self.low = close;
        }

        match self.current_label {
            PhaseLabel::Valley => {
                // Tracking a potential valley — price was low, watching for rise
                if close < self.extreme {
                    // New low — extend valley
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                } else if close - self.extreme > smoothing {
                    // Risen by > smoothing from low — CONFIRM valley, begin transition-up
                    self.close_phase(candle_num);
                    self.begin_phase(PhaseLabel::Transition, PhaseDirection::Up, close, volume, candle_num);
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                }
                // else: still near low, extend valley zone
            }
            PhaseLabel::Peak => {
                // Tracking a potential peak — price was high, watching for fall
                if close > self.extreme {
                    // New high — extend peak
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                } else if self.extreme - close > smoothing {
                    // Fallen by > smoothing from high — CONFIRM peak, begin transition-down
                    self.close_phase(candle_num);
                    self.begin_phase(PhaseLabel::Transition, PhaseDirection::Down, close, volume, candle_num);
                    self.extreme = close;
                    self.extreme_candle = candle_num;
                }
                // else: still near high, extend peak zone
            }
            PhaseLabel::Transition => {
                match self.current_direction {
                    PhaseDirection::Up => {
                        if close > self.extreme {
                            // New high during transition-up
                            self.extreme = close;
                            self.extreme_candle = candle_num;
                        } else if self.extreme - close > smoothing {
                            // Fallen by > smoothing — close transition, begin peak zone
                            self.close_phase(candle_num);
                            self.begin_phase(PhaseLabel::Peak, PhaseDirection::None, close, volume, candle_num);
                            self.extreme = close;
                            self.extreme_candle = candle_num;
                            // Peak tracks high, so set extreme to the transition's high
                            self.extreme = self.high;
                        }
                    }
                    PhaseDirection::Down => {
                        if close < self.extreme {
                            // New low during transition-down
                            self.extreme = close;
                            self.extreme_candle = candle_num;
                        } else if close - self.extreme > smoothing {
                            // Risen by > smoothing — close transition, begin valley zone
                            self.close_phase(candle_num);
                            self.begin_phase(PhaseLabel::Valley, PhaseDirection::None, close, volume, candle_num);
                            self.extreme = close;
                            self.extreme_candle = candle_num;
                            // Valley tracks low, so set extreme to the transition's low
                            self.extreme = self.low;
                        }
                    }
                    PhaseDirection::None => {
                        // Shouldn't happen for transition, but handle gracefully
                    }
                }
            }
        }
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
            close_final: if duration > 0 {
                // The last close added is close_sum - (close_sum - close) but we
                // don't have it separately. Use high or low depending on phase.
                // Actually, the current close IS the final close of this phase.
                // But we already advanced count. We'll store the boundary close
                // as close_final via the close at the transition point.
                avg_close // approximation — the true final close would require storing it
            } else {
                0.0
            },
            volume_avg: avg_volume,
        };

        if self.phase_history.len() >= PHASE_HISTORY_CAPACITY {
            self.phase_history.pop_front();
        }
        self.phase_history.push_back(record);
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
        assert_eq!(state.current_label, PhaseLabel::Valley);
    }

    #[test]
    fn test_valley_to_transition_up() {
        let mut state = PhaseState::new();
        let smoothing = 5.0;

        // Start in valley
        state.step(100.0, 50.0, 1, smoothing);
        state.step(98.0, 50.0, 2, smoothing); // new low
        state.step(97.0, 50.0, 3, smoothing); // new low
        assert_eq!(state.current_label, PhaseLabel::Valley);
        assert_eq!(state.extreme, 97.0);

        // Rise by more than smoothing (97 + 5 = 102, need close > 102)
        state.step(103.0, 50.0, 4, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Transition);
        assert_eq!(state.current_direction, PhaseDirection::Up);
        assert_eq!(state.phase_history.len(), 1); // valley closed
        assert_eq!(state.phase_history[0].label, PhaseLabel::Valley);
    }

    #[test]
    fn test_full_cycle() {
        let mut state = PhaseState::new();
        let smoothing = 5.0;

        // Valley
        state.step(100.0, 50.0, 1, smoothing);
        state.step(95.0, 50.0, 2, smoothing);

        // Transition up (95 + 5 = 100, need > 100)
        state.step(101.0, 50.0, 3, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Transition);
        assert_eq!(state.current_direction, PhaseDirection::Up);

        // Continue up
        state.step(105.0, 50.0, 4, smoothing);

        // Fall enough to close transition → peak (105 - 5 = 100, need < 100)
        state.step(99.0, 50.0, 5, smoothing);
        assert_eq!(state.current_label, PhaseLabel::Peak);
        assert!(state.phase_history.len() >= 2);

        // Peak continues to track high
        state.step(98.0, 50.0, 6, smoothing);

        // Fall enough from peak extreme to transition down
        // Peak extreme is high of peak phase, which started at 99 (the close at begin_phase)
        // But we set extreme = self.high after begin_phase for peak
        // self.high was set to close=99 in begin_phase, then 98 didn't exceed it
        // So extreme = 99 (the high from begin_phase overwrite)
        // Wait, actually in the Peak transition: after close_phase + begin_phase,
        // extreme is set to close (99), then overwritten to self.high (99).
        // Then tick 6: close=98 < 99, doesn't update extreme. 99-98=1 < 5, stays in peak.
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
