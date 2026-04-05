//! Enterprise — the four-step candle loop.
//!
//! See wat/enterprise.wat for the specification.
//!
//! RESOLVE → COMPUTE+DISPATCH → PROCESS → COLLECT+FUND
//! Four steps. Sequential. Reality first.
//! The parallelism is inside COMPUTE (par_iter market observers).
//!
//! The desk is gone. The treasury IS the desk.
//! The manager is gone. The tuple journal IS the manager.

use holon::Vector;

use crate::exit::tuple::TupleJournal;
use crate::exit::learned_stop::LearnedStop;
use crate::position::ManagedPosition;

/// A trade proposal from an exit observer.
#[derive(Clone)]
pub struct Proposal {
    pub composed_thought: Vector,
    pub direction: Option<crate::journal::Label>,
    pub distance: f64,
    pub conviction: f64,
    pub market_idx: usize,
    pub exit_idx: usize,
}

/// The enterprise's three flat N×M vecs + accounting.
/// Pre-allocated at startup. Disjoint slots. Mutex-free parallel.
pub struct Enterprise {
    /// N market observers × M exit observers
    pub n_market: usize,
    pub m_exit: usize,

    /// Closures: permanent, never shrink. Each knows its (market, exit) pair.
    pub registry: Vec<TupleJournal>,

    /// Proposals waiting for funding. Cleared every candle.
    pub proposals: Vec<Option<Proposal>>,

    /// Active trades. Insert on fund, remove on close.
    pub trades: Vec<Option<ManagedPosition>>,

    /// Thought vectors stashed at trade entry for tuple journal resolution.
    pub trade_thoughts: Vec<Option<Vec<Vector>>>,
}

impl Enterprise {
    /// Pre-allocate N×M slots.
    pub fn new(
        n_market: usize,
        m_exit: usize,
        dims: usize,
        recalib_interval: usize,
        market_names: &[&str],
        exit_names: &[&str],
    ) -> Self {
        let total = n_market * m_exit;
        let mut registry = Vec::with_capacity(total);
        for mi in 0..n_market {
            for ei in 0..m_exit {
                registry.push(TupleJournal::new(
                    market_names.get(mi).unwrap_or(&"market"),
                    exit_names.get(ei).unwrap_or(&"exit"),
                    dims,
                    recalib_interval,
                ));
            }
        }

        let mut proposals = Vec::with_capacity(total);
        let mut trades = Vec::with_capacity(total);
        let mut trade_thoughts = Vec::with_capacity(total);
        for _ in 0..total {
            proposals.push(None);
            trades.push(None);
            trade_thoughts.push(None);
        }

        Self {
            n_market,
            m_exit,
            registry,
            proposals,
            trades,
            trade_thoughts,
        }
    }

    /// Flat index from (market_idx, exit_idx).
    #[inline]
    pub fn idx(&self, market_idx: usize, exit_idx: usize) -> usize {
        market_idx * self.m_exit + exit_idx
    }

    /// Clear all proposals. Called at end of Step 4.
    pub fn clear_proposals(&mut self) {
        for p in &mut self.proposals {
            *p = None;
        }
    }

    /// Count active trades.
    pub fn active_trade_count(&self) -> usize {
        self.trades.iter().filter(|t| t.is_some()).count()
    }

    /// Count proposals this candle.
    pub fn proposal_count(&self) -> usize {
        self.proposals.iter().filter(|p| p.is_some()).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enterprise_new_preallocates() {
        let e = Enterprise::new(
            7, 4, 64, 500,
            &["momentum", "structure", "volume", "narrative", "regime", "generalist", "classic"],
            &["volatility", "structure", "timing", "exit-generalist"],
        );
        assert_eq!(e.registry.len(), 28); // 7 × 4
        assert_eq!(e.proposals.len(), 28);
        assert_eq!(e.trades.len(), 28);
        assert_eq!(e.active_trade_count(), 0);
        assert_eq!(e.proposal_count(), 0);
    }

    #[test]
    fn enterprise_idx() {
        let e = Enterprise::new(3, 4, 64, 500, &["a", "b", "c"], &["x", "y", "z", "w"]);
        assert_eq!(e.idx(0, 0), 0);
        assert_eq!(e.idx(0, 3), 3);
        assert_eq!(e.idx(1, 0), 4);
        assert_eq!(e.idx(2, 3), 11);
    }
}
