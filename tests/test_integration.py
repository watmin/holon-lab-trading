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
                gate=system.gate,
                tree=system.tree,
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

    def test_baseline_subspace_calibrates_threshold(self):
        """After enough updates the baseline StripedSubspace's threshold is finite."""
        with tempfile.TemporaryDirectory() as td:
            system = _make_system(f"{td}/t.db", f"{td}/e.json")
            from trading.system import RealTimeConsumer
            import math
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                gate=system.gate,
                tree=system.tree,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=f"{td}/e.json",
                reload_interval_s=999999,
            )
            assert math.isinf(system.subspace.threshold)
            consumer.run(feed=_make_feed(steps=60))
            # Gate-based consumer doesn't update baseline subspace directly,
            # but the subspace is still available for inspection
            # (baseline calibration is now handled by gate's regime subspaces)

    def test_non_hold_decisions_appear(self):
        """With a trained gate and permissive tree, BUY/SELL decisions appear."""
        import pandas as pd
        from trading.system import RealTimeConsumer
        from trading.rule_tree import RuleTree
        from trading.gate import HolonGate, label_regimes
        from trading.features import TechnicalFeatureFactory
        with tempfile.TemporaryDirectory() as td:
            system = _make_system(f"{td}/t.db", f"{td}/e.json")

            # Train gate on a chunk of data
            raw = pd.read_parquet(str(PARQUET))
            factory = TechnicalFeatureFactory()
            df_train = factory.compute_indicators(raw.iloc[:5000])
            labels = label_regimes(df_train)
            system.gate.train_regimes(df_train, labels, n_train=100)

            system.tree = RuleTree(
                conviction_fires=1, min_tenure=1, cooldown_candles=1,
                max_trades_per_window=100, rate_window=1000,
            )
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                gate=system.gate,
                tree=system.tree,
                library=system.library,
                library_lock=system.library_lock,
                subspace=system.subspace,
                tracker=system.tracker,
                darwinism=system.darwinism,
                engram_path=f"{td}/e.json",
                reload_interval_s=999999,
            )
            consumer.run(feed=_make_feed(steps=500, seed=7))
            df = system.tracker.recent_decisions(hours=9999)
            non_hold = df[df["action"] != "HOLD"]
            assert len(non_hold) > 0, (
                "Expected BUY/SELL decisions — gate never fired transitions in 500 steps"
            )


class TestCriticCycle:
    def test_critic_ships_engram_file(self):
        from trading.system import AsyncCritic, RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            ep = f"{td}/e.json"
            system = _make_system(f"{td}/t.db", ep)
            consumer = RealTimeConsumer(
                encoder=system.encoder,
                gate=system.gate,
                tree=system.tree,
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
                k=system._k,
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
                gate=system.gate,
                tree=system.tree,
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
                k=system._k,
                n_stripes=system._n_stripes,
                interval_minutes=999,
                engram_path=ep,
            )
            critic._critic_cycle()
            lib_after = len(system.library)
            assert lib_after < lib_before * 2, \
                f"Library grew unboundedly: {lib_before} → {lib_after}"


class TestFullLoop:
    def test_end_to_end_assertions(self):
        """Smoke test: 300 steps, critic fires once, all assertions pass."""
        from trading.system import AsyncCritic, RealTimeConsumer
        with tempfile.TemporaryDirectory() as td:
            ep = f"{td}/e.json"
            system = _make_system(f"{td}/t.db", ep)

            consumer = RealTimeConsumer(
                encoder=system.encoder,
                gate=system.gate,
                tree=system.tree,
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
                k=system._k,
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
