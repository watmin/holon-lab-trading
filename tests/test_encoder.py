"""Unit and integration tests for OHLCVEncoder.

Covers:
- Output vector has correct dimensionality
- Determinism: same window → identical vector
- Structural similarity: similar market states → high cosine similarity
- Structural dissimilarity: different regimes → low cosine similarity
- Zero-weighted field excluded from walkable (weight gating)
- update_weights() changes encoding output
- Short window (NaN fields) does not crash encoder
- Walkable structure contains expected field keys
- All vector values are finite (no NaN, no inf)

Integration with holon:
- encode_walkable is called on a valid dict (not tested by mocking;
  we call the real holon API to catch any API drift early)
"""

from __future__ import annotations

import math

import numpy as np
import pytest

from tests.conftest import make_flat_ohlcv, make_volatile_ohlcv, make_trending_ohlcv
from trading.encoder import OHLCVEncoder, _LOG_FIELDS, _LINEAR_FIELDS


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def encoder(holon_client):
    return OHLCVEncoder(holon_client)


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)


# ---------------------------------------------------------------------------
# Basic shape and validity
# ---------------------------------------------------------------------------

class TestVectorShape:
    def test_output_shape_matches_client_dim(self, encoder, holon_client, flat_df):
        vec = encoder.encode(flat_df)
        assert vec.shape == (holon_client.encoder.vector_manager.dimensions,)

    def test_output_is_numpy_array(self, encoder, flat_df):
        vec = encoder.encode(flat_df)
        assert isinstance(vec, np.ndarray)

    def test_all_values_finite(self, encoder, volatile_df):
        vec = encoder.encode(volatile_df)
        assert np.all(np.isfinite(vec)), "Vector contains NaN or inf"

    def test_short_window_does_not_crash(self):
        """5-candle window triggers NaN paths but encoder should not crash."""
        from holon import HolonClient
        client = HolonClient(dimensions=512)
        enc = OHLCVEncoder(client)
        df = make_flat_ohlcv(5)
        vec = enc.encode(df)
        assert np.all(np.isfinite(vec))


# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------

class TestDeterminism:
    def test_same_window_identical_vector(self, encoder, volatile_df):
        v1 = encoder.encode(volatile_df)
        v2 = encoder.encode(volatile_df)
        np.testing.assert_array_equal(v1, v2)

    def test_independent_encoder_instances_agree(self, holon_client, volatile_df):
        """Two encoders sharing the same client produce identical vectors."""
        e1 = OHLCVEncoder(holon_client)
        e2 = OHLCVEncoder(holon_client)
        np.testing.assert_array_equal(e1.encode(volatile_df), e2.encode(volatile_df))


# ---------------------------------------------------------------------------
# Structural similarity — the key holon property
# ---------------------------------------------------------------------------

class TestStructuralSimilarity:
    def test_identical_windows_produce_identical_vectors(self, encoder, flat_df):
        """MAP bipolar vectors: same input must yield bit-for-bit identical output.

        Note: cosine(v, v) < 1.0 in bipolar {-1,0,1} space because zeros make
        norm(v)^2 > dot(v,v). Use array equality instead of cosine here.
        """
        v1 = encoder.encode(flat_df)
        v2 = encoder.encode(flat_df)
        np.testing.assert_array_equal(v1, v2)

    def test_similar_windows_high_cosine(self):
        """Two windows at nearly the same price level should be more similar
        to each other than either is to a window at a dramatically different level."""
        from holon import HolonClient
        df_low_a = make_flat_ohlcv(200, price=50_000.0)
        df_low_b = make_flat_ohlcv(200, price=50_100.0)   # 0.2% different
        df_high = make_flat_ohlcv(200, price=90_000.0)    # 80% different

        enc = OHLCVEncoder(HolonClient(dimensions=512))
        v_low_a = enc.encode(df_low_a)
        v_low_b = enc.encode(df_low_b)
        v_high = enc.encode(df_high)

        sim_close = cosine_similarity(v_low_a, v_low_b)
        sim_far = cosine_similarity(v_low_a, v_high)
        assert sim_close > sim_far, (
            f"Similar windows ({sim_close:.3f}) should be more similar "
            f"than distant windows ({sim_far:.3f})"
        )

    def test_different_regimes_lower_cosine(self):
        """Uptrend vs flat price should produce lower cosine than flat vs flat."""
        from holon import HolonClient
        df_flat = make_flat_ohlcv(200, price=50_000.0)
        df_flat2 = make_flat_ohlcv(200, price=50_000.0)
        df_trend = make_trending_ohlcv(200, start=30_000, end=80_000)

        enc = OHLCVEncoder(HolonClient(dimensions=512))
        v_flat = enc.encode(df_flat)
        v_flat2 = enc.encode(df_flat2)
        v_trend = enc.encode(df_trend)

        sim_same = cosine_similarity(v_flat, v_flat2)
        sim_diff = cosine_similarity(v_flat, v_trend)
        assert sim_same > sim_diff


