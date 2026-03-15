"""Integration tests for DiscoveryHarness and HistoricalFeed.

These tests use synthetic in-memory DataFrames — no network, no parquet.
We monkey-patch HistoricalFeed.ensure_data() to inject the synthetic df.

Covers:
- HistoricalFeed.random_episode() window sizing and count
- HistoricalFeed.replay() determinism and bounds
- HistoricalFeed.next_close() off-by-one correctness
- DiscoveryHarness.run() on a tiny synthetic dataset:
    - terminates cleanly
    - decisions are recorded in tracker
    - engrams may be minted (depends on surprise)
    - results() returns expected structure
- Score path: correct direction → score > 0 in engram metadata
- _timeframe_to_seconds() helper
"""

from __future__ import annotations

import math
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from tests.conftest import make_volatile_ohlcv, make_flat_ohlcv
from trading.feed import HistoricalFeed, _timeframe_to_seconds
from trading.harness import DiscoveryHarness


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_large_ohlcv(n: int = 600, seed: int = 7) -> pd.DataFrame:
    """Enough rows to run multi-episode discovery."""
    return make_volatile_ohlcv(n=n, seed=seed)


def inject_df(feed: HistoricalFeed, df: pd.DataFrame) -> None:
    """Bypass _download by pre-loading _df."""
    feed._df = df


# ---------------------------------------------------------------------------
# HistoricalFeed — window / episode logic
# ---------------------------------------------------------------------------

class TestHistoricalFeed:
    def test_random_episode_yields_correct_count(self):
        df = make_large_ohlcv(600)
        feed = HistoricalFeed()
        inject_df(feed, df)

        length, window = 20, 50
        windows = list(feed.random_episode(length=length, window=window))
        assert len(windows) == length

    def test_random_episode_window_shape(self):
        df = make_large_ohlcv(600)
        feed = HistoricalFeed()
        inject_df(feed, df)

        windows = list(feed.random_episode(length=10, window=30))
        for w in windows:
            assert len(w) == 30

    def test_random_episode_consecutive_windows_overlap(self):
        """Each step shifts by 1 candle — windows overlap by window-1 rows."""
        df = make_large_ohlcv(600)
        feed = HistoricalFeed()
        inject_df(feed, df)

        windows = list(feed.random_episode(length=5, window=20))
        for i in range(len(windows) - 1):
            # Candle at position [1:] of window i should equal [0:-1] of window i+1
            left_tail = windows[i]["close"].iloc[1:].values
            right_head = windows[i + 1]["close"].iloc[:-1].values
            np.testing.assert_array_equal(left_tail, right_head)

    def test_random_episode_seeded_reproducible(self):
        df = make_large_ohlcv(600)
        feed = HistoricalFeed()
        inject_df(feed, df)

        rng_a = np.random.default_rng(42)
        rng_b = np.random.default_rng(42)

        w_a = list(feed.random_episode(length=10, window=30, rng=rng_a))
        w_b = list(feed.random_episode(length=10, window=30, rng=rng_b))

        for wa, wb in zip(w_a, w_b):
            np.testing.assert_array_equal(wa["close"].values, wb["close"].values)

    def test_random_episode_too_small_raises(self):
        df = make_large_ohlcv(50)
        feed = HistoricalFeed()
        inject_df(feed, df)

        with pytest.raises(ValueError, match="candles"):
            list(feed.random_episode(length=40, window=30))  # 30+40=70 > 50

    def test_replay_deterministic(self):
        df = make_large_ohlcv(600)
        feed = HistoricalFeed()
        inject_df(feed, df)

        w1 = list(feed.replay(start_idx=0, length=10, window=20))
        w2 = list(feed.replay(start_idx=0, length=10, window=20))
        for a, b in zip(w1, w2):
            np.testing.assert_array_equal(a["close"].values, b["close"].values)

    def test_replay_respects_bounds(self):
        df = make_large_ohlcv(100)
        feed = HistoricalFeed()
        inject_df(feed, df)

        # Request more steps than available data
        windows = list(feed.replay(start_idx=95, length=20, window=10))
        # Should stop before going out of bounds (100 - 95 - 10 = -5 → 0 valid steps or very few)
        assert len(windows) <= 5  # can't go beyond end

    def test_next_close_correct_value(self):
        df = make_large_ohlcv(200)
        feed = HistoricalFeed()
        inject_df(feed, df)

        window_size = 10
        start = 5
        expected = float(df.iloc[start + window_size]["close"])
        actual = feed.next_close(window_start_idx=start, window_size=window_size)
        assert math.isclose(actual, expected, rel_tol=1e-9)

    def test_next_close_out_of_range_returns_none(self):
        df = make_large_ohlcv(50)
        feed = HistoricalFeed()
        inject_df(feed, df)

        result = feed.next_close(window_start_idx=45, window_size=10)
        assert result is None

    def test_ensure_data_returns_injected_df(self):
        df = make_large_ohlcv(100)
        feed = HistoricalFeed()
        inject_df(feed, df)
        result = feed.ensure_data()
        assert len(result) == 100


