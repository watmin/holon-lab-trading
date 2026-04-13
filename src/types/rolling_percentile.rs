/// RollingPercentile — a bounded window of f64 values with percentile computation.
/// Used by the pivot tracker (conviction threshold at 80th percentile, N=500)
/// and potentially by the broker's journey grading.

use std::collections::VecDeque;

pub struct RollingPercentile {
    values: VecDeque<f64>,
    capacity: usize,
}

impl RollingPercentile {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "RollingPercentile requires non-zero capacity");
        Self {
            values: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    /// Push a value. If at capacity, drop the oldest.
    pub fn push(&mut self, value: f64) {
        if self.values.len() >= self.capacity {
            self.values.pop_front();
        }
        self.values.push_back(value);
    }

    /// Compute the p-th percentile (p in [0.0, 1.0]).
    /// Returns 0.0 if empty. Copies to a temp vec, sorts, indexes.
    pub fn percentile(&self, p: f64) -> f64 {
        if self.values.is_empty() {
            return 0.0;
        }
        let mut sorted: Vec<f64> = self.values.iter().copied().collect();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let idx = ((sorted.len() as f64 - 1.0) * p.clamp(0.0, 1.0)) as usize;
        sorted[idx]
    }

    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_returns_zero() {
        let rp = RollingPercentile::new(10);
        assert_eq!(rp.percentile(0.5), 0.0);
        assert!(rp.is_empty());
    }

    #[test]
    fn single_value() {
        let mut rp = RollingPercentile::new(10);
        rp.push(42.0);
        assert_eq!(rp.percentile(0.0), 42.0);
        assert_eq!(rp.percentile(0.5), 42.0);
        assert_eq!(rp.percentile(1.0), 42.0);
        assert_eq!(rp.len(), 1);
    }

    #[test]
    fn bounded_capacity() {
        let mut rp = RollingPercentile::new(3);
        rp.push(1.0);
        rp.push(2.0);
        rp.push(3.0);
        assert_eq!(rp.len(), 3);
        rp.push(4.0); // evicts 1.0
        assert_eq!(rp.len(), 3);
        // Values are now [2, 3, 4]
        assert_eq!(rp.percentile(0.0), 2.0);
        assert_eq!(rp.percentile(1.0), 4.0);
    }

    #[test]
    fn percentile_80th() {
        let mut rp = RollingPercentile::new(100);
        for i in 1..=100 {
            rp.push(i as f64);
        }
        let p80 = rp.percentile(0.80);
        // 80th percentile of 1..=100 should be around 80
        assert!(p80 >= 79.0 && p80 <= 81.0, "got {}", p80);
    }

    #[test]
    fn percentile_50th_is_median() {
        let mut rp = RollingPercentile::new(10);
        rp.push(10.0);
        rp.push(20.0);
        rp.push(30.0);
        rp.push(40.0);
        rp.push(50.0);
        let median = rp.percentile(0.50);
        assert_eq!(median, 30.0);
    }
}
