"""HolonGate — regime classification with transition detection.

Holon decides *when* to pay attention. The tree decides *what to do*.

The gate classifies the current market window into a regime (TREND_UP,
TREND_DOWN, CONSOLIDATION, VOLATILE) using StripedSubspace engrams.
When the classified regime changes, a GateSignal fires with the
transition type, which the RuleTree evaluates.

Regime classification is pure present-tense description — no prediction.
A transition from TREND_DOWN to CONSOLIDATION means "the downtrend just
stopped." The tree decides if that's a BUY opportunity.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from enum import Enum

import numpy as np

from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

from .features import TechnicalFeatureFactory


class Regime(str, Enum):
    TREND_UP = "TREND_UP"
    TREND_DOWN = "TREND_DOWN"
    CONSOLIDATION = "CONSOLIDATION"
    VOLATILE = "VOLATILE"
    UNKNOWN = "UNKNOWN"


@dataclass
class GateSignal:
    """Output of the HolonGate — passed to the RuleTree."""
    fired: bool
    current_regime: Regime
    previous_regime: Regime | None
    transition_type: str | None  # e.g. "TREND_DOWN → CONSOLIDATION"
    magnitude: float  # margin between best and second-best regime residual
    residuals: dict[str, float] = field(default_factory=dict)
    regime_tenure: int = 0  # how many candles the previous regime held


class HolonGate:
    """Regime classifier using StripedSubspace engrams.

    One subspace per regime, trained on labeled windows. Each candle,
    the gate scores the current window against all regime subspaces and
    reports which regime is the best fit. When the best-fit regime changes,
    it fires a GateSignal.

    The gate tracks regime tenure (how long the previous regime held) to
    help the tree filter noisy transitions (short tenures = chatter).
    """

    DIM = 1024
    K = 32
    N_STRIPES = 32
    WINDOW = 12  # 1 hour at 5-minute candles

    def __init__(
        self,
        client: HolonClient,
        regime_subspaces: dict[str, StripedSubspace] | None = None,
        min_tenure: int = 1,
    ):
        self.client = client
        self.factory = TechnicalFeatureFactory()
        self.regime_subspaces: dict[str, StripedSubspace] = regime_subspaces or {}
        self.min_tenure = min_tenure

        self._current_regime: Regime = Regime.UNKNOWN
        self._tenure: int = 0
        self._ready = bool(self.regime_subspaces)

    @property
    def ready(self) -> bool:
        return self._ready and len(self.regime_subspaces) >= 2

    @property
    def current_regime(self) -> Regime:
        return self._current_regime

    def train_regimes(self, df_ind, labels, n_train: int = 200, rng=None):
        """Train regime subspaces from labeled data.

        Args:
            df_ind: DataFrame with computed indicators
            labels: array of regime labels aligned with df_ind
            n_train: max samples per regime
            rng: numpy random generator for sampling
        """
        if rng is None:
            rng = np.random.default_rng(42)

        regime_names = [r.value for r in Regime if r not in (Regime.UNKNOWN,)]

        for regime in regime_names:
            indices = [i for i in range(self.WINDOW, len(df_ind)) if labels[i] == regime]
            if len(indices) < 20:
                continue

            sample = rng.choice(indices, size=min(n_train + 50, len(indices)), replace=False)
            ss = StripedSubspace(dim=self.DIM, k=self.K, n_stripes=self.N_STRIPES)
            count = 0
            for idx in sample:
                try:
                    v = self._encode_window(df_ind, idx)
                    if v:
                        ss.update(v)
                        count += 1
                except Exception:
                    pass
                if count >= n_train:
                    break

            if count >= 20:
                self.regime_subspaces[regime] = ss

        self._ready = len(self.regime_subspaces) >= 2

    def check(self, df_ind, idx: int) -> GateSignal:
        """Score the current window against all regime subspaces.

        Returns a GateSignal. The signal fires when the classified
        regime changes AND the previous regime had sufficient tenure.
        """
        if not self.ready:
            return GateSignal(
                fired=False, current_regime=Regime.UNKNOWN,
                previous_regime=None, transition_type=None,
                magnitude=0.0, regime_tenure=0,
            )

        v = self._encode_window(df_ind, idx)
        if v is None:
            return GateSignal(
                fired=False, current_regime=self._current_regime,
                previous_regime=None, transition_type=None,
                magnitude=0.0, regime_tenure=self._tenure,
            )

        residuals = {}
        for regime, ss in self.regime_subspaces.items():
            residuals[regime] = ss.residual(v)

        best_regime_str = min(residuals, key=residuals.get)
        best_regime = Regime(best_regime_str)
        best_resid = residuals[best_regime_str]

        sorted_resids = sorted(residuals.values())
        margin = sorted_resids[1] - sorted_resids[0] if len(sorted_resids) > 1 else 0.0

        previous = self._current_regime
        is_transition = (
            previous != Regime.UNKNOWN
            and best_regime != previous
        )
        fired = is_transition and self._tenure >= self.min_tenure

        transition_type = None
        tenure_at_transition = self._tenure
        if is_transition:
            transition_type = f"{previous.value} → {best_regime.value}"
            self._tenure = 1
        else:
            self._tenure += 1

        self._current_regime = best_regime

        return GateSignal(
            fired=fired,
            current_regime=best_regime,
            previous_regime=previous if is_transition else None,
            transition_type=transition_type if fired else None,
            magnitude=margin,
            residuals=residuals,
            regime_tenure=tenure_at_transition if is_transition else self._tenure,
        )

    def precompute_features(self, df_ind) -> dict[str, np.ndarray]:
        """Precompute all feature arrays from df_ind for fast window encoding.

        Call once per period, then pass the result to _encode_window_fast.
        Eliminates per-candle DataFrame row access in the hot loop.
        """
        n = len(df_ind)
        o = df_ind["open"].values
        h = df_ind["high"].values
        l = df_ind["low"].values
        c = df_ind["close"].values
        rng = np.maximum(h - l, 1e-10)

        return {
            "open_r": df_ind["open_r"].values if "open_r" in df_ind.columns else np.zeros(n),
            "high_r": df_ind["high_r"].values if "high_r" in df_ind.columns else np.zeros(n),
            "low_r": df_ind["low_r"].values if "low_r" in df_ind.columns else np.zeros(n),
            "vol_r": df_ind["vol_r"].values if "vol_r" in df_ind.columns else np.zeros(n),
            "rsi": df_ind["rsi"].values if "rsi" in df_ind.columns else np.full(n, 50.0),
            "ret": df_ind["ret"].values if "ret" in df_ind.columns else np.zeros(n),
            "sma20_r": df_ind["sma20_r"].values if "sma20_r" in df_ind.columns else np.zeros(n),
            "sma50_r": df_ind["sma50_r"].values if "sma50_r" in df_ind.columns else np.zeros(n),
            "macd_hist": df_ind["macd_hist_r"].values if "macd_hist_r" in df_ind.columns else np.zeros(n),
            "bb_width": df_ind["bb_width"].values if "bb_width" in df_ind.columns else np.zeros(n),
            "adx": df_ind["adx"].values if "adx" in df_ind.columns else np.zeros(n),
            "body": (c - o) / rng,
            "upper_wick": (h - np.maximum(o, c)) / rng,
            "lower_wick": (np.minimum(o, c) - l) / rng,
            "close_pos": (c - l) / rng,
        }

    def _encode_window_fast(self, features: dict[str, np.ndarray], idx: int):
        """Encode a window using precomputed feature arrays. ~10x faster."""
        start = int(idx) - self.WINDOW + 1
        if start < 0:
            return None

        walkable = {}
        for name in [
            "open_r", "high_r", "low_r", "vol_r", "rsi", "ret",
            "sma20_r", "sma50_r", "macd_hist", "bb_width", "adx",
            "body", "upper_wick", "lower_wick", "close_pos",
        ]:
            arr = features[name]
            walkable[name] = WalkableSpread(
                [LinearScale(float(arr[start + i])) for i in range(self.WINDOW)]
            )

        return self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.N_STRIPES)

    def check_fast(
        self, features: dict[str, np.ndarray], idx: int, adaptive: bool = False,
    ) -> GateSignal:
        """Same as check() but uses precomputed feature arrays.

        adaptive: if True, update the winning regime's subspace after scoring.
                  Score first, update second — core Holon principle.
        """
        if not self.ready:
            return GateSignal(
                fired=False, current_regime=Regime.UNKNOWN,
                previous_regime=None, transition_type=None,
                magnitude=0.0, regime_tenure=0,
            )

        v = self._encode_window_fast(features, idx)
        if v is None:
            return GateSignal(
                fired=False, current_regime=self._current_regime,
                previous_regime=None, transition_type=None,
                magnitude=0.0, regime_tenure=self._tenure,
            )

        # Score first
        residuals = {}
        for regime, ss in self.regime_subspaces.items():
            residuals[regime] = ss.residual(v)

        best_regime_str = min(residuals, key=residuals.get)
        best_regime = Regime(best_regime_str)

        # Update second — winning subspace absorbs new geometry
        if adaptive:
            self.regime_subspaces[best_regime_str].update(v)

        sorted_resids = sorted(residuals.values())
        margin = sorted_resids[1] - sorted_resids[0] if len(sorted_resids) > 1 else 0.0

        previous = self._current_regime
        is_transition = (
            previous != Regime.UNKNOWN
            and best_regime != previous
        )
        fired = is_transition and self._tenure >= self.min_tenure

        transition_type = None
        tenure_at_transition = self._tenure
        if is_transition:
            transition_type = f"{previous.value} → {best_regime.value}"
            self._tenure = 1
        else:
            self._tenure += 1

        self._current_regime = best_regime

        return GateSignal(
            fired=fired,
            current_regime=best_regime,
            previous_regime=previous if is_transition else None,
            transition_type=transition_type if fired else None,
            magnitude=margin,
            residuals=residuals,
            regime_tenure=tenure_at_transition if is_transition else self._tenure,
        )

    def _encode_window(self, df_ind, idx: int):
        """Encode a window ending at idx as striped hypervectors."""
        start = int(idx) - self.WINDOW + 1
        if start < 0 or int(idx) >= len(df_ind):
            return None

        candles = []
        for i in range(self.WINDOW):
            try:
                raw = self.factory.compute_candle_row(df_ind, start + i)
                candles.append(raw)
            except Exception:
                return None

        walkable = {}
        for name, extractor in [
            ("open_r",    lambda c: c["ohlcv"]["open_r"]),
            ("high_r",    lambda c: c["ohlcv"]["high_r"]),
            ("low_r",     lambda c: c["ohlcv"]["low_r"]),
            ("vol_r",     lambda c: c["vol_r"]),
            ("rsi",       lambda c: c["rsi"]),
            ("ret",       lambda c: c["ret"]),
            ("sma20_r",   lambda c: c["sma"]["s20_r"]),
            ("sma50_r",   lambda c: c["sma"]["s50_r"]),
            ("macd_hist", lambda c: c["macd"]["hist_r"]),
            ("bb_width",  lambda c: c["bb"]["width"]),
            ("adx",       lambda c: c["dmi"]["adx"]),
        ]:
            walkable[name] = WalkableSpread([LinearScale(extractor(c)) for c in candles])

        body_vals, upper_vals, lower_vals, cpos_vals = [], [], [], []
        for i in range(self.WINDOW):
            row = df_ind.iloc[start + i]
            o, h, l, c = row["open"], row["high"], row["low"], row["close"]
            rng = max(h - l, 1e-10)
            body_vals.append(LinearScale((c - o) / rng))
            upper_vals.append(LinearScale((h - max(o, c)) / rng))
            lower_vals.append(LinearScale((min(o, c) - l) / rng))
            cpos_vals.append(LinearScale((c - l) / rng))

        walkable["body"] = WalkableSpread(body_vals)
        walkable["upper_wick"] = WalkableSpread(upper_vals)
        walkable["lower_wick"] = WalkableSpread(lower_vals)
        walkable["close_pos"] = WalkableSpread(cpos_vals)

        return self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.N_STRIPES)

    def reset(self):
        """Reset gate state (for backtesting across periods)."""
        self._current_regime = Regime.UNKNOWN
        self._tenure = 0


def label_regimes(df_ind, window: int = 12):
    """Label each candle with a regime based on backward-looking price action.

    Pure mechanical labeling — no future leak. Labels are based on the
    window ENDING at this candle.

    Args:
        df_ind: DataFrame with computed indicators (needs close, atr columns)
        window: lookback window in candles

    Returns:
        numpy array of string labels aligned with df_ind index
    """
    n = len(df_ind)
    labels = np.full(n, "UNKNOWN", dtype=object)

    close = df_ind["close"].values
    atr = df_ind["atr"].values if "atr" in df_ind.columns else np.ones(n)

    for i in range(window, n):
        start = i - window
        window_close = close[start:i + 1]
        window_atr = atr[start:i + 1]

        ret_total = (window_close[-1] / window_close[0] - 1) * 100
        path_returns = np.diff(window_close) / window_close[:-1] * 100

        if ret_total > 0:
            monotonicity = np.mean(path_returns > 0)
        else:
            monotonicity = np.mean(path_returns < 0)

        mean_atr_r = np.mean(window_atr) / np.mean(window_close)

        window_range = (np.max(window_close) - np.min(window_close)) / np.mean(window_close)

        if mean_atr_r > 0.015:
            labels[i] = "VOLATILE"
        elif abs(ret_total) > 0.8 and monotonicity > 0.6:
            labels[i] = "TREND_UP" if ret_total > 0 else "TREND_DOWN"
        elif window_range < 0.005:
            labels[i] = "CONSOLIDATION"
        elif abs(ret_total) < 0.3 and window_range < 0.015:
            labels[i] = "CONSOLIDATION"
        elif ret_total > 0.3:
            labels[i] = "TREND_UP"
        elif ret_total < -0.3:
            labels[i] = "TREND_DOWN"
        else:
            labels[i] = "CONSOLIDATION"

    return labels