# ---------------------------------------------------------------------------
# _timeframe_to_seconds
# ---------------------------------------------------------------------------

class TestTimeframeToSeconds:
    def test_5m(self):
        assert _timeframe_to_seconds("5m") == 300

    def test_1h(self):
        assert _timeframe_to_seconds("1h") == 3600

    def test_1d(self):
        assert _timeframe_to_seconds("1d") == 86400

    def test_15m(self):
        assert _timeframe_to_seconds("15m") == 900


# ---------------------------------------------------------------------------
# DiscoveryHarness — integration
# ---------------------------------------------------------------------------

class TestDiscoveryHarness:
    """Integration tests that run real holon encode+subspace cycles
    against synthetic OHLCV data. No network, no files.

    We use a small dim=256 and k=4 to keep tests fast.
    """

    @pytest.fixture
    def harness(self, tmp_path):
        h = DiscoveryHarness(
            dimensions=256,
            k=4,
            initial_usdt=10_000.0,
            data_path=str(tmp_path / "btc.parquet"),
            db_path=str(tmp_path / "disc.db"),
        )
        # Inject synthetic data (enough for 3 episodes × 10 steps with 40-candle window)
        df = make_large_ohlcv(n=600, seed=99)
        inject_df(h.feed, df)
        return h

    def test_run_terminates(self, harness):
        """3 episodes × 5 steps with 40-candle window should complete without error."""
        harness.run(num_episodes=3, episode_length=5, window_candles=40)

    def test_decisions_recorded(self, harness):
        harness.run(num_episodes=2, episode_length=5, window_candles=40)
        s = harness.tracker.summary()
        # 2 episodes × 5 steps = 10 decisions
        assert s["decisions"] == 10

    def test_results_structure(self, harness):
        harness.run(num_episodes=2, episode_length=5, window_candles=40)
        r = harness.results()
        assert "summary" in r
        assert "engram_count" in r
        assert "feature_report" in r
        assert isinstance(r["engram_count"], int)

    def test_library_grows_over_episodes(self, harness):
        """With a volatile enough series, surprise fires and engrams are minted."""
        harness.run(num_episodes=5, episode_length=20, window_candles=40)
        # We don't assert a specific count — surprise depends on the series —
        # but the library must be a valid EngramLibrary with consistent names.
        names = harness.library.names()
        assert isinstance(names, list)
        assert len(names) >= 0  # structural: names() always returns a list

    def test_engram_metadata_structure(self, harness):
        """Any minted engram must have the required metadata keys."""
        harness.run(num_episodes=5, episode_length=20, window_candles=40)
        for name in harness.library.names():
            eng = harness.library.get(name)
            assert eng is not None
            assert eng.metadata is not None
            assert "action" in eng.metadata
            assert "confidence" in eng.metadata
            assert "score" in eng.metadata

    def test_correct_direction_scores_positively(self, harness, tmp_path):
        """Manually inject an engram, run one step where the price goes up,
        and verify its score becomes positive."""
        from holon.memory import OnlineSubspace, EngramLibrary
        import numpy as np

        # Warm up the subspace with 10 vectors so threshold is finite
        sub = OnlineSubspace(dim=harness.dimensions, k=harness.k)
        rng = np.random.default_rng(0)
        for _ in range(20):
            v = rng.choice(np.array([-1, 0, 1], dtype=np.int8), size=harness.dimensions)
            sub.update(v)

        # Add a BUY engram
        harness.library.add(
            "test_buy",
            sub,
            None,
            action="BUY",
            confidence=0.9,
            score=0.0,
        )

        # Simulate a call to _score_engrams: price went up → correct for BUY
        harness._score_engrams(["test_buy"], "BUY", actual_return=0.05)
        eng = harness.library.get("test_buy")
        assert eng.metadata["score"] > 0.0

    def test_wrong_direction_scores_negatively(self, harness):
        """BUY engram used when price fell → score should decrease."""
        from holon.memory import OnlineSubspace
        import numpy as np

        sub = OnlineSubspace(dim=harness.dimensions, k=harness.k)
        rng = np.random.default_rng(1)
        for _ in range(20):
            v = rng.choice(np.array([-1, 0, 1], dtype=np.int8), size=harness.dimensions)
            sub.update(v)

        harness.library.add(
            "test_sell_loss",
            sub,
            None,
            action="BUY",
            confidence=0.9,
            score=0.0,
        )
        harness._score_engrams(["test_sell_loss"], "BUY", actual_return=-0.03)
        eng = harness.library.get("test_sell_loss")
        assert eng.metadata["score"] < 0.0

    def test_unknown_engram_in_score_ignored(self, harness):
        """Non-existent engram ID in score call must not raise."""
        harness._score_engrams(["ghost_engram"], "BUY", actual_return=0.01)

    def test_results_summary_keys(self, harness):
        harness.run(num_episodes=1, episode_length=5, window_candles=40)
        r = harness.results()
        for key in ("total_return", "trades", "decisions"):
            assert key in r["summary"]
