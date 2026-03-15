"""Encode OHLCV windows into hypervectors via holon's walkable interface.

This is the bridge between market data and algebraic geometry. Uses
HolonClient.encode_walkable() with LinearScale/LogScale wrappers for
structure-preserving encoding.
"""

from __future__ import annotations

from typing import Any

import numpy as np
import pandas as pd

from holon import HolonClient
from holon.kernel.walkable import LinearScale, LogScale

from .features import TechnicalFeatureFactory

# Fields that represent ratios or multiplicative quantities → log encoding.
_LOG_FIELDS = {"vol_regime", "atr", "price", "bb_upper", "bb_lower"}

# Fields that represent differences or additive quantities → linear encoding.
_LINEAR_FIELDS = {
    "sma_short", "sma_long", "sma_cross",
    "bb_width", "macd_line", "macd_signal", "macd_hist",
    "rsi", "adx", "return_1",
    "hour_sin", "hour_cos", "dow_sin", "dow_cos",
}


class OHLCVEncoder:
    """Encode a DataFrame window into a single hypervector.

    Uses TechnicalFeatureFactory for indicator computation, then wraps each
    field in the appropriate scalar type (LinearScale or LogScale) before
    passing the whole structure through encode_walkable.

    Feature weights are multiplicative: a weight of 0.0 effectively removes
    a field from the encoding. The geometry stays valid because we're just
    scaling the scalar input.
    """

    def __init__(
        self,
        client: HolonClient,
        feature_weights: dict[str, float] | None = None,
        factory: TechnicalFeatureFactory | None = None,
    ):
        self.client = client
        self.factory = factory or TechnicalFeatureFactory()
        self.feature_weights = feature_weights or {
            field: 1.0 for field in (_LOG_FIELDS | _LINEAR_FIELDS)
        }

    def encode(self, df: pd.DataFrame) -> np.ndarray:
        """Encode a DataFrame window into a hypervector."""
        feats = self.factory.compute(df)
        returns = self.factory.compute_returns(df)

        walkable = self._build_walkable(feats, returns)
        return self.client.encode_walkable(walkable)

    def update_weights(self, weights: dict[str, float]) -> None:
        """Hot-update feature weights (called by Darwinism / Critic)."""
        self.feature_weights.update(weights)

    def _build_walkable(
        self, feats: dict[str, float], returns: list[float]
    ) -> dict[str, Any]:
        """Build a walkable dict from features + weights."""
        walkable: dict[str, Any] = {}

        for field, value in feats.items():
            weight = self.feature_weights.get(field, 1.0)
            if weight <= 0.01:
                continue

            scaled = value * weight

            if field in _LOG_FIELDS:
                walkable[field] = LogScale(max(scaled, 1e-9))
            elif field in _LINEAR_FIELDS:
                walkable[field] = LinearScale(scaled)
            # else: skip unknown fields

        # Recent returns as a list (encoder will use sequence mode)
        if returns:
            walkable["recent_returns"] = [LinearScale(r) for r in returns]

        return walkable
