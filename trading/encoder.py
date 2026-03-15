"""Encode OHLCV windows into hypervectors via holon's walkable interface.

This is the bridge between market data and algebraic geometry. Uses
HolonClient.encode_walkable() with LinearScale/LogScale wrappers for
structure-preserving encoding.

Field attribution (HOLON_CONTEXT.md):
  After OnlineSubspace.anomalous_component(vec) returns the out-of-manifold
  component, we identify which indicator fields drove the surprise by measuring
  abs(cosine(anomalous, leaf_binding)) per field.
  leaf_binding(actual_value, field_name) gives the EXACT binding vector placed
  into the encoded hypervector — passing actual field values (not a probe) is
  required for precise attribution. Higher cosine → that field contributed more.
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
        self,
        anomalous: np.ndarray,
        walkable: dict[str, Any] | None = None,
    ) -> dict[str, float]:
        """Attribute an anomalous component to specific indicator fields.

        Uses abs(cosine(anomalous, leaf_binding(value, field))) per field.
        Passing the walkable dict gives exact attribution — leaf_binding with
        the actual encoded value matches what went into the hypervector exactly.
        Without walkable, falls back to a unit-value probe (less precise).

        Args:
            anomalous: out-of-manifold component from OnlineSubspace.anomalous_component()
            walkable: the walkable dict returned by encode_with_walkable() — used
                      to pass actual field values to leaf_binding for exact attribution.

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

            # Use actual field value from walkable for exact leaf_binding;
            # fall back to unit probe if walkable unavailable.
            field_value = walkable.get(field) if walkable else None
            binding = self._get_leaf_binding(enc, field, field_value)
            if binding is None:
                continue

            binding_f = binding.astype(float)
            bnorm = float(np.linalg.norm(binding_f))
            if bnorm == 0:
                continue

            sim = abs(float(np.dot(anomalous_f, binding_f)) / (anorm * bnorm))
            profile[field] = sim

        return profile

    def update_weights(self, weights: dict[str, float]) -> None:
        """Hot-update feature weights (called by Darwinism / Critic)."""
        self.feature_weights.update(weights)
        # Clear role atom cache so newly gated fields re-check on next call
        self._role_atoms.clear()

    def _get_leaf_binding(
        self, enc, field: str, value: Any | None = None
    ) -> np.ndarray | None:
        """Return the leaf binding vector for a field, or None on error.

        If value is provided, uses it directly (exact attribution).
        If value is None, falls back to a unit probe (approximate, cached).
        """
        if value is not None:
            # Exact: use the actual encoded value — not cached since values vary
            try:
                return enc.leaf_binding(value, field)
            except Exception:
                pass  # fall through to probe fallback

        # Probe fallback (cached per field — deterministic for fixed probe)
        if field in self._role_atoms:
            return self._role_atoms[field]
        try:
            probe = LogScale(1.0) if field in _LOG_FIELDS else LinearScale(1.0)
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
