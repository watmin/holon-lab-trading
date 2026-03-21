"""RuleTree — static decision tree with dynamic Holon gate invocations.

Fixed structure, deterministic, auditable. Receives raw candle data and
a GateSignal from the HolonGate. Each node evaluates a condition and
routes to children. Leaf nodes produce BUY/SELL/HOLD actions.

Tree structure:
  1. Gate Check       — did the gate fire?
  2. Transition Filter — is this a directionally meaningful transition?
  3. History Guard    — cooldown, rate limit, streak, conviction checks
  4. Cost Gate        — is the expected edge > fees?
  5. Direction Node   — which direction does the transition imply?
  6. Risk Gate        — position sizing, drawdown, tilt protection

The tree logs which node rejected each signal for diagnostic analysis.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import NamedTuple

import numpy as np
import pandas as pd

from .gate import GateSignal, Regime


class TradeAction(str, Enum):
    BUY = "BUY"
    SELL = "SELL"
    HOLD = "HOLD"


class RejectionReason(str, Enum):
    GATE_NOT_FIRED = "gate_not_fired"
    TRANSITION_NOT_DIRECTIONAL = "transition_not_directional"
    COOLDOWN = "cooldown"
    RATE_LIMIT = "rate_limit"
    STREAK_SUPPRESSED = "streak_suppressed"
    INSUFFICIENT_CONVICTION = "insufficient_conviction"
    COST_TOO_HIGH = "cost_too_high"
    DIRECTION_AMBIGUOUS = "direction_ambiguous"
    RISK_EXCEEDED = "risk_exceeded"
    TENURE_TOO_SHORT = "tenure_too_short"
    TA_REJECTED = "ta_rejected"


@dataclass
class TAContext:
    """TA indicator values at the current candle, computed before tree eval.

    These are scalar summaries passed into the tree for momentum confirmation.
    Computed outside the tree so the tree remains pure decision logic.
    """
    rsi: float = 50.0
    macd_hist: float = 0.0   # price-normalized MACD histogram
    bb_pos: float = 0.5      # 0=lower band, 1=upper band
    adx: float = 25.0
    vol_r: float = 0.0       # volume relative to SMA


@dataclass
class TreeResult:
    """Full result from tree evaluation — includes diagnostics."""
    action: TradeAction
    confidence: float
    rejection: RejectionReason | None = None
    direction_hint: str | None = None  # "BUY" or "SELL" from transition type
    transition_type: str | None = None
    regime_tenure: int = 0


class _HistoryEvent(NamedTuple):
    step: int
    gate_fired: bool
    action: str


# Transitions that indicate a directional opportunity.
# Based on empirical results from explore_regime.py:
#   TREND_DOWN-involving transitions → BUY-biased
#   TREND_UP-involving transitions → SELL-biased

BUY_TRANSITIONS = frozenset({
    "TREND_DOWN → CONSOLIDATION",
    "TREND_DOWN → VOLATILE",
    "TREND_DOWN → TREND_UP",
    "VOLATILE → TREND_UP",       # recovery from volatile selloff
})

SELL_TRANSITIONS = frozenset({
    "TREND_UP → CONSOLIDATION",
    "TREND_UP → VOLATILE",
    "TREND_UP → TREND_DOWN",
    "VOLATILE → TREND_DOWN",     # breakdown from volatile rally
})


class RuleTree:
    """Static decision tree with configurable guard parameters.

    All parameters are constructor arguments — no magic numbers buried
    in methods. The backtest sweeps these to find optimal values.
    """

    def __init__(
        self,
        # Cost parameters (Jupiter/Solana)
        fee_per_side: float = 0.025,  # 0.025% per swap

        # History guard parameters
        cooldown_candles: int = 6,        # min candles between trades (30 min)
        max_trades_per_window: int = 3,   # max trades per rate_window
        rate_window: int = 48,            # rate limit window (4 hours)
        streak_suppress: int = 10,        # suppress if gate fires N times straight
        conviction_fires: int = 2,        # require N gate fires in conviction_window
        conviction_window: int = 6,       # conviction lookback (30 min)

        # Tenure filter
        min_tenure: int = 3,              # previous regime must have held N candles

        # TA momentum confirmation — buy on confirmation, not on dip
        # Empirical finding: momentum-following beats mean-reversion at
        # regime transitions. Buy when RSI/MACD confirm recovery,
        # sell when RSI/MACD confirm exhaustion.
        buy_rsi_min: float = 50.0,        # BUY requires RSI above this
        buy_macd_positive: bool = True,   # BUY requires MACD hist > 0
        sell_rsi_max: float = 50.0,       # SELL requires RSI below this
        ta_enabled: bool = True,          # toggle TA confirmation

        # Risk parameters
        max_drawdown: float = 0.20,       # stop trading if drawdown exceeds 20%
        max_loss_streak: int = 5,         # stop after N consecutive losses

        # Edge estimation
        min_edge_pct: float = 0.0,        # minimum estimated edge (0 = no filter)
    ):
        self.fee_per_side = fee_per_side
        self.cooldown_candles = cooldown_candles
        self.max_trades_per_window = max_trades_per_window
        self.rate_window = rate_window
        self.streak_suppress = streak_suppress
        self.conviction_fires = conviction_fires
        self.conviction_window = conviction_window
        self.min_tenure = min_tenure
        self.buy_rsi_min = buy_rsi_min
        self.buy_macd_positive = buy_macd_positive
        self.sell_rsi_max = sell_rsi_max
        self.ta_enabled = ta_enabled
        self.max_drawdown = max_drawdown
        self.max_loss_streak = max_loss_streak
        self.min_edge_pct = min_edge_pct

        self._history: deque[_HistoryEvent] = deque(maxlen=max(rate_window, 200))
        self._step = 0
        self._consecutive_losses = 0
        self._peak_equity = 0.0
        self._current_equity = 0.0

        # Diagnostic counters
        self.rejection_counts: dict[str, int] = {r.value: 0 for r in RejectionReason}
        self.action_counts: dict[str, int] = {"BUY": 0, "SELL": 0, "HOLD": 0}

    def evaluate(
        self,
        signal: GateSignal,
        candles: pd.DataFrame | None = None,
        equity: float = 0.0,
        step: int | None = None,
        ta: TAContext | None = None,
    ) -> TreeResult:
        """Walk the tree top-down. Returns action + diagnostics."""
        self._step = step if step is not None else self._step + 1
        self._current_equity = equity
        self._peak_equity = max(self._peak_equity, equity)

        # --- Node 1: Gate Check ---
        if not signal.fired:
            self._record(gate_fired=False, action="HOLD")
            self.rejection_counts[RejectionReason.GATE_NOT_FIRED.value] += 1
            self.action_counts["HOLD"] += 1
            return TreeResult(
                action=TradeAction.HOLD, confidence=0.0,
                rejection=RejectionReason.GATE_NOT_FIRED,
            )

        transition = signal.transition_type

        # --- Node 2: Transition Filter ---
        direction_hint = self._transition_direction(transition)
        if direction_hint is None:
            self._record(gate_fired=True, action="HOLD")
            self.rejection_counts[RejectionReason.TRANSITION_NOT_DIRECTIONAL.value] += 1
            self.action_counts["HOLD"] += 1
            return TreeResult(
                action=TradeAction.HOLD, confidence=0.0,
                rejection=RejectionReason.TRANSITION_NOT_DIRECTIONAL,
                transition_type=transition,
                regime_tenure=signal.regime_tenure,
            )

        # --- Node 2b: Tenure Filter ---
        if signal.regime_tenure < self.min_tenure:
            self._record(gate_fired=True, action="HOLD")
            self.rejection_counts[RejectionReason.TENURE_TOO_SHORT.value] += 1
            self.action_counts["HOLD"] += 1
            return TreeResult(
                action=TradeAction.HOLD, confidence=0.0,
                rejection=RejectionReason.TENURE_TOO_SHORT,
                direction_hint=direction_hint,
                transition_type=transition,
                regime_tenure=signal.regime_tenure,
            )

        # --- Node 3: History Guard ---
        # Record the current gate fire BEFORE checking conviction so the
        # current signal counts toward the conviction requirement.
        self._record(gate_fired=True, action="PENDING")
        guard_rejection = self._history_guard()
        if guard_rejection is not None:
            # Overwrite the pending record with HOLD
            self._history[-1] = _HistoryEvent(
                step=self._step, gate_fired=True, action="HOLD",
            )
            self.rejection_counts[guard_rejection.value] += 1
            self.action_counts["HOLD"] += 1
            return TreeResult(
                action=TradeAction.HOLD, confidence=0.0,
                rejection=guard_rejection,
                direction_hint=direction_hint,
                transition_type=transition,
                regime_tenure=signal.regime_tenure,
            )

        # --- Node 4: Cost Gate ---
        round_trip_cost = self.fee_per_side * 2
        if self.min_edge_pct > 0 and signal.magnitude < self.min_edge_pct + round_trip_cost:
            self._update_pending("HOLD")
            self.rejection_counts[RejectionReason.COST_TOO_HIGH.value] += 1
            self.action_counts["HOLD"] += 1
            return TreeResult(
                action=TradeAction.HOLD, confidence=0.0,
                rejection=RejectionReason.COST_TOO_HIGH,
                direction_hint=direction_hint,
                transition_type=transition,
                regime_tenure=signal.regime_tenure,
            )

        # --- Node 5: Direction (from transition type) ---
        action = TradeAction.BUY if direction_hint == "BUY" else TradeAction.SELL

        # --- Node 5b: TA Momentum Confirmation ---
        if self.ta_enabled and ta is not None:
            if not self._ta_confirms(action, ta):
                self._update_pending("HOLD")
                self.rejection_counts[RejectionReason.TA_REJECTED.value] += 1
                self.action_counts["HOLD"] += 1
                return TreeResult(
                    action=TradeAction.HOLD, confidence=0.0,
                    rejection=RejectionReason.TA_REJECTED,
                    direction_hint=direction_hint,
                    transition_type=transition,
                    regime_tenure=signal.regime_tenure,
                )

        # --- Node 6: Risk Gate ---
        risk_rejection = self._risk_gate()
        if risk_rejection is not None:
            self._update_pending("HOLD")
            self.rejection_counts[risk_rejection.value] += 1
            self.action_counts["HOLD"] += 1
            return TreeResult(
                action=TradeAction.HOLD, confidence=0.0,
                rejection=risk_rejection,
                direction_hint=direction_hint,
                transition_type=transition,
                regime_tenure=signal.regime_tenure,
            )

        # --- Leaf: Execute ---
        confidence = min(0.5 + signal.magnitude / 20.0, 0.95)
        self._update_pending(action.value)
        self.action_counts[action.value] += 1
        return TreeResult(
            action=action,
            confidence=confidence,
            direction_hint=direction_hint,
            transition_type=transition,
            regime_tenure=signal.regime_tenure,
        )

    def record_trade_result(self, pnl: float):
        """Feed back trade results for risk gate tracking."""
        if pnl < 0:
            self._consecutive_losses += 1
        else:
            self._consecutive_losses = 0

    def reset(self):
        """Reset tree state for backtesting across periods."""
        self._history.clear()
        self._step = 0
        self._consecutive_losses = 0
        self._peak_equity = 0.0
        self._current_equity = 0.0
        self.rejection_counts = {r.value: 0 for r in RejectionReason}
        self.action_counts = {"BUY": 0, "SELL": 0, "HOLD": 0}

    def diagnostics(self) -> dict:
        """Return rejection and action counts for analysis."""
        return {
            "rejections": dict(self.rejection_counts),
            "actions": dict(self.action_counts),
        }

    # --- Private node implementations ---

    def _ta_confirms(self, action: TradeAction, ta: TAContext) -> bool:
        """Check if TA indicators confirm the momentum direction.

        Buy on momentum confirmation: RSI already recovering, MACD turning.
        Sell on momentum exhaustion: RSI already weakening.
        This is momentum-following, NOT mean-reversion.
        """
        if action == TradeAction.BUY:
            if ta.rsi < self.buy_rsi_min:
                return False
            if self.buy_macd_positive and ta.macd_hist <= 0:
                return False
            return True
        elif action == TradeAction.SELL:
            if ta.rsi > self.sell_rsi_max:
                return False
            return True
        return True

    def _transition_direction(self, transition: str | None) -> str | None:
        """Map transition type to directional hint."""
        if transition is None:
            return None
        if transition in BUY_TRANSITIONS:
            return "BUY"
        if transition in SELL_TRANSITIONS:
            return "SELL"
        return None

    def _history_guard(self) -> RejectionReason | None:
        """Check all history-based guards. Returns rejection reason or None."""
        recent = list(self._history)

        # Cooldown: minimum candles since last trade
        for event in reversed(recent):
            if event.action in ("BUY", "SELL"):
                if self._step - event.step < self.cooldown_candles:
                    return RejectionReason.COOLDOWN
                break

        # Rate limit: max trades in window
        window_start = self._step - self.rate_window
        trades_in_window = sum(
            1 for e in recent
            if e.step >= window_start and e.action in ("BUY", "SELL")
        )
        if trades_in_window >= self.max_trades_per_window:
            return RejectionReason.RATE_LIMIT

        # Streak suppression: gate firing too consistently
        consecutive_fires = 0
        for event in reversed(recent):
            if event.gate_fired:
                consecutive_fires += 1
            else:
                break
        if consecutive_fires >= self.streak_suppress:
            return RejectionReason.STREAK_SUPPRESSED

        # Conviction: require multiple gate fires in recent window
        conviction_start = self._step - self.conviction_window
        fires_in_window = sum(
            1 for e in recent
            if e.step >= conviction_start and e.gate_fired
        )
        if fires_in_window < self.conviction_fires:
            return RejectionReason.INSUFFICIENT_CONVICTION

        return None

    def _risk_gate(self) -> RejectionReason | None:
        """Check risk limits."""
        # Drawdown check
        if self._peak_equity > 0:
            drawdown = 1.0 - self._current_equity / self._peak_equity
            if drawdown > self.max_drawdown:
                return RejectionReason.RISK_EXCEEDED

        # Loss streak check
        if self._consecutive_losses >= self.max_loss_streak:
            return RejectionReason.RISK_EXCEEDED

        return None

    def _record(self, gate_fired: bool, action: str):
        """Record event in history ring buffer."""
        self._history.append(_HistoryEvent(
            step=self._step, gate_fired=gate_fired, action=action,
        ))

    def _update_pending(self, action: str):
        """Update the last history entry (PENDING → final action)."""
        if self._history:
            last = self._history[-1]
            self._history[-1] = _HistoryEvent(
                step=last.step, gate_fired=last.gate_fired, action=action,
            )
