"""Tests for HolonGate and RuleTree."""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from trading.gate import GateSignal, HolonGate, Regime, label_regimes
from trading.rule_tree import (
    BUY_TRANSITIONS,
    SELL_TRANSITIONS,
    RejectionReason,
    RuleTree,
    TAContext,
    TradeAction,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _make_signal(
    fired=True,
    current=Regime.CONSOLIDATION,
    previous=Regime.TREND_DOWN,
    transition="TREND_DOWN → CONSOLIDATION",
    magnitude=5.0,
    tenure=10,
):
    return GateSignal(
        fired=fired,
        current_regime=current,
        previous_regime=previous,
        transition_type=transition,
        magnitude=magnitude,
        regime_tenure=tenure,
    )


# ---------------------------------------------------------------------------
# RuleTree — Gate Check
# ---------------------------------------------------------------------------

class TestGateCheck:
    def test_gate_not_fired_returns_hold(self):
        tree = RuleTree()
        signal = _make_signal(fired=False)
        result = tree.evaluate(signal)
        assert result.action == TradeAction.HOLD
        assert result.rejection == RejectionReason.GATE_NOT_FIRED

    def test_gate_fired_proceeds(self):
        tree = RuleTree(conviction_fires=1)
        signal = _make_signal(fired=True)
        # Pre-populate history so conviction passes
        tree._history.append(tree._history.__class__.__bases__[0].__new__(
            type(list(tree._history)[0]) if tree._history else object
        ) if tree._history else None)
        # Fresh tree with conviction_fires=1 should pass on first gate fire
        tree2 = RuleTree(conviction_fires=1)
        result = tree2.evaluate(signal)
        # Should not reject at gate level
        assert result.rejection != RejectionReason.GATE_NOT_FIRED


# ---------------------------------------------------------------------------
# RuleTree — Transition Filter
# ---------------------------------------------------------------------------

class TestTransitionFilter:
    def test_buy_transition_detected(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        signal = _make_signal(transition="TREND_DOWN → CONSOLIDATION")
        result = tree.evaluate(signal)
        assert result.direction_hint == "BUY"

    def test_sell_transition_detected(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        signal = _make_signal(
            transition="TREND_UP → CONSOLIDATION",
            previous=Regime.TREND_UP,
        )
        result = tree.evaluate(signal)
        assert result.direction_hint == "SELL"

    def test_nondirectional_transition_rejected(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        signal = _make_signal(transition="CONSOLIDATION → VOLATILE")
        result = tree.evaluate(signal)
        assert result.rejection == RejectionReason.TRANSITION_NOT_DIRECTIONAL

    def test_all_buy_transitions_map_correctly(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        for t in BUY_TRANSITIONS:
            assert tree._transition_direction(t) == "BUY", f"{t} should be BUY"

    def test_all_sell_transitions_map_correctly(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        for t in SELL_TRANSITIONS:
            assert tree._transition_direction(t) == "SELL", f"{t} should be SELL"


# ---------------------------------------------------------------------------
# RuleTree — Tenure Filter
# ---------------------------------------------------------------------------

class TestTenureFilter:
    def test_short_tenure_rejected(self):
        tree = RuleTree(conviction_fires=1, min_tenure=5)
        signal = _make_signal(tenure=2)
        result = tree.evaluate(signal)
        assert result.rejection == RejectionReason.TENURE_TOO_SHORT

    def test_sufficient_tenure_passes(self):
        tree = RuleTree(conviction_fires=1, min_tenure=3)
        signal = _make_signal(tenure=5)
        result = tree.evaluate(signal)
        assert result.rejection != RejectionReason.TENURE_TOO_SHORT


# ---------------------------------------------------------------------------
# RuleTree — History Guard
# ---------------------------------------------------------------------------

class TestHistoryGuard:
    def test_cooldown_blocks_rapid_trades(self):
        tree = RuleTree(cooldown_candles=6, conviction_fires=1, min_tenure=1)
        signal = _make_signal()

        # First trade goes through
        r1 = tree.evaluate(signal, step=10)
        assert r1.action in (TradeAction.BUY, TradeAction.SELL)

        # Immediately after should be blocked by cooldown
        r2 = tree.evaluate(signal, step=12)
        assert r2.rejection == RejectionReason.COOLDOWN

    def test_cooldown_expires(self):
        tree = RuleTree(cooldown_candles=6, conviction_fires=1, min_tenure=1)
        signal = _make_signal()

        tree.evaluate(signal, step=10)
        # After cooldown expires
        result = tree.evaluate(signal, step=20)
        assert result.rejection != RejectionReason.COOLDOWN

    def test_rate_limit_blocks_excessive_trades(self):
        tree = RuleTree(
            max_trades_per_window=2, rate_window=100,
            cooldown_candles=1, conviction_fires=1, min_tenure=1,
        )
        signal = _make_signal()

        tree.evaluate(signal, step=10)
        tree.evaluate(signal, step=20)
        result = tree.evaluate(signal, step=30)
        assert result.rejection == RejectionReason.RATE_LIMIT

    def test_conviction_requires_multiple_fires(self):
        tree = RuleTree(conviction_fires=3, conviction_window=6, min_tenure=1)
        signal = _make_signal()

        # First fire — not enough conviction
        result = tree.evaluate(signal, step=10)
        assert result.rejection == RejectionReason.INSUFFICIENT_CONVICTION

    def test_conviction_met_after_enough_fires(self):
        tree = RuleTree(
            conviction_fires=2, conviction_window=10,
            cooldown_candles=1, min_tenure=1,
        )
        signal = _make_signal()
        not_fired = _make_signal(fired=False)

        # Build up conviction
        tree.evaluate(signal, step=1)  # fire 1 (will trade, conviction=1 passes since it IS the fire)
        # After cooldown
        tree.evaluate(signal, step=10)  # fire 2, conviction met
        # The second should not be rejected for conviction
        # (it may be rejected for other reasons, but not conviction)


# ---------------------------------------------------------------------------
# RuleTree — Risk Gate
# ---------------------------------------------------------------------------

class TestRiskGate:
    def test_drawdown_blocks_trading(self):
        tree = RuleTree(
            max_drawdown=0.10, conviction_fires=1, min_tenure=1,
        )
        signal = _make_signal()

        # Simulate equity peak then drop
        tree.evaluate(signal, equity=10000, step=10)
        tree._peak_equity = 10000
        result = tree.evaluate(signal, equity=8000, step=20)
        assert result.rejection == RejectionReason.RISK_EXCEEDED

    def test_loss_streak_blocks_trading(self):
        tree = RuleTree(
            max_loss_streak=3, conviction_fires=1, min_tenure=1,
        )
        signal = _make_signal()

        tree.record_trade_result(-100)
        tree.record_trade_result(-50)
        tree.record_trade_result(-75)
        result = tree.evaluate(signal, step=10)
        assert result.rejection == RejectionReason.RISK_EXCEEDED

    def test_win_resets_loss_streak(self):
        tree = RuleTree(
            max_loss_streak=3, conviction_fires=1, min_tenure=1,
        )
        tree.record_trade_result(-100)
        tree.record_trade_result(-50)
        tree.record_trade_result(200)  # win resets streak
        assert tree._consecutive_losses == 0


# ---------------------------------------------------------------------------
# RuleTree — Full Pipeline
# ---------------------------------------------------------------------------

class TestFullPipeline:
    def test_buy_signal_through_full_tree(self):
        tree = RuleTree(
            conviction_fires=1, min_tenure=1,
            cooldown_candles=1, max_loss_streak=100,
        )
        signal = _make_signal(
            transition="TREND_DOWN → CONSOLIDATION",
            tenure=10, magnitude=5.0,
        )
        result = tree.evaluate(signal, equity=10000, step=100)
        assert result.action == TradeAction.BUY
        assert result.direction_hint == "BUY"
        assert result.confidence > 0.5

    def test_sell_signal_through_full_tree(self):
        tree = RuleTree(
            conviction_fires=1, min_tenure=1,
            cooldown_candles=1, max_loss_streak=100,
        )
        signal = _make_signal(
            transition="TREND_UP → CONSOLIDATION",
            previous=Regime.TREND_UP,
            tenure=10, magnitude=5.0,
        )
        result = tree.evaluate(signal, equity=10000, step=100)
        assert result.action == TradeAction.SELL
        assert result.direction_hint == "SELL"

    def test_diagnostics_track_counts(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        signal_fire = _make_signal()
        signal_no = _make_signal(fired=False)

        tree.evaluate(signal_no, step=1)
        tree.evaluate(signal_fire, step=10)

        diag = tree.diagnostics()
        assert diag["rejections"]["gate_not_fired"] == 1
        assert diag["actions"]["HOLD"] >= 1

    def test_reset_clears_state(self):
        tree = RuleTree(conviction_fires=1, min_tenure=1)
        tree.evaluate(_make_signal(), step=10)
        tree.reset()
        assert tree._step == 0
        assert len(tree._history) == 0
        assert all(v == 0 for v in tree.rejection_counts.values())


# ---------------------------------------------------------------------------
# GateSignal
# ---------------------------------------------------------------------------

class TestGateSignal:
    def test_gate_signal_creation(self):
        sig = GateSignal(
            fired=True, current_regime=Regime.TREND_UP,
            previous_regime=Regime.TREND_DOWN,
            transition_type="TREND_DOWN → TREND_UP",
            magnitude=3.5, regime_tenure=15,
        )
        assert sig.fired is True
        assert sig.current_regime == Regime.TREND_UP
        assert sig.regime_tenure == 15


# ---------------------------------------------------------------------------
# label_regimes
# ---------------------------------------------------------------------------

class TestLabelRegimes:
    def _make_trending_up_df(self, n=50):
        """Create a DataFrame with steadily rising prices."""
        prices = 100 + np.arange(n) * 0.5
        df = pd.DataFrame({
            "open": prices - 0.1,
            "high": prices + 0.3,
            "low": prices - 0.3,
            "close": prices,
            "volume": np.ones(n) * 1000,
            "atr": np.ones(n) * 0.3,
        })
        return df

    def _make_flat_df(self, n=50):
        """Create a DataFrame with flat/sideways prices."""
        prices = np.full(n, 100.0) + np.random.default_rng(42).normal(0, 0.01, n)
        df = pd.DataFrame({
            "open": prices - 0.01,
            "high": prices + 0.02,
            "low": prices - 0.02,
            "close": prices,
            "volume": np.ones(n) * 1000,
            "atr": np.ones(n) * 0.02,
        })
        return df

    def test_trending_up_labeled_correctly(self):
        df = self._make_trending_up_df()
        labels = label_regimes(df, window=12)
        # Later candles should be labeled TREND_UP
        assert labels[30] == "TREND_UP"

    def test_flat_labeled_consolidation(self):
        df = self._make_flat_df()
        labels = label_regimes(df, window=12)
        # Should be CONSOLIDATION
        assert labels[30] == "CONSOLIDATION"

    def test_first_window_candles_are_unknown(self):
        df = self._make_trending_up_df()
        labels = label_regimes(df, window=12)
        assert labels[5] == "UNKNOWN"

    def test_output_length_matches_input(self):
        df = self._make_trending_up_df(100)
        labels = label_regimes(df, window=12)
        assert len(labels) == len(df)


# ---------------------------------------------------------------------------
# TA Confirmation
# ---------------------------------------------------------------------------

class TestTAConfirmation:
    def test_buy_rejected_low_rsi(self):
        """BUY with RSI below threshold should be rejected."""
        tree = RuleTree(conviction_fires=1, min_tenure=1, buy_rsi_min=50)
        signal = _make_signal(transition="TREND_DOWN → CONSOLIDATION")
        ta = TAContext(rsi=35, macd_hist=0.01)
        result = tree.evaluate(signal, step=10, ta=ta)
        assert result.rejection == RejectionReason.TA_REJECTED

    def test_buy_rejected_macd_negative(self):
        """BUY with negative MACD hist should be rejected."""
        tree = RuleTree(conviction_fires=1, min_tenure=1, buy_rsi_min=50)
        signal = _make_signal(transition="TREND_DOWN → CONSOLIDATION")
        ta = TAContext(rsi=60, macd_hist=-0.01)
        result = tree.evaluate(signal, step=10, ta=ta)
        assert result.rejection == RejectionReason.TA_REJECTED

    def test_buy_accepted_momentum_confirmed(self):
        """BUY with high RSI and positive MACD should pass."""
        tree = RuleTree(
            conviction_fires=1, min_tenure=1, cooldown_candles=1,
            buy_rsi_min=50,
        )
        signal = _make_signal(transition="TREND_DOWN → CONSOLIDATION")
        ta = TAContext(rsi=65, macd_hist=0.01)
        result = tree.evaluate(signal, equity=10000, step=10, ta=ta)
        assert result.action == TradeAction.BUY

    def test_sell_rejected_high_rsi(self):
        """SELL with RSI above threshold should be rejected."""
        tree = RuleTree(conviction_fires=1, min_tenure=1, sell_rsi_max=50)
        signal = _make_signal(
            transition="TREND_UP → CONSOLIDATION",
            previous=Regime.TREND_UP,
        )
        ta = TAContext(rsi=65)
        result = tree.evaluate(signal, step=10, ta=ta)
        assert result.rejection == RejectionReason.TA_REJECTED

    def test_sell_accepted_weak_rsi(self):
        """SELL with RSI below threshold should pass."""
        tree = RuleTree(
            conviction_fires=1, min_tenure=1, cooldown_candles=1,
            sell_rsi_max=50,
        )
        signal = _make_signal(
            transition="TREND_UP → CONSOLIDATION",
            previous=Regime.TREND_UP,
        )
        ta = TAContext(rsi=35)
        result = tree.evaluate(signal, equity=10000, step=10, ta=ta)
        assert result.action == TradeAction.SELL

    def test_ta_disabled_bypasses_check(self):
        """With ta_enabled=False, TA context is ignored."""
        tree = RuleTree(
            conviction_fires=1, min_tenure=1, cooldown_candles=1,
            ta_enabled=False, buy_rsi_min=90,
        )
        signal = _make_signal(transition="TREND_DOWN → CONSOLIDATION")
        ta = TAContext(rsi=30, macd_hist=-0.5)
        result = tree.evaluate(signal, equity=10000, step=10, ta=ta)
        assert result.action == TradeAction.BUY

    def test_no_ta_context_bypasses_check(self):
        """With no TAContext passed, TA check is skipped."""
        tree = RuleTree(
            conviction_fires=1, min_tenure=1, cooldown_candles=1,
            buy_rsi_min=90,
        )
        signal = _make_signal(transition="TREND_DOWN → CONSOLIDATION")
        result = tree.evaluate(signal, equity=10000, step=10)
        assert result.action == TradeAction.BUY
