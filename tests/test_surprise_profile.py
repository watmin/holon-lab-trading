"""Tests for surprise profile / field attribution and Darwinism wiring.

Covers:
- OHLCVEncoder.build_surprise_profile():
    - returns dict with field names as keys
    - values are in [0, 1]
    - outlier field scores higher than neutral fields
    - zero anomalous vector → empty profile
    - gated (zero-weight) fields excluded from profile
    - caching: role atoms consistent across calls
- OHLCVEncoder.encode_with_walkable():
    - returns (vector, walkable) tuple
    - vector matches encode() output
    - walkable is a non-empty dict
- Darwinism wiring in harness:
    - after run(), darwinism weights are no longer all 1.0 (got updated)
    - feature_report is non-trivial
- Harness engram surprise_profile stored:
    - minted engrams have a surprise_profile attribute
"""

from __future__ import annotations

import math
import numpy as np
import pytest

from holon import HolonClient
from holon.kernel.walkable import LinearScale, LogScale
from holon.memory import OnlineSubspace

from tests.conftest import make_volatile_ohlcv, make_flat_ohlcv
from trading.encoder import OHLCVEncoder, _LOG_FIELDS, _LINEAR_FIELDS
from trading.harness import DiscoveryHarness


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def client():
    return HolonClient(dimensions=512)


@pytest.fixture
def encoder(client):
    return OHLCVEncoder(client)


@pytest.fixture
def volatile_df():
    return make_volatile_ohlcv(200)


def make_harness(tmp_path):
    h = DiscoveryHarness(
        dimensions=256,
        k=4,
        db_path=str(tmp_path / "disc.db"),
    )
    df = make_volatile_ohlcv(600, seed=77)
    h.feed._df = df
    return h


# ---------------------------------------------------------------------------
# OHLCVEncoder.encode_with_walkable()
# ---------------------------------------------------------------------------

class TestEncodeWithWalkable:
    def test_returns_tuple(self, encoder, volatile_df):
        result = encoder.encode_with_walkable(volatile_df)
        assert isinstance(result, tuple)
        assert len(result) == 2

    def test_vector_matches_encode(self, encoder, volatile_df):
        vec, _ = encoder.encode_with_walkable(volatile_df)
        vec2 = encoder.encode(volatile_df)
        np.testing.assert_array_equal(vec, vec2)

    def test_walkable_is_dict(self, encoder, volatile_df):
        _, walkable = encoder.encode_with_walkable(volatile_df)
        assert isinstance(walkable, dict)
        assert len(walkable) > 0

    def test_walkable_contains_price(self, encoder, volatile_df):
        _, walkable = encoder.encode_with_walkable(volatile_df)
        assert "price" in walkable


# ---------------------------------------------------------------------------
# OHLCVEncoder.build_surprise_profile()
# ---------------------------------------------------------------------------

