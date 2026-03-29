"""Unit and integration tests for OHLCVEncoder (window-snapshot architecture).

Covers:
- encode() returns list[np.ndarray] of n_stripes vectors
- All stripe vectors have correct dimensionality
- Determinism: same window → identical stripe vectors
- Structural similarity: similar windows → higher aggregate cosine than dissimilar
- build_surprise_profile returns field_path → float in [0,1]
- encode_with_walkable returns (list[np.ndarray], dict)
- Walkable has the expected per-candle nested structure (t0, t1, ..., time)
- All stripe vector values are finite

Integration: real holon API called to catch API drift early.
"""

from __future__ import annotations

import numpy as np
import pytest

from holon import HolonClient
from tests.conftest import make_flat_ohlcv, make_volatile_ohlcv, make_trending_ohlcv
from trading.encoder import OHLCVEncoder


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_encoder(dim: int = 512, window_candles: int = 6, n_stripes: int = 4) -> OHLCVEncoder:
    client = HolonClient(dimensions=dim)
    return OHLCVEncoder(client, window_candles=window_candles, n_stripes=n_stripes)


def aggregate_cosine(vecs_a: list[np.ndarray], vecs_b: list[np.ndarray]) -> float:
    """Mean per-stripe cosine similarity between two stripe vector lists."""
    sims = []
    for a, b in zip(vecs_a, vecs_b):
        a_f, b_f = a.astype(float), b.astype(float)
        denom = np.linalg.norm(a_f) * np.linalg.norm(b_f)
        sims.append(float(np.dot(a_f, b_f) / denom) if denom > 0 else 0.0)
    return float(np.mean(sims))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def enc():
    return make_encoder()


@pytest.fixture
def large_flat_df():
    return make_flat_ohlcv(250)


@pytest.fixture
def large_volatile_df():
    return make_volatile_ohlcv(250)


# ---------------------------------------------------------------------------
# Output shape and type
# ---------------------------------------------------------------------------

class TestOutputShape:
    def test_returns_list(self, enc, large_volatile_df):
        result = enc.encode(large_volatile_df)
        assert isinstance(result, list)

    def test_correct_number_of_stripes(self, enc, large_volatile_df):
        result = enc.encode(large_volatile_df)
        assert len(result) == enc.n_stripes

    def test_each_stripe_is_ndarray(self, enc, large_volatile_df):
        result = enc.encode(large_volatile_df)
        for vec in result:
            assert isinstance(vec, np.ndarray)

    def test_each_stripe_has_correct_dim(self, enc, large_volatile_df):
        dim = enc.client.encoder.vector_manager.dimensions
        result = enc.encode(large_volatile_df)
        for vec in result:
            assert vec.shape == (dim,)

    def test_all_values_finite(self, enc, large_volatile_df):
        result = enc.encode(large_volatile_df)
        for vec in result:
            assert np.all(np.isfinite(vec)), "Stripe vector contains NaN or inf"

    def test_too_short_raises(self, enc):
        # enc has window_candles=6, needs LOOKBACK_CANDLES+6 = 206 rows minimum
        short_df = make_volatile_ohlcv(50)
        with pytest.raises(ValueError, match="candles"):
            enc.encode(short_df)


# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------

class TestDeterminism:
    def test_same_window_identical_stripes(self, enc, large_volatile_df):
        s1 = enc.encode(large_volatile_df)
        s2 = enc.encode(large_volatile_df)
        for a, b in zip(s1, s2):
            np.testing.assert_array_equal(a, b)

    def test_independent_instances_agree(self, large_volatile_df):
        client = HolonClient(dimensions=512)
        e1 = OHLCVEncoder(client, window_candles=6, n_stripes=4)
        e2 = OHLCVEncoder(client, window_candles=6, n_stripes=4)
        for a, b in zip(e1.encode(large_volatile_df), e2.encode(large_volatile_df)):
            np.testing.assert_array_equal(a, b)


# ---------------------------------------------------------------------------
# Structural similarity — the core holon property
# ---------------------------------------------------------------------------

class TestStructuralSimilarity:
    def test_identical_windows_identical_stripes(self, enc, large_flat_df):
        s1 = enc.encode(large_flat_df)
        s2 = enc.encode(large_flat_df)
        for a, b in zip(s1, s2):
            np.testing.assert_array_equal(a, b)

    def test_different_price_levels_same_pattern_high_cosine(self):
        """Price-normalized encoding: same pattern at different price levels should be very similar."""
        enc = make_encoder()
        df_low  = make_flat_ohlcv(250, price=5_000.0)
        df_high = make_flat_ohlcv(250, price=90_000.0)

        s_low  = enc.encode(df_low)
        s_high = enc.encode(df_high)

        sim = aggregate_cosine(s_low, s_high)
        assert sim > 0.95, (
            f"Same pattern at different price levels should be very similar ({sim:.3f})"
        )

    def test_different_regimes_lower_cosine(self):
        enc = make_encoder()
        df_flat  = make_flat_ohlcv(250, price=50_000.0)
        df_flat2 = make_flat_ohlcv(250, price=50_000.0)
        df_trend = make_trending_ohlcv(250, start=30_000, end=80_000)

        s_flat  = enc.encode(df_flat)
        s_flat2 = enc.encode(df_flat2)
        s_trend = enc.encode(df_trend)

        sim_same = aggregate_cosine(s_flat, s_flat2)
        sim_diff = aggregate_cosine(s_flat, s_trend)
        assert sim_same > sim_diff, (
            f"Identical regimes ({sim_same:.3f}) should exceed different ({sim_diff:.3f})"
        )


