"""Tests for surprise profile / field attribution and Darwinism wiring.

Covers:
- OHLCVEncoder.build_surprise_profile():
    - returns dict with field paths as keys
    - values are in [0, 1]
    - zero anomalous vector → empty profile
- OHLCVEncoder.encode_with_walkable():
    - returns (list[np.ndarray], dict) tuple
    - stripe vectors match encode() output
    - walkable is a non-empty dict
- Darwinism wiring:
    - update() with BUY/SELL changes importance; HOLD does not
    - importance stays bounded in [-1, 1] after many updates
- Harness engram surprise_profile attribute:
    - minted engrams have a surprise_profile attribute (dict)
"""

from __future__ import annotations

import math
import numpy as np
import pytest

from holon import HolonClient
from holon.memory import StripedSubspace

from tests.conftest import make_volatile_ohlcv
from trading.encoder import OHLCVEncoder
from trading.harness import DiscoveryHarness


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def client():
    return HolonClient(dimensions=512)


@pytest.fixture
def enc(client):
    return OHLCVEncoder(client, window_candles=6, n_stripes=4)


@pytest.fixture
def large_volatile_df():
    return make_volatile_ohlcv(250)


def make_harness(tmp_path):
    h = DiscoveryHarness(
        dimensions=256,
        k=4,
        db_path=str(tmp_path / "disc.db"),
        save_dir=str(tmp_path),
    )
    df = make_volatile_ohlcv(600, seed=77)
    h.feed._df = df
    return h


# ---------------------------------------------------------------------------
# OHLCVEncoder.encode_with_walkable()
# ---------------------------------------------------------------------------

class TestEncodeWithWalkable:
    def test_returns_tuple(self, enc, large_volatile_df):
        result = enc.encode_with_walkable(large_volatile_df)
        assert isinstance(result, tuple)
        assert len(result) == 2

    def test_stripes_match_encode(self, enc, large_volatile_df):
        stripe_vecs, _ = enc.encode_with_walkable(large_volatile_df)
        stripe_vecs2   = enc.encode(large_volatile_df)
        for a, b in zip(stripe_vecs, stripe_vecs2):
            np.testing.assert_array_equal(a, b)

    def test_walkable_is_dict(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        assert isinstance(walkable, dict)
        assert len(walkable) > 0

    def test_walkable_has_candle_keys(self, enc, large_volatile_df):
        _, walkable = enc.encode_with_walkable(large_volatile_df)
        assert "t0" in walkable


# ---------------------------------------------------------------------------
# OHLCVEncoder.build_surprise_profile()
# ---------------------------------------------------------------------------

class TestBuildSurpriseProfile:
    def _setup(self, enc, df, n: int = 60):
        dim = enc.client.encoder.vector_manager.dimensions
        ss = StripedSubspace(dim=dim, k=8, n_stripes=enc.n_stripes)
        stripe_vecs, walkable = enc.encode_with_walkable(df)
        for _ in range(n):
            ss.update(stripe_vecs)
        return ss, stripe_vecs, walkable

    def test_returns_dict(self, enc, large_volatile_df):
        ss, sv, wk = self._setup(enc, large_volatile_df)
        hot = int(np.argmax(ss.residual_profile(sv)))
        anomalous = ss.anomalous_component(sv, hot)
        assert isinstance(enc.build_surprise_profile(anomalous, hot, wk), dict)

    def test_values_in_unit_interval(self, enc, large_volatile_df):
        ss, sv, wk = self._setup(enc, large_volatile_df)
        hot = int(np.argmax(ss.residual_profile(sv)))
        anomalous = ss.anomalous_component(sv, hot)
        profile = enc.build_surprise_profile(anomalous, hot, wk)
        for path, score in profile.items():
            assert 0.0 <= score <= 1.0, f"{path}: {score:.4f} out of [0,1]"

    def test_zero_anomalous_returns_empty(self, enc, large_volatile_df):
        _, sv, wk = self._setup(enc, large_volatile_df)
        dim = enc.client.encoder.vector_manager.dimensions
        zero = np.zeros(dim, dtype=float)
        assert enc.build_surprise_profile(zero, 0, wk) == {}

    def test_role_atoms_cached_after_call(self, enc, large_volatile_df):
        ss, sv, wk = self._setup(enc, large_volatile_df)
        hot = int(np.argmax(ss.residual_profile(sv)))
        anomalous = ss.anomalous_component(sv, hot)
        p1 = enc.build_surprise_profile(anomalous, hot, wk)
        p2 = enc.build_surprise_profile(anomalous, hot, wk)
        assert p1 == p2

    def test_update_weights_clears_cache(self, enc):
        enc._role_atoms["dummy.path"] = np.zeros(10)
        enc.update_weights({"any": 1.0})
        assert len(enc._role_atoms) == 0


# ---------------------------------------------------------------------------
# Darwinism wiring (unit-level)
# ---------------------------------------------------------------------------

class TestDarwinismWiring:
    def test_darwinism_update_fires_on_buy(self):
        from trading.darwinism import FeatureDarwinism
        d = FeatureDarwinism(["price", "rsi"])
        initial = dict(d.importance)
        d.update({"price": 0.2, "rsi": 0.5}, realized_return=0.01, action="BUY")
        changed = sum(1 for f in d.importance if abs(d.importance[f] - initial[f]) > 1e-9)
        assert changed >= 1, "At least one field should update on BUY"

    def test_darwinism_hold_is_neutral(self):
        from trading.darwinism import FeatureDarwinism
        d = FeatureDarwinism(["price", "rsi"])
        initial = dict(d.importance)
        d.update({"price": 0.2, "rsi": 0.5}, realized_return=0.01, action="HOLD")
        for f, v in d.importance.items():
            assert math.isclose(v, initial[f]), f"{f} changed on HOLD — should be neutral"

    def test_darwinism_importance_bounded(self):
        from trading.darwinism import FeatureDarwinism
        d = FeatureDarwinism(["price"])
        for _ in range(200):
            d.update({"price": 0.0}, realized_return=-0.01, action="BUY")
        assert -1.0 <= d.importance["price"] <= 1.0

    def test_feature_report_nonempty(self, tmp_path):
        h = make_harness(tmp_path)
        h.run(num_episodes=2, episode_length=10)
        report = h.darwinism.report()
        assert len(report) > 0

    def test_results_includes_feature_report(self, tmp_path):
        h = make_harness(tmp_path)
        h.run(num_episodes=2, episode_length=10)
        r = h.results()
        assert "feature_report" in r
        assert isinstance(r["feature_report"], str)


# ---------------------------------------------------------------------------
# Harness: surprise_profile stored on minted engrams
# ---------------------------------------------------------------------------

class TestEngramSurpriseProfile:
    def test_minted_engrams_have_surprise_profile_attr(self, tmp_path):
        h = make_harness(tmp_path)
        h.run(num_episodes=5, episode_length=30)
        for name in h.names():
            eng = h.library.get(name)
            assert hasattr(eng, "surprise_profile"), (
                f"Engram {name} missing surprise_profile attribute"
            )

    def test_minted_engrams_surprise_profile_type(self, tmp_path):
        h = make_harness(tmp_path)
        h.run(num_episodes=5, episode_length=30)
        for name in h.names():
            eng = h.library.get(name)
            assert isinstance(eng.surprise_profile, dict)
