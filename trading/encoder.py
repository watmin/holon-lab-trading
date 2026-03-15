"""Encode OHLCV windows into hypervectors via holon's walkable interface.

This is the bridge between market data and algebraic geometry. Uses
HolonClient.encode_walkable() with LinearScale/LogScale wrappers for
structure-preserving encoding.

Field attribution (HOLON_CONTEXT.md):
  After OnlineSubspace.anomalous_component(vec) returns the out-of-manifold
  component, we identify which indicator fields drove the surprise by measuring
  abs(cosine(anomalous, role_atom)) for each field's role atom.
  Role atoms are retrieved via encoder.leaf_binding(scale_wrapper, field_name).
  Higher value → that field contributed more to the anomaly.
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

# Canonical scale wrapper instances for role-atom lookup (value is arbitrary).
_LOG_PROBE   = LogScale(1.0)
_LINEAR_PROBE = LinearScale(1.0)


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
        # Cache of field → role atom (computed once per field, deterministic)
        self._role_atoms: dict[str, np.ndarray] = {}

    def encode(self, df: pd.DataFrame) -> np.ndarray:
        """Encode a DataFrame window into a hypervector."""
        feats = self.factory.compute(df)
        returns = self.factory.compute_returns(df)
        walkable = self._build_walkable(feats, returns)
        return self.client.encode_walkable(walkable)

    def encode_with_walkable(
        self, df: pd.DataFrame
    ) -> tuple[np.ndarray, dict[str, Any]]:
        """Encode and return both the vector and the walkable dict.

        Used by the harness to build surprise profiles without recomputing.
        """
        feats = self.factory.compute(df)
        returns = self.factory.compute_returns(df)
        walkable = self._build_walkable(feats, returns)
        vec = self.client.encode_walkable(walkable)
        return vec, walkable

    def build_surprise_profile(
        self, anomalous: np.ndarray
    ) -> dict[str, float]:
        """Attribute an anomalous component to specific indicator fields.

        Uses abs(cosine(anomalous, role_atom)) per field.
        Role atoms are retrieved via encoder.leaf_binding(scale_type, field_name).

        Args:
            anomalous: out-of-manifold component from OnlineSubspace.anomalous_component()

        Returns:
            dict mapping field_name → surprise score in [0, 1].
            Higher = that field contributed more to the anomaly.
            Only includes currently active (non-gated) fields.
        """
        profile: dict[str, float] = {}
        anomalous_f = anomalous.astype(float)
        anorm = float(np.linalg.norm(anomalous_f))
        if anorm == 0:
            return profile

        enc = self.client.encoder

        for field in _LOG_FIELDS | _LINEAR_FIELDS:
            weight = self.feature_weights.get(field, 1.0)
            if weight <= 0.01:
                continue  # gated field — exclude from profile

            role = self._get_role_atom(enc, field)
            if role is None:
                continue

            role_f = role.astype(float)
            rnorm = float(np.linalg.norm(role_f))
            if rnorm == 0:
                continue

            sim = abs(float(np.dot(anomalous_f, role_f)) / (anorm * rnorm))
            profile[field] = sim

        return profile

    def update_weights(self, weights: dict[str, float]) -> None:
        """Hot-update feature weights (called by Darwinism / Critic)."""
        self.feature_weights.update(weights)
        # Clear role atom cache so newly gated fields re-check on next call
        self._role_atoms.clear()

    def _get_role_atom(self, enc, field: str) -> np.ndarray | None:
        """Return (cached) role atom for a field, or None on error."""
        if field in self._role_atoms:
            return self._role_atoms[field]
        try:
            probe = _LOG_PROBE if field in _LOG_FIELDS else _LINEAR_PROBE
            atom = enc.leaf_binding(probe, field)
            self._role_atoms[field] = atom
            return atom
        except Exception:
            return None

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
