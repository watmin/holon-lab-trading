//! Exit expert encoding — atoms and thought composition for the exit observer.
//!
//! The exit expert encodes position state (P&L, hold duration, MFE, MAE,
//! ATR at entry/now, stop distance, phase, direction) into a single thought
//! vector. The exit journal learns Hold/Exit from these thoughts.
//!
//! rune:scry(aspirational) — exit.wat specifies the exit expert modulates
//! k_trail per position per candle based on its Hold/Exit prediction.
//! Code only buffers ExitObservation and learns labels but never reads
//! the exit expert's prediction to adjust trailing stops.

use holon::{Primitives, ScalarEncoder, ScalarMode, Vector, VectorManager};
use crate::position::{ManagedPosition, PositionPhase};

/// Immutable atom vectors for the exit expert encoding.
pub struct ExitAtoms {
    pub pnl: Vector,
    pub hold: Vector,
    pub mfe: Vector,
    pub mae: Vector,
    pub atr_entry: Vector,
    pub atr_now: Vector,
    pub stop_dist: Vector,
    pub phase: Vector,
    pub direction: Vector,
    // Filler atoms — pre-warmed, not created in the hot path
    pub runner: Vector,
    pub active: Vector,
    pub buy: Vector,
    pub sell: Vector,
}

impl ExitAtoms {
    pub fn new(vm: &VectorManager) -> Self {
        Self {
            pnl: vm.get_vector("position-pnl"),
            hold: vm.get_vector("position-hold"),
            mfe: vm.get_vector("position-mfe"),
            mae: vm.get_vector("position-mae"),
            atr_entry: vm.get_vector("position-atr-entry"),
            atr_now: vm.get_vector("position-atr-now"),
            stop_dist: vm.get_vector("position-stop-dist"),
            phase: vm.get_vector("position-phase"),
            direction: vm.get_vector("position-direction"),
            runner: vm.get_vector("runner"),
            active: vm.get_vector("active"),
            buy: vm.get_vector("buy"),
            sell: vm.get_vector("sell"),
        }
    }
}

/// Encode a single exit-expert thought from position state + current market.
///
/// Nine facts: pnl, hold duration, MFE, MAE, ATR at entry, ATR now, stop distance,
/// position phase, and direction — bundled into one vector.
pub fn encode_exit_thought(
    pos: &ManagedPosition,
    pnl_frac: f64,
    current_rate: f64,
    exit_atoms: &ExitAtoms,
    exit_scalar: &ScalarEncoder,
    candle_atr: f64,
    is_buy: bool,
) -> Vector {
    // MFE in rate space: how far did the rate go in our favor?
    let mfe_frac = (pos.extreme_rate - pos.entry_rate) / pos.entry_rate;
    // Stop distance in rate space
    let stop_dist = (pos.trailing_stop - current_rate).abs() / current_rate;

    Primitives::bundle(&[
        &Primitives::bind(&exit_atoms.pnl, &exit_scalar.encode(pnl_frac.clamp(-1.0, 1.0) * 0.5 + 0.5, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.hold, &exit_scalar.encode_log(pos.candles_held as f64)),
        &Primitives::bind(&exit_atoms.mfe, &exit_scalar.encode(mfe_frac.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.mae, &exit_scalar.encode(pos.max_adverse.clamp(-1.0, 0.0).abs(), ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.atr_entry, &exit_scalar.encode_log(pos.entry_atr.max(1e-10))),
        &Primitives::bind(&exit_atoms.atr_now, &exit_scalar.encode_log(candle_atr.max(1e-10))),
        &Primitives::bind(&exit_atoms.stop_dist, &exit_scalar.encode(stop_dist.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.phase, if pos.phase == PositionPhase::Runner { &exit_atoms.runner } else { &exit_atoms.active }),
        &Primitives::bind(&exit_atoms.direction, if is_buy { &exit_atoms.buy } else { &exit_atoms.sell }),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::position::PositionEntry;
    use crate::treasury::Asset;

    const TEST_DIMS: usize = 64;

    fn make_vm() -> VectorManager {
        VectorManager::new(TEST_DIMS)
    }

    fn make_position() -> ManagedPosition {
        let entry = PositionEntry {
            id: 1,
            candle_idx: 0,
            source_asset: Asset::new("USDC"),
            target_asset: Asset::new("WBTC"),
            source_amount: 1000.0,
            target_received: 0.02,
            entry_rate: 50000.0,
            entry_atr: 0.01,
            entry_fee: 1.0,
            k_stop: 2.0,
            k_tp: 3.0,
        };
        ManagedPosition::new(entry)
    }

    #[test]
    fn exit_atoms_new_does_not_panic() {
        let vm = make_vm();
        let _atoms = ExitAtoms::new(&vm);
    }

    #[test]
    fn exit_atoms_fields_are_nonzero() {
        let vm = make_vm();
        let atoms = ExitAtoms::new(&vm);
        assert!(atoms.pnl.data().iter().any(|&x| x != 0));
        assert!(atoms.hold.data().iter().any(|&x| x != 0));
        assert!(atoms.buy.data().iter().any(|&x| x != 0));
        assert!(atoms.sell.data().iter().any(|&x| x != 0));
    }

    #[test]
    fn encode_exit_thought_returns_nonzero_vector() {
        let vm = make_vm();
        let atoms = ExitAtoms::new(&vm);
        let scalar = ScalarEncoder::new(TEST_DIMS);
        let pos = make_position();

        let thought = encode_exit_thought(
            &pos,
            0.05,    // pnl_frac (5% profit)
            51000.0, // current_rate
            &atoms,
            &scalar,
            0.015,   // candle_atr
            true,    // is_buy
        );

        assert!(thought.data().iter().any(|&x| x != 0), "exit thought should be non-zero");
    }

    #[test]
    fn encode_exit_thought_buy_vs_sell_differ() {
        let vm = make_vm();
        let atoms = ExitAtoms::new(&vm);
        let scalar = ScalarEncoder::new(TEST_DIMS);
        let pos = make_position();

        let thought_buy = encode_exit_thought(&pos, 0.05, 51000.0, &atoms, &scalar, 0.015, true);
        let thought_sell = encode_exit_thought(&pos, 0.05, 51000.0, &atoms, &scalar, 0.015, false);

        assert_ne!(thought_buy.data(), thought_sell.data(),
            "buy and sell exit thoughts should differ");
    }

    #[test]
    fn encode_exit_thought_different_pnl_differ() {
        // Use higher dims so scalar encoding has room to differentiate
        let dims = 256;
        let vm = VectorManager::new(dims);
        let atoms = ExitAtoms::new(&vm);
        let scalar = ScalarEncoder::new(dims);
        let pos_entry = PositionEntry {
            id: 1, candle_idx: 0,
            source_asset: Asset::new("USDC"), target_asset: Asset::new("WBTC"),
            source_amount: 1000.0, target_received: 0.02,
            entry_rate: 50000.0, entry_atr: 0.01, entry_fee: 1.0,
            k_stop: 2.0, k_tp: 3.0,
        };
        let pos = ManagedPosition::new(pos_entry);

        let thought_profit = encode_exit_thought(&pos, 0.50, 51000.0, &atoms, &scalar, 0.015, true);
        let thought_loss = encode_exit_thought(&pos, -0.50, 51000.0, &atoms, &scalar, 0.015, true);

        // At 256 dims with extreme P&L difference, cosine should be < 1.0
        let sim = holon::Similarity::cosine(&thought_profit, &thought_loss);
        assert!(sim < 0.99, "profit and loss exit thoughts should differ, cosine={sim}");
    }
}