class TestBuildSurpriseProfile:
    def _make_trained_subspace(self, encoder, volatile_df, n: int = 80) -> tuple:
        """Return (subspace, anomalous_component) trained on volatile_df."""
        sub = OnlineSubspace(dim=encoder.client.encoder.vector_manager.dimensions, k=8)
        vec = encoder.encode(volatile_df)
        for _ in range(n):
            sub.update(vec)
        anomalous = sub.anomalous_component(vec)
        return sub, anomalous

    def test_returns_dict(self, encoder, volatile_df):
        _, anomalous = self._make_trained_subspace(encoder, volatile_df)
        profile = encoder.build_surprise_profile(anomalous)
        assert isinstance(profile, dict)

    def test_keys_are_field_names(self, encoder, volatile_df):
        _, anomalous = self._make_trained_subspace(encoder, volatile_df)
        profile = encoder.build_surprise_profile(anomalous)
        known_fields = _LOG_FIELDS | _LINEAR_FIELDS
        for key in profile:
            assert key in known_fields, f"Unexpected key: {key}"

    def test_values_in_unit_interval(self, encoder, volatile_df):
        _, anomalous = self._make_trained_subspace(encoder, volatile_df)
        profile = encoder.build_surprise_profile(anomalous)
        for field, score in profile.items():
            assert 0.0 <= score <= 1.0, f"{field} score={score:.4f} out of [0,1]"

    def test_zero_anomalous_returns_empty(self, encoder):
        dim = encoder.client.encoder.vector_manager.dimensions
        zero = np.zeros(dim, dtype=float)
        profile = encoder.build_surprise_profile(zero)
        assert profile == {}

    def test_gated_field_excluded(self, client, volatile_df):
        """A zero-weight field must not appear in the surprise profile."""
        enc = OHLCVEncoder(client)
        enc.update_weights({"macd_hist": 0.0, "macd_line": 0.0, "macd_signal": 0.0})
        sub = OnlineSubspace(dim=512, k=8)
        vec = enc.encode(volatile_df)
        for _ in range(40):
            sub.update(vec)
        anomalous = sub.anomalous_component(vec)
        profile = enc.build_surprise_profile(anomalous)
        assert "macd_hist" not in profile
        assert "macd_line" not in profile
        assert "macd_signal" not in profile

    def test_outlier_field_scores_highest(self, client):
        """Encode a walkable with one exaggerated field. After training a subspace
        on normal values, the anomalous component should attribute to the outlier."""
        enc = OHLCVEncoder(client)

        # Normal encoding repeated to train subspace
        normal_w = {"price": LogScale(50_000.0), "rsi": LinearScale(50.0), "macd_hist": LinearScale(0.0)}
        v_normal = client.encode_walkable(normal_w)

        sub = OnlineSubspace(dim=512, k=8)
        for _ in range(80):
            sub.update(v_normal)

        # Outlier: macd_hist is extreme
        outlier_w = {"price": LogScale(50_000.0), "rsi": LinearScale(50.0), "macd_hist": LinearScale(500.0)}
        v_outlier = client.encode_walkable(outlier_w)
        anomalous = sub.anomalous_component(v_outlier)

        profile = enc.build_surprise_profile(anomalous)

        assert "macd_hist" in profile, "macd_hist should appear in profile"
        # macd_hist should score higher than price or rsi
        macd_score = profile.get("macd_hist", 0.0)
        price_score = profile.get("price", 0.0)
        rsi_score = profile.get("rsi", 0.0)
        assert macd_score > price_score, (
            f"macd_hist ({macd_score:.4f}) should > price ({price_score:.4f})"
        )
        assert macd_score > rsi_score, (
            f"macd_hist ({macd_score:.4f}) should > rsi ({rsi_score:.4f})"
        )

    def test_role_atoms_cached(self, encoder, volatile_df):
        """Calling build_surprise_profile twice should use cached role atoms."""
        sub = OnlineSubspace(dim=512, k=8)
        vec = encoder.encode(volatile_df)
        for _ in range(40):
            sub.update(vec)
        anomalous = sub.anomalous_component(vec)

        # First call populates cache
        p1 = encoder.build_surprise_profile(anomalous)
        cached_keys = set(encoder._role_atoms.keys())

        # Second call — cache already populated
        p2 = encoder.build_surprise_profile(anomalous)

        assert p1 == p2
        assert set(encoder._role_atoms.keys()) == cached_keys  # no new atoms added

    def test_update_weights_clears_cache(self, client):
        """update_weights() must clear the role atom cache.

        We use a fresh encoder and a non-zero anomalous vector so the cache
        is guaranteed to be populated before we test clearing.
        """
        enc = OHLCVEncoder(client)

        # Build a walkable with extreme macd_hist so anomalous is non-zero
        normal_w = {"price": LogScale(50_000.0), "rsi": LinearScale(50.0), "macd_hist": LinearScale(0.0)}
        v_normal = client.encode_walkable(normal_w)

        sub = OnlineSubspace(dim=512, k=8)
        for _ in range(40):
            sub.update(v_normal)

        # Outlier vec → non-zero anomalous component
        outlier_w = {"price": LogScale(50_000.0), "rsi": LinearScale(50.0), "macd_hist": LinearScale(500.0)}
        v_outlier = client.encode_walkable(outlier_w)
        anomalous = sub.anomalous_component(v_outlier)

        # Populate cache
        enc.build_surprise_profile(anomalous)
        assert len(enc._role_atoms) > 0, "Cache should be populated after build_surprise_profile"

        # Clear it
        enc.update_weights({"rsi": 2.0})
        assert len(enc._role_atoms) == 0, "Cache should be cleared after update_weights"


