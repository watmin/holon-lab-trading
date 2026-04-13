//! Pivot tracker — single-writer service that detects conviction pivots.
//! One thread. N writers (market observer observation queues). M readers
//! (exit observer query/reply channels). Drain writes before reads.
//! No contention. No Mutex. The cache pattern.
//!
//! Proposals 045, 047, 048.

use std::collections::VecDeque;
use std::thread;

use crate::services::queue::{self, QueueReceiver, QueueSender};
use crate::types::log_entry::LogEntry;
use crate::types::pivot::{
    CurrentPeriod, PeriodKind, PivotObservation, PivotRecord, PivotSnapshot,
};
use crate::types::rolling_percentile::RollingPercentile;

/// Per-caller handle to the pivot tracker. Each exit slot gets its own.
/// Not cloneable — one per exit slot. The pipe IS the identity.
pub struct PivotHandle {
    query_tx: QueueSender<()>,
    reply_rx: QueueReceiver<PivotSnapshot>,
}

impl PivotHandle {
    /// Query the tracker. Sends a unit signal, blocks on reply.
    /// Returns None if the tracker has shut down.
    pub fn query(&self) -> Option<PivotSnapshot> {
        self.query_tx.send(()).ok()?;
        self.reply_rx.recv().ok()
    }
}

/// Handle to the pivot tracker driver thread for lifecycle management.
/// Same pattern as CacheDriverHandle — no Drop impl.
pub struct PivotTrackerDriverHandle {
    #[allow(dead_code)]
    thread: Option<thread::JoinHandle<()>>,
}