# ---------------------------------------------------------------------------
# encode_with_walkable
# ---------------------------------------------------------------------------

class TestEncodeWithWalkable:
    def test_returns_tuple(self, enc, large_volatile_df):
        result = enc.encode_with_walkable(large_volatile_df)
        assert isinstance(result, tuple) and len(result) == 2

    def test_stripes_match_encode(self, enc, large_volatile_df):
        stripe_vecs, _ = enc.encode_with_walkable(large_volatile_df)
        stripe_vecs2   = enc.encode(large_volatile_df)
        for a, b in zip(stripe_vecs, stripe_vecs2):
            np.testing.assert_array_equal(a, b)

    def test_walkable_is_dict(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        assert isinstance(walkable, dict) and len(walkable) > 0

    def test_walkable_has_candle_keys(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        # Should have t0 .. t(window_candles-1)
        for i in range(enc.window_candles):
            assert f"t{i}" in walkable, f"Missing key t{i} in walkable"

    def test_walkable_has_time_block(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        assert "time" in walkable
        for key in ("hour_sin", "hour_cos", "dow_sin", "dow_cos"):
            assert key in walkable["time"], f"Missing {key} in time block"

    def test_candle_has_expected_subkeys(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        t0 = walkable["t0"]
        for group in ("ohlcv", "sma", "macd", "bb", "dmi"):
            assert group in t0, f"Missing group {group} in t0"
        for scalar in ("vol_r", "atr_r", "rsi", "ret"):
            assert scalar in t0, f"Missing field {scalar} in t0"

    def test_ohlcv_has_normalized_values(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        for key in ("open_r", "high_r", "low_r"):
            assert key in walkable["t0"]["ohlcv"]


# ---------------------------------------------------------------------------
# build_surprise_profile
# ---------------------------------------------------------------------------

class TestBuildSurpriseProfile:
    def _trained_subspace_and_vecs(self, enc, df, n: int = 60):
        from holon.memory import StripedSubspace
        ss = StripedSubspace(
            dim=enc.client.encoder.vector_manager.dimensions,
            k=8,
            n_stripes=enc.n_stripes,
        )
        stripe_vecs, walkable = enc.encode_with_walkable(df)
        for _ in range(n):
            ss.update(stripe_vecs)
        return ss, stripe_vecs, walkable

    def test_returns_dict(self, enc, large_volatile_df):
        ss, sv, wk = self._trained_subspace_and_vecs(enc, large_volatile_df)
        profile_arr = ss.residual_profile(sv)
        hot = int(np.argmax(profile_arr))
        anomalous = ss.anomalous_component(sv, hot)
        profile = enc.build_surprise_profile(anomalous, hot, wk)
        assert isinstance(profile, dict)

    def test_values_in_unit_interval(self, enc, large_volatile_df):
        ss, sv, wk = self._trained_subspace_and_vecs(enc, large_volatile_df)
        hot = int(np.argmax(ss.residual_profile(sv)))
        anomalous = ss.anomalous_component(sv, hot)
        profile = enc.build_surprise_profile(anomalous, hot, wk)
        for path, score in profile.items():
            assert 0.0 <= score <= 1.0, f"{path}: {score:.4f} out of [0,1]"

    def test_zero_anomalous_returns_empty(self, enc, large_volatile_df):
        _, sv, wk = self._trained_subspace_and_vecs(enc, large_volatile_df)
        dim = enc.client.encoder.vector_manager.dimensions
        zero = np.zeros(dim, dtype=float)
        profile = enc.build_surprise_profile(zero, 0, wk)
        assert profile == {}

    def test_keys_are_field_paths(self, enc, large_volatile_df):
        ss, sv, wk = self._trained_subspace_and_vecs(enc, large_volatile_df)
        hot = int(np.argmax(ss.residual_profile(sv)))
        anomalous = ss.anomalous_component(sv, hot)
        profile = enc.build_surprise_profile(anomalous, hot, wk)
        # All keys should be dot-notation paths (at least one dot)
        for key in profile:
            assert "." in key or key in ("time",), f"Unexpected key format: {key}"


# ---------------------------------------------------------------------------
# update_weights
# ---------------------------------------------------------------------------

class TestUpdateWeights:
    def test_update_weights_persists(self, enc):
        enc.update_weights({"some_weight": 2.5})
        assert enc.feature_weights.get("some_weight") == 2.5

    def test_update_weights_clears_cache(self, enc):
        enc._role_atoms["dummy"] = np.zeros(10)
        enc.update_weights({"something": 1.0})
        assert len(enc._role_atoms) == 0