# ---------------------------------------------------------------------------
# Weight gating
# ---------------------------------------------------------------------------

class TestWeightGating:
    def test_zero_weight_changes_output(self, volatile_df):
        """Zeroing a field should produce a different vector."""
        from holon import HolonClient
        client = HolonClient(dimensions=512)
        enc_full = OHLCVEncoder(client)
        enc_gated = OHLCVEncoder(client)
        enc_gated.update_weights({"macd_hist": 0.0, "macd_line": 0.0, "macd_signal": 0.0})

        v_full = enc_full.encode(volatile_df)
        v_gated = enc_gated.encode(volatile_df)

        # They shouldn't be identical once fields are removed
        assert not np.array_equal(v_full, v_gated)

    def test_update_weights_persists(self, encoder):
        encoder.update_weights({"rsi": 2.5})
        assert math.isclose(encoder.feature_weights["rsi"], 2.5)

    def test_very_low_weight_field_excluded_from_walkable(self, holon_client, volatile_df):
        """Fields with weight ≤ 0.01 must not appear in the walkable dict."""
        enc = OHLCVEncoder(holon_client)
        enc.update_weights({"rsi": 0.0})

        # Patch _build_walkable to inspect its output
        original = enc._build_walkable

        captured = {}

        def capture(*args, **kwargs):
            result = original(*args, **kwargs)
            captured["walkable"] = result
            return result

        enc._build_walkable = capture
        enc.encode(volatile_df)
        assert "rsi" not in captured["walkable"]


# ---------------------------------------------------------------------------
# Walkable structure
# ---------------------------------------------------------------------------

class TestWalkableStructure:
    def test_walkable_contains_price_field(self, holon_client, volatile_df):
        enc = OHLCVEncoder(holon_client)
        captured = {}
        original = enc._build_walkable

        def capture(*args, **kwargs):
            result = original(*args, **kwargs)
            captured["w"] = result
            return result

        enc._build_walkable = capture
        enc.encode(volatile_df)
        assert "price" in captured["w"]

    def test_walkable_contains_recent_returns(self, holon_client, volatile_df):
        enc = OHLCVEncoder(holon_client)
        captured = {}
        original = enc._build_walkable

        def capture(*args, **kwargs):
            result = original(*args, **kwargs)
            captured["w"] = result
            return result

        enc._build_walkable = capture
        enc.encode(volatile_df)
        assert "recent_returns" in captured["w"]
        assert isinstance(captured["w"]["recent_returns"], list)
        assert len(captured["w"]["recent_returns"]) == 5  # default periods

    def test_log_fields_use_logscale(self, holon_client, volatile_df):
        from holon.kernel.walkable import LogScale
        enc = OHLCVEncoder(holon_client)
        captured = {}
        original = enc._build_walkable

        def capture(*args, **kwargs):
            result = original(*args, **kwargs)
            captured["w"] = result
            return result

        enc._build_walkable = capture
        enc.encode(volatile_df)

        for field in _LOG_FIELDS:
            if field in captured["w"]:
                assert isinstance(captured["w"][field], LogScale), (
                    f"{field} should use LogScale"
                )

    def test_linear_fields_use_linearscale(self, holon_client, volatile_df):
        from holon.kernel.walkable import LinearScale
        enc = OHLCVEncoder(holon_client)
        captured = {}
        original = enc._build_walkable

        def capture(*args, **kwargs):
            result = original(*args, **kwargs)
            captured["w"] = result
            return result

        enc._build_walkable = capture
        enc.encode(volatile_df)

        for field in _LINEAR_FIELDS:
            if field in captured["w"]:
                assert isinstance(captured["w"][field], LinearScale), (
                    f"{field} should use LinearScale"
                )
