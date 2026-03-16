"""Encode OHLCV windows into striped hypervectors via holon's walkable interface.

This is the bridge between market data and algebraic geometry. Uses
client.encoder.encode_walkable_striped() with deeply nested per-candle structure
preserving temporal patterns that aggregate statistics cannot distinguish.

Field attribution (HOLON_CONTEXT.md):
  After StripedSubspace.anomalous_component(stripe_vecs, hot_stripe) returns the
  out-of-manifold component for a specific stripe, we identify which indicator
  fields drove the surprise by measuring abs(cosine(anomalous, leaf_binding))
  per field. leaf_binding(actual_value, field_path) gives the EXACT binding
  vector placed into the hypervector — passing actual field values (not a probe)
  is required for precise attribution. Higher cosine → that field contributed more.
"""

from __future__ import annotations

from typing import Any

import numpy as np
import pandas as pd

from holon import HolonClient
from holon.kernel.walkable import LinearScale, LogScale

from .features import TechnicalFeatureFactory


class OHLCVEncoder:
    """Encode a DataFrame window into striped hypervectors with per-candle nested structure.

    Uses TechnicalFeatureFactory for indicator computation, then builds a deeply
    nested walkable dict with full OHLCV + indicators per candle in the window,
    plus a single time block. Passed through encode_walkable_striped.

    Feature weights are not currently applied at the walkable level (the nested
    structure makes field-by-field gating more complex). They are used only for
    the surprise profile attribution step. Full weight gating will be added in a
    follow-up once the geometry is validated on real data.
    """

    # Module constants — single source of truth for all consumers
    DEFAULT_DIM = 1024
    N_STRIPES = 8
    WINDOW_CANDLES = 12
    LOOKBACK_CANDLES = 200

    def __init__(
        self,
        client: HolonClient,
        window_candles: int = WINDOW_CANDLES,
        n_stripes: int = N_STRIPES,
        feature_weights: dict[str, float] | None = None,
        factory: TechnicalFeatureFactory | None = None,
    ):
        self.client = client
        self.window_candles = window_candles
        self.n_stripes = n_stripes
        self.factory = factory or TechnicalFeatureFactory()
        self.feature_weights = feature_weights or {}
        # Cache of field_path → role atom (unit-probe, deterministic)
        self._role_atoms: dict[str, np.ndarray] = {}

    def encode(self, df: pd.DataFrame) -> list[np.ndarray]:
        """Encode a DataFrame window into striped hypervectors."""
        walkable = self._build_window_walkable(df)
        return self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.n_stripes)

    def encode_from_precomputed(self, df_ind: pd.DataFrame) -> list[np.ndarray]:
        """Encode from a DataFrame that already has all indicator columns.

        Skips indicator computation (saves ~15ms per call). df_ind must contain at
        least window_candles rows with all indicator columns already present.
        """
        walkable = self._build_walkable_from_precomputed(df_ind)
        return self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.n_stripes)

    def encode_with_walkable(
        self, df: pd.DataFrame
    ) -> tuple[list[np.ndarray], dict[str, Any]]:
        """Encode and return both the stripe vectors and the walkable dict.

        Used by the harness to build surprise profiles without recomputing.
        """
        walkable = self._build_window_walkable(df)
        stripe_vecs = self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.n_stripes)
        return stripe_vecs, walkable

    def build_surprise_profile(
        self,
        anomalous: np.ndarray,
        hot_stripe_idx: int,
        walkable: dict[str, Any],
    ) -> dict[str, float]:
        """Attribute an anomalous component to specific indicator fields in a stripe.

        Walks the walkable dict, collects all leaf field paths, determines which
        stripe each path hashes to (via holon's FNV-1a field_stripe), and
        measures abs(cosine(anomalous, leaf_binding(value, path))) for all
        fields that land in the hot stripe.

        Args:
            anomalous: out-of-manifold component from StripedSubspace.anomalous_component()
            hot_stripe_idx: stripe index with highest residual
            walkable: the walkable dict returned by encode_with_walkable()

        Returns:
            dict mapping field_path → surprise score in [0, 1].
            Higher = that field contributed more to the anomaly.
            Only includes fields that hash to hot_stripe_idx.
        """
        profile: dict[str, float] = {}
        anomalous_f = anomalous.astype(float)
        anorm = float(np.linalg.norm(anomalous_f))
        if anorm == 0:
            return profile

        enc = self.client.encoder
        all_field_paths = self._collect_field_paths(walkable)

        for field_path in all_field_paths:
            # Only process fields that hash to the hot stripe
            try:
                stripe = enc.field_stripe(field_path, self.n_stripes)
            except Exception:
                continue
            if stripe != hot_stripe_idx:
                continue

            # Get the actual scale-wrapped value for exact attribution
            raw_value = self._get_nested_value(walkable, field_path)
            if raw_value is None:
                continue

            binding = self._get_leaf_binding(enc, field_path, raw_value)
            if binding is None:
                continue

            binding_f = binding.astype(float)
            bnorm = float(np.linalg.norm(binding_f))
            if bnorm == 0:
                continue

            sim = abs(float(np.dot(anomalous_f, binding_f)) / (anorm * bnorm))
            profile[field_path] = sim

        return profile

    def update_weights(self, weights: dict[str, float]) -> None:
        """Hot-update feature weights (called by Darwinism / Critic)."""
        self.feature_weights.update(weights)
        # Clear role atom cache so re-evaluated on next call
        self._role_atoms.clear()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _build_window_walkable(self, df: pd.DataFrame) -> dict[str, Any]:
        """Build the deeply nested per-candle window walkable dict.

        Requires at least LOOKBACK_CANDLES rows (for SMA200 etc). Encodes
        only the last window_candles rows as t0..t(N-1), plus a single
        time block from the last candle's timestamp.
        """
        min_rows = self.LOOKBACK_CANDLES + self.window_candles
        if len(df) < min_rows:
            raise ValueError(
                f"Need at least {min_rows} candles ({self.LOOKBACK_CANDLES} lookback + "
                f"{self.window_candles} encode window), got {len(df)}"
            )

        df_ind = self.factory.compute_indicators(df)

        if len(df_ind) < self.window_candles:
            raise ValueError(
                f"After indicator computation only {len(df_ind)} rows remain "
                f"(need {self.window_candles})"
            )

        walkable: dict[str, Any] = {}

        for i in range(self.window_candles):
            row_idx = len(df_ind) - self.window_candles + i
            candle_raw = self.factory.compute_candle_row(df_ind, row_idx)
            walkable[f"t{i}"] = self._wrap_candle(candle_raw)

        # Time features once per window — not per candle (avoids 12x identical bindings)
        if "timestamp" in df_ind.columns:
            last_ts = pd.to_datetime(df_ind["timestamp"].iloc[-1])
        else:
            last_ts = pd.Timestamp.now()

        walkable["time"] = {
            "hour_sin": LinearScale(float(np.sin(2 * np.pi * last_ts.hour / 24))),
            "hour_cos": LinearScale(float(np.cos(2 * np.pi * last_ts.hour / 24))),
            "dow_sin": LinearScale(float(np.sin(2 * np.pi * last_ts.dayofweek / 7))),
            "dow_cos": LinearScale(float(np.cos(2 * np.pi * last_ts.dayofweek / 7))),
        }

        return walkable

    def _build_walkable_from_precomputed(self, df_ind: pd.DataFrame) -> dict[str, Any]:
        """Build the walkable dict from a DataFrame that already has all indicator columns.

        df_ind must already contain indicator columns (sma20, rsi, etc.) and at least
        window_candles rows. Skips compute_indicators — use this when indicators have
        been computed once across the full dataset and df_ind is a slice of that result.
        """
        if len(df_ind) < self.window_candles:
            raise ValueError(
                f"Need at least {self.window_candles} rows in pre-indicator df, "
                f"got {len(df_ind)}"
            )

        walkable: dict[str, Any] = {}

        for i in range(self.window_candles):
            row_idx = len(df_ind) - self.window_candles + i
            candle_raw = self.factory.compute_candle_row(df_ind, row_idx)
            walkable[f"t{i}"] = self._wrap_candle(candle_raw)

        # Time features from last candle
        ts_col = "ts" if "ts" in df_ind.columns else "timestamp"
        if ts_col in df_ind.columns:
            last_ts = pd.to_datetime(df_ind[ts_col].iloc[-1])
        else:
            last_ts = pd.Timestamp.now()

        walkable["time"] = {
            "hour_sin": LinearScale(float(np.sin(2 * np.pi * last_ts.hour / 24))),
            "hour_cos": LinearScale(float(np.cos(2 * np.pi * last_ts.hour / 24))),
            "dow_sin": LinearScale(float(np.sin(2 * np.pi * last_ts.dayofweek / 7))),
            "dow_cos": LinearScale(float(np.cos(2 * np.pi * last_ts.dayofweek / 7))),
        }

        return walkable

    def _wrap_candle(self, raw: dict[str, Any]) -> dict[str, Any]:
        """Wrap raw float values in the appropriate Scale type per the schema."""
        return {
            "ohlcv": {
                "open":  LogScale(max(raw["ohlcv"]["open"],  1e-9)),
                "high":  LogScale(max(raw["ohlcv"]["high"],  1e-9)),
                "low":   LogScale(max(raw["ohlcv"]["low"],   1e-9)),
                "close": LogScale(max(raw["ohlcv"]["close"], 1e-9)),
            },
            "vol":  LogScale(max(raw["vol"], 1e-9)),
            "atr":  LogScale(max(raw["atr"], 1e-9)),
            "rsi":  LinearScale(raw["rsi"]),
            "ret":  LinearScale(raw["ret"]),
            "sma": {
                "s20":  LogScale(max(raw["sma"]["s20"],  1e-9)),
                "s50":  LogScale(max(raw["sma"]["s50"],  1e-9)),
                "s200": LogScale(max(raw["sma"]["s200"], 1e-9)),
            },
            "macd": {
                "line":   LinearScale(raw["macd"]["line"]),
                "signal": LinearScale(raw["macd"]["signal"]),
                "hist":   LinearScale(raw["macd"]["hist"]),
            },
            "bb": {
                "upper": LogScale(max(raw["bb"]["upper"], 1e-9)),
                "lower": LogScale(max(raw["bb"]["lower"], 1e-9)),
                "width": LinearScale(raw["bb"]["width"]),
            },
            "dmi": {
                "plus":  LinearScale(raw["dmi"]["plus"]),
                "minus": LinearScale(raw["dmi"]["minus"]),
                "adx":   LinearScale(raw["dmi"]["adx"]),
            },
        }

    def _collect_field_paths(self, walkable: dict[str, Any], prefix: str = "") -> list[str]:
        """Recursively collect all leaf field paths using dot notation."""
        paths: list[str] = []
        for key, value in walkable.items():
            current = f"{prefix}.{key}" if prefix else key
            if isinstance(value, dict):
                paths.extend(self._collect_field_paths(value, current))
            else:
                paths.append(current)
        return paths

    def _get_nested_value(self, walkable: dict[str, Any], field_path: str) -> Any:
        """Extract a nested scale-wrapped value by dot-notation path."""
        keys = field_path.split(".")
        current: Any = walkable
        for key in keys:
            if isinstance(current, dict) and key in current:
                current = current[key]
            else:
                return None
        return current

    def _get_leaf_binding(self, enc, field_path: str, value: Any) -> np.ndarray | None:
        """Return the leaf binding vector for a field path and scale-wrapped value."""
        try:
            return enc.leaf_binding(value, field_path)
        except Exception:
            pass

        # Fallback: unit probe (cached, deterministic)
        if field_path in self._role_atoms:
            return self._role_atoms[field_path]
        try:
            probe = LogScale(1.0) if self._is_log_field(field_path) else LinearScale(1.0)
            atom = enc.leaf_binding(probe, field_path)
            self._role_atoms[field_path] = atom
            return atom
        except Exception:
            return None

    def _is_log_field(self, field_path: str) -> bool:
        """Determine if a field path should use log scaling."""
        log_suffixes = {
            "ohlcv.open", "ohlcv.high", "ohlcv.low", "ohlcv.close",
            "vol", "atr", "bb.upper", "bb.lower",
            "sma.s20", "sma.s50", "sma.s200",
        }
        for suffix in log_suffixes:
            if field_path.endswith(suffix) or field_path == suffix:
                return True
        return False