impl PivotTrackerDriverHandle {
    /// Block until the driver thread exits.
    pub fn join(mut self) {
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

/// Internal state for one market observer's tracker.
struct TrackerState {
    conviction_history: RollingPercentile,
    current_period: CurrentPeriod,
    pivot_memory: VecDeque<PivotRecord>,
}

impl TrackerState {
    fn new() -> Self {
        // Start with a gap period — no observations yet.
        // Use a dummy initial period that will be replaced on first observation.
        Self {
            conviction_history: RollingPercentile::new(500),
            current_period: CurrentPeriod {
                kind: PeriodKind::Gap,
                direction: None,
                start_candle: 0,
                last_candle: 0,
                close_sum: 0.0,
                volume_sum: 0.0,
                high: 0.0,
                low: f64::MAX,
                conviction_sum: 0.0,
                count: 0,
                below_count: 0,
            },
            pivot_memory: VecDeque::with_capacity(20),
        }
    }

    /// Process one observation through the state machine.
    /// Returns Some(PivotRecord) if a period was closed (for telemetry).
    fn observe(&mut self, obs: &PivotObservation) -> Option<PivotRecord> {
        // Always push conviction into the rolling window
        self.conviction_history.push(obs.conviction);

        // Threshold: 80th percentile of rolling window
        let threshold = self.conviction_history.percentile(0.80);
        let above = obs.conviction > threshold;

        let mut closed_record = None;

        match self.current_period.kind {
            PeriodKind::Gap => {
                if above {
                    // Close gap, open pivot
                    if self.current_period.count > 0 {
                        closed_record = Some(self.close_current());
                    }
                    self.current_period = CurrentPeriod::new(
                        PeriodKind::Pivot,
                        Some(obs.direction),
                        obs,
                    );
                } else {
                    // Extend gap
                    if self.current_period.count == 0 {
                        // First observation ever — initialize the gap
                        self.current_period = CurrentPeriod::new(
                            PeriodKind::Gap,
                            None,
                            obs,
                        );
                    } else {
                        self.current_period.extend(obs);
                    }
                }
            }
            PeriodKind::Pivot => {
                if above {
                    // Check direction change
                    if self.current_period.direction != Some(obs.direction) {
                        // Direction changed — close pivot, open new pivot
                        closed_record = Some(self.close_current());
                        self.current_period = CurrentPeriod::new(
                            PeriodKind::Pivot,
                            Some(obs.direction),
                            obs,
                        );
                    } else {
                        // Same direction, still above — reset debounce, extend
                        self.current_period.below_count = 0;
                        self.current_period.extend(obs);
                    }
                } else {
                    // Below threshold while in pivot — debounce
                    self.current_period.below_count += 1;
                    self.current_period.extend(obs);
                    if self.current_period.below_count >= 3 {
                        // Debounce expired — close pivot, open gap
                        closed_record = Some(self.close_current());
                        self.current_period = CurrentPeriod::new(
                            PeriodKind::Gap,
                            None,
                            obs,
                        );
                    }
                }
            }
        }

        closed_record
    }

    /// Close the current period: convert to record, push to memory.
    fn close_current(&mut self) -> PivotRecord {
        let record = self.current_period.to_record();
        if self.pivot_memory.len() >= 20 {
            self.pivot_memory.pop_front();
        }
        self.pivot_memory.push_back(record.clone());
        record
    }

    /// Take a snapshot of the current state.
    fn snapshot(&self) -> PivotSnapshot {
        PivotSnapshot {
            records: self.pivot_memory.iter().cloned().collect(),
            current_period: self.current_period.clone(),
        }
    }

    /// Current conviction threshold (for telemetry).
    fn threshold(&self) -> f64 {
        self.conviction_history.percentile(0.80)
    }
}

/// Create a pivot tracker program.
///
/// - `observation_rxs`: N receivers, one per market observer (writes)
/// - `num_exit_slots`: how many exit observer slots need handles
/// - `slot_to_market`: maps exit slot index to market observer index
/// - `db_tx`: telemetry sender
///
/// Returns (Vec<PivotHandle>, PivotTrackerDriverHandle).
/// Each PivotHandle goes to the corresponding exit slot.
pub fn pivot_tracker(
    observation_rxs: Vec<QueueReceiver<PivotObservation>>,
    num_exit_slots: usize,
    slot_to_market: Vec<usize>,
    db_tx: QueueSender<LogEntry>,
) -> (Vec<PivotHandle>, PivotTrackerDriverHandle) {
    let num_market = observation_rxs.len();
    assert!(num_exit_slots > 0, "pivot tracker requires at least one exit slot");
    assert_eq!(slot_to_market.len(), num_exit_slots, "slot_to_market length must match num_exit_slots");

    // Per-exit-slot query/reply pairs
    let mut handles = Vec::with_capacity(num_exit_slots);
    let mut query_rxs = Vec::with_capacity(num_exit_slots);
    let mut reply_txs = Vec::with_capacity(num_exit_slots);

    for _ in 0..num_exit_slots {
        let (query_tx, query_rx) = queue::queue_unbounded::<()>();
        let (reply_tx, reply_rx) = queue::queue_unbounded::<PivotSnapshot>();

        query_rxs.push(query_rx);
        reply_txs.push(reply_tx);

        handles.push(PivotHandle {
            query_tx,
            reply_rx,
        });
    }

    let thread = thread::spawn(move || {
        // One tracker per market observer
        let mut trackers: Vec<TrackerState> = (0..num_market)
            .map(|_| TrackerState::new())
            .collect();

        let mut obs_alive: Vec<bool> = vec![true; num_market];
        let mut query_closed: Vec<bool> = vec![false; num_exit_slots];
        let mut candle_count: usize = 0;

        loop {
            // Phase 1: drain ALL observation queues
            let mut any_obs_alive = false;
            for (idx, rx) in observation_rxs.iter().enumerate() {
                if !obs_alive[idx] { continue; }
                any_obs_alive = true;
                loop {
                    match rx.try_recv() {
                        Ok(obs) => {
                            candle_count = candle_count.max(obs.candle_num);
                            if let Some(closed_record) = trackers[idx].observe(&obs) {
                                // Emit telemetry on period transition
                                let ts = std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap()
                                    .as_nanos() as u64;
                                let id = format!("pivot:{}:{}", idx, candle_count);
                                let dims = format!("{{\"market_idx\":{}}}", idx);
                                crate::programs::telemetry::emit_metric(
                                    &db_tx, "pivot-tracker", &id, &dims, ts,
                                    &format!("{}_closed", closed_record.kind),
                                    closed_record.duration as f64, "Count",
                                );
                            }
                        }
                        Err(crossbeam::channel::TryRecvError::Empty) => break,
                        Err(crossbeam::channel::TryRecvError::Disconnected) => {
                            obs_alive[idx] = false;
                            break;
                        }
                    }
                }
            }

            // Periodic telemetry: emit snapshot every 100 candles
            if candle_count > 0 && candle_count % 100 == 0 {
                for (idx, tracker) in trackers.iter().enumerate() {
                    let pivot_count = tracker.pivot_memory.iter()
                        .filter(|r| r.kind == PeriodKind::Pivot)
                        .count();
                    let gap_count = tracker.pivot_memory.iter()
                        .filter(|r| r.kind == PeriodKind::Gap)
                        .count();

                    let _ = db_tx.send(LogEntry::PivotTrackerSnapshot {
                        candle: candle_count,
                        market_idx: idx,
                        lens: format!("market-{}", idx),
                        pivot_count,
                        gap_count,
                        current_kind: format!("{}", tracker.current_period.kind),
                        current_duration: tracker.current_period.count,
                        threshold: tracker.threshold(),
                        conviction_window_size: tracker.conviction_history.len(),
                    });
                }
            }

            // Phase 2: service ALL pending queries
            let mut all_queries_closed = true;
            for slot_idx in 0..num_exit_slots {
                if query_closed[slot_idx] { continue; }
                all_queries_closed = false;
                match query_rxs[slot_idx].try_recv() {
                    Ok(()) => {
                        let market_idx = slot_to_market[slot_idx];
                        let snapshot = trackers[market_idx].snapshot();
                        let _ = reply_txs[slot_idx].send(snapshot);
                    }
                    Err(crossbeam::channel::TryRecvError::Empty) => {}
                    Err(crossbeam::channel::TryRecvError::Disconnected) => {
                        query_closed[slot_idx] = true;
                    }
                }
            }

            // Exit when all observation queues AND all query queues are disconnected
            if !any_obs_alive && all_queries_closed {
                break;
            }

            // Phase 3: select/wait for next activity
            let mut sel = crossbeam::channel::Select::new();
            let mut has_ops = false;
            for (idx, rx) in observation_rxs.iter().enumerate() {
                if obs_alive[idx] {
                    sel.recv(rx.inner());
                    has_ops = true;
                }
            }
            for (slot_idx, rx) in query_rxs.iter().enumerate() {
                if !query_closed[slot_idx] {
                    sel.recv(rx.inner());
                    has_ops = true;
                }
            }
            if !has_ops {
                break;
            }
            let _ = sel.ready();
        }
    });

    (
        handles,
        PivotTrackerDriverHandle {
            thread: Some(thread),
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::Direction;
    use crate::types::pivot::PivotObservation;
    use std::thread;
    use std::time::Duration;

    fn make_obs(market_idx: usize, conviction: f64, direction: Direction, candle_num: usize) -> PivotObservation {
        PivotObservation {
            market_idx,
            conviction,
            direction,
            candle_num,
            close: 50000.0,
            volume: 100.0,
        }
    }

    #[test]
    fn basic_pivot_detection() {
        let (obs_tx, obs_rx) = queue::queue_unbounded::<PivotObservation>();
        let (db_tx, _db_rx) = queue::queue_unbounded::<LogEntry>();

        let (handles, driver) = pivot_tracker(
            vec![obs_rx],
            1,
            vec![0],
            db_tx,
        );

        // Feed enough low-conviction observations to fill the window
        for i in 1..=50 {
            let _ = obs_tx.send(make_obs(0, 0.1, Direction::Up, i));
        }
        // Then a burst of high-conviction observations
        for i in 51..=60 {
            let _ = obs_tx.send(make_obs(0, 0.9, Direction::Up, i));
        }

        thread::sleep(Duration::from_millis(100));

        let snapshot = handles[0].query().expect("should get snapshot");
        // Should have some current period
        assert!(snapshot.current_period.count > 0);

        drop(handles);
        drop(obs_tx);
        driver.join();
    }

    #[test]
    fn shutdown_clean() {
        let (obs_tx, obs_rx) = queue::queue_unbounded::<PivotObservation>();
        let (db_tx, _db_rx) = queue::queue_unbounded::<LogEntry>();

        let (handles, driver) = pivot_tracker(
            vec![obs_rx],
            1,
            vec![0],
            db_tx,
        );

        drop(handles);
        drop(obs_tx);
        driver.join(); // should not hang
    }

    #[test]
    fn multiple_markets_multiple_slots() {
        let mut obs_txs = Vec::new();
        let mut obs_rxs = Vec::new();
        for _ in 0..3 {
            let (tx, rx) = queue::queue_unbounded::<PivotObservation>();
            obs_txs.push(tx);
            obs_rxs.push(rx);
        }
        let (db_tx, _db_rx) = queue::queue_unbounded::<LogEntry>();

        // 6 exit slots: 2 per market
        let slot_to_market = vec![0, 0, 1, 1, 2, 2];
        let (handles, driver) = pivot_tracker(
            obs_rxs,
            6,
            slot_to_market,
            db_tx,
        );

        // Feed some data
        for i in 1..=20 {
            for (mi, tx) in obs_txs.iter().enumerate() {
                let _ = tx.send(make_obs(mi, 0.5, Direction::Up, i));
            }
        }

        thread::sleep(Duration::from_millis(100));

        // All handles should respond
        for h in &handles {
            let snap = h.query().expect("should get snapshot");
            assert!(snap.current_period.count > 0);
        }

        drop(handles);
        for tx in obs_txs { drop(tx); }
        driver.join();
    }
}
