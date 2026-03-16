"""Integration tests for the full consumer → critic → hot-reload loop.

These tests use ReplayFeed driven from the historical parquet file so they
prove real code paths (encoding, matching, minting, consolidation, shipping)
without hitting any exchange or sleeping.

Requires: holon-lab-trading/data/btc_5m_raw.parquet
Skip automatically if that file is absent (CI without data).
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

PARQUET = Path(__file__).parent.parent / "data" / "btc_5m_raw.parquet"
SEED_ENGRAMS = Path(__file__).parent.parent / "data" / "seed_engrams.json"

pytestmark = pytest.mark.skipif(
    not PARQUET.exists() or not SEED_ENGRAMS.exists(),
    reason="btc_5m_raw.parquet or seed_engrams.json not present",
)


def _make_system(db_path: str, engram_path: str):
    from trading.system import TradingSystem
    return TradingSystem(
        seed_engrams=str(SEED_ENGRAMS),
        live_engrams=engram_path,
        db_path=db_path,
        critic_interval_minutes=999,
    )


def _make_feed(steps: int, seed: int = 42):
    from trading.feed import ReplayFeed
    from trading.encoder import OHLCVEncoder
    return ReplayFeed(
        parquet_path=str(PARQUET),
        window=OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES,
        max_steps=steps,
        rng_seed=seed,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestReplayFeedBasics:
    def test_yields_correct_shape(self):
        from trading.encoder import OHLCVEncoder
        feed = _make_feed(steps=5)
        windows = list(feed.stream())
        expected_rows = OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES
        assert len(windows) == 5
        for w in windows:
            assert len(w) == expected_rows

    def test_stops_at_max_steps(self):
        feed = _make_feed(steps=10)
        count = sum(1 for _ in feed.stream())
        assert count == 10

    def test_different_seeds_produce_different_windows(self):
        f1 = _make_feed(steps=1, seed=1)
        f2 = _make_feed(steps=1, seed=2)
        w1 = next(iter(f1.stream()))
        w2 = next(iter(f2.stream()))
        assert not w1.equals(w2)


class TestConsumerLoop:
    def test_consumer_records_decisions(self):
        with tempfile.TemporaryDirectory() as td:
            system = _make_system(f"{td}/t.db", f"{td}/e.json")
            from trading.system import RealTimeConsumer
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=f"{td}/e.json",
                reload_interval_s=999999,
            )
            consumer.run(feed=_make_feed(steps=60))
            summary = system.tracker.summary()
            assert summary["decisions"] == 60

    def test_threshold_calibrates_after_warmup(self):
        from trading.system import RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            system = _make_system(f"{td}/t.db", f"{td}/e.json")
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=f"{td}/e.json",
                reload_interval_s=999999,
            )
            assert consumer.match_threshold is None
            consumer.run(feed=_make_feed(steps=RealTimeConsumer.CALIBRATION_STEPS + 5))
            assert consumer.match_threshold is not None
            assert consumer.match_threshold > 0

    def test_non_hold_decisions_appear_after_calibration(self):
        from trading.system import RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            system = _make_system(f"{td}/t.db", f"{td}/e.json")
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=f"{td}/e.json",
                reload_interval_s=999999,
            )
            consumer.run(feed=_make_feed(steps=200))
            df = system.tracker.recent_decisions(hours=9999)
            non_hold = df[df["action"] != "HOLD"]
            assert len(non_hold) > 0, "Expected some BUY/SELL after calibration"


class TestCriticCycle:
    def test_critic_ships_engram_file(self):
        from trading.system import AsyncCritic, RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            ep = f"{td}/e.json"
            system = _make_system(f"{td}/t.db", ep)
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=ep,
                reload_interval_s=999999,
            )
            consumer.run(feed=_make_feed(steps=150))

            critic = AsyncCritic(
                library=system.library,
                library_lock=system.library_lock,
                tracker=system.tracker,
                darwinism=system.darwinism,
                dimensions=system._dimensions,
                n_stripes=system._n_stripes,
                interval_minutes=999,
                engram_path=ep,
            )
            critic._critic_cycle()
            assert Path(ep).exists(), "Critic did not ship engram file"
            assert critic._version == 1

    def test_critic_does_not_grow_library_unboundedly(self):
        from trading.system import AsyncCritic, RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            ep = f"{td}/e.json"
            system = _make_system(f"{td}/t.db", ep)
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=ep,
                reload_interval_s=999999,
            )
            consumer.run(feed=_make_feed(steps=200))
            lib_before = len(system.library)

            critic = AsyncCritic(
                library=system.library,
                library_lock=system.library_lock,
                tracker=system.tracker,
                darwinism=system.darwinism,
                dimensions=system._dimensions,
                n_stripes=system._n_stripes,
                interval_minutes=999,
                engram_path=ep,
            )
            critic._critic_cycle()
            lib_after = len(system.library)
            # Critic prunes / consolidates — library should not grow
            assert lib_after <= lib_before


class TestFullLoop:
    def test_end_to_end_assertions(self):
        """Smoke test: 300 steps, critic fires once, all assertions pass."""
        from trading.system import AsyncCritic, RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            ep = f"{td}/e.json"
            system = _make_system(f"{td}/t.db", ep)

            consumer = RealTimeConsumer(
                encoder=system.encoder,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=ep,
                reload_interval_s=999999,
            )
            consumer.run(feed=_make_feed(steps=150))

            critic = AsyncCritic(
                library=system.library,
                library_lock=system.library_lock,
                tracker=system.tracker,
                darwinism=system.darwinism,
                dimensions=system._dimensions,
                n_stripes=system._n_stripes,
                interval_minutes=999,
                engram_path=ep,
            )
            critic._critic_cycle()

            consumer.run(feed=_make_feed(steps=150, seed=99))

            summary = system.tracker.summary()
            assert summary["decisions"] == 300
            assert critic._version == 1
            assert len(system.library) > 0