# ---------------------------------------------------------------------------
# Darwinism wiring in harness
# ---------------------------------------------------------------------------

class TestDarwinismWiring:
    def test_darwinism_update_fires_on_buy(self):
        """update() with BUY + correct return should increase importance."""
        from trading.darwinism import FeatureDarwinism
        d = FeatureDarwinism(["price", "rsi"])
        initial = dict(d.importance)

        profile = {"price": 0.2, "rsi": 0.5}
        d.update(profile, realized_return=0.01, action="BUY")  # correct direction

        changed = sum(
            1 for f in d.importance if abs(d.importance[f] - initial[f]) > 1e-9
        )
        assert changed >= 1, "At least one field should update on a scored BUY"

    def test_darwinism_hold_is_neutral(self):
        """HOLD should not change importance at all."""
        from trading.darwinism import FeatureDarwinism
        d = FeatureDarwinism(["price", "rsi"])
        initial = dict(d.importance)

        profile = {"price": 0.2, "rsi": 0.5}
        d.update(profile, realized_return=0.01, action="HOLD")

        for f, v in d.importance.items():
            assert math.isclose(v, initial[f]), f"{f} changed on HOLD — should be neutral"

    def test_darwinism_importance_bounded(self):
        """Importance stays in [-1, 1] even after many updates."""
        from trading.darwinism import FeatureDarwinism
        d = FeatureDarwinism(["price"])
        profile = {"price": 0.0}
        for _ in range(200):
            d.update(profile, realized_return=-0.01, action="BUY")  # always wrong
        assert -1.0 <= d.importance["price"] <= 1.0

    def test_feature_report_nonempty(self, tmp_path):
        h = make_harness(tmp_path)
        h.run(num_episodes=2, episode_length=10, window_candles=40)
        report = h.darwinism.report()
        assert len(report) > 50
        # All field names should appear in the report
        for field in h.darwinism.importance:
            assert field in report

    def test_results_includes_feature_report(self, tmp_path):
        h = make_harness(tmp_path)
        h.run(num_episodes=2, episode_length=10, window_candles=40)
        r = h.results()
        assert "feature_report" in r
        assert isinstance(r["feature_report"], str)
        assert len(r["feature_report"]) > 0


# ---------------------------------------------------------------------------
# Harness: surprise_profile stored on minted engrams
# ---------------------------------------------------------------------------

class TestEngramSurpriseProfile:
    def test_minted_engrams_have_surprise_profile_attr(self, tmp_path):
        """Engrams minted during discovery should have a surprise_profile attribute."""
        h = make_harness(tmp_path)
        h.run(num_episodes=5, episode_length=30, window_candles=40)

        for name in h.library.names():
            eng = h.library.get(name)
            assert hasattr(eng, "surprise_profile"), (
                f"Engram {name} missing surprise_profile attribute"
            )

    def test_minted_engrams_surprise_profile_type(self, tmp_path):
        """surprise_profile should be a dict (possibly empty if not computed)."""
        h = make_harness(tmp_path)
        h.run(num_episodes=5, episode_length=30, window_candles=40)

        for name in h.library.names():
            eng = h.library.get(name)
            assert isinstance(eng.surprise_profile, dict)
