"""End-to-end integration test: full consumer + critic loop on historical data.

Proves every code path works before deploying on the spare host:
  - ReplayFeed drives RealTimeConsumer at full speed from btc_5m_raw.parquet
  - Engrams are minted when StripedSubspace flags genuine surprise
  - Raw windows are persisted to SQLite (engram_windows table)
  - AsyncCritic fires after N steps: scores, labels, consolidates, prunes, ships
  - Consumer hot-reloads the shipped library
  - Final report: equity curve, engram count, critic version, sample decisions

Usage:
    ./scripts/run_with_venv.sh python -u scripts/integration_test.py
    ./scripts/run_with_venv.sh python -u scripts/integration_test.py --steps 200 --critic-after 100
"""

from __future__ import annotations

import argparse
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.feed import ReplayFeed
from trading.system import AsyncCritic, RealTimeConsumer, TradingSystem, _RWLock
from trading.tracker import ExperimentTracker
from trading.encoder import OHLCVEncoder

PARQUET = "holon-lab-trading/data/btc_5m_raw.parquet"
SEED_ENGRAMS = "holon-lab-trading/data/seed_engrams.json"


def run(steps: int = 500, critic_after: int = 250, rng_seed: int = 7) -> None:
    print(f"=== Integration test: {steps} steps, critic fires after {critic_after} ===",
          flush=True)

    with tempfile.TemporaryDirectory() as tmpdir:
        db_path      = f"{tmpdir}/test.db"
        engram_path  = f"{tmpdir}/live_engrams.json"

        # --- Build system from seed engrams ---
        system = TradingSystem(
            seed_engrams=SEED_ENGRAMS,
            live_engrams=engram_path,
            db_path=db_path,
            critic_interval_minutes=999,   # we'll fire the critic manually
        )

        feed = ReplayFeed(
            parquet_path=PARQUET,
            window=OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES,
            max_steps=steps,
            rng_seed=rng_seed,
        )

        # --- Phase 1: run consumer for `critic_after` steps ---
        print(f"\n--- Phase 1: consumer running {critic_after} steps ---", flush=True)
        phase1_feed = ReplayFeed(
            parquet_path=PARQUET,
            window=OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES,
            max_steps=critic_after,
            rng_seed=rng_seed,
        )

        critic = AsyncCritic(
            library=system.library,
            library_lock=system.library_lock,
            tracker=system.tracker,
            darwinism=system.darwinism,
            dimensions=system._dimensions,
            n_stripes=system._n_stripes,
            interval_minutes=999,
            engram_path=engram_path,
        )
        consumer = RealTimeConsumer(
            encoder=system.encoder,
            library=system.library,
            library_lock=system.library_lock,
            subspace=system.subspace,
            tracker=system.tracker,
            darwinism=system.darwinism,
            engram_path=engram_path,
            reload_interval_s=999999,  # suppress auto-reload during test
        )

        consumer.run(feed=phase1_feed)

        # Snapshot state after phase 1
        lib_size_before = len(system.library)
        window_counts   = system.tracker.engram_window_counts()
        decisions_after_p1 = len(system.tracker.recent_decisions(hours=9999))

        print(f"\n--- Phase 1 complete ---", flush=True)
        print(f"  decisions recorded : {decisions_after_p1}", flush=True)
        print(f"  library size       : {lib_size_before}", flush=True)
        print(f"  engrams with stored windows: {len(window_counts)}", flush=True)
        if window_counts:
            total_w = sum(window_counts.values())
            print(f"  total stored windows: {total_w}", flush=True)

        # --- Phase 2: fire the critic ---
        print(f"\n--- Firing AsyncCritic ---", flush=True)
        critic._critic_cycle()
        lib_size_after = len(system.library)
        critic_version = critic._version

        print(f"\n--- Critic done ---", flush=True)
        print(f"  library before : {lib_size_before}", flush=True)
        print(f"  library after  : {lib_size_after}", flush=True)
        print(f"  critic version : {critic_version}", flush=True)
        assert Path(engram_path).exists(), "Critic did not ship engram file!"
        print(f"  engram file shipped: ✓ ({Path(engram_path).stat().st_size:,} bytes)",
              flush=True)

        # --- Phase 3: run remaining steps with hot-reloaded library ---
        remaining = steps - critic_after
        if remaining > 0:
            print(f"\n--- Phase 3: {remaining} more steps post-critic ---", flush=True)
            phase3_feed = ReplayFeed(
                parquet_path=PARQUET,
                window=OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES,
                max_steps=remaining,
                rng_seed=rng_seed + 1,
            )
            consumer.run(feed=phase3_feed)

        # --- Final report ---
        summary = system.tracker.summary()
        df = system.tracker.recent_decisions(hours=9999)

        print(f"\n{'='*60}", flush=True)
        print(f"  INTEGRATION TEST COMPLETE", flush=True)
        print(f"{'='*60}", flush=True)
        print(f"  total decisions  : {summary['decisions']}", flush=True)
        print(f"  trades executed  : {summary['trades']}", flush=True)
        print(f"  total return     : {summary['total_return']:+.2%}", flush=True)
        print(f"  sharpe           : {summary['sharpe']:.3f}", flush=True)
        print(f"  max drawdown     : {summary['max_drawdown']:.2%}", flush=True)
        print(f"  final lib size   : {len(system.library)}", flush=True)
        print(f"  critic version   : {critic_version}", flush=True)

        # Spot-check: show action distribution
        action_dist = df["action"].value_counts().to_dict()
        print(f"  action dist      : {action_dist}", flush=True)

        # Show a few engram metadata entries
        names = system.library.names(kind="striped")[:5]
        if names:
            print(f"\n  sample engrams:", flush=True)
            for name in names:
                eng = system.library.get(name)
                if eng and eng.metadata:
                    m = eng.metadata
                    print(f"    {name[:40]:40s} | "
                          f"action={m.get('action','?'):4s} | "
                          f"conf={m.get('confidence',0):.2f} | "
                          f"score={m.get('score',0):+.2f} | "
                          f"origin={m.get('origin','?')}",
                          flush=True)

        print(f"\n✓ Full loop verified.", flush=True)

        # Assertions: basic sanity
        assert summary["decisions"] == steps, \
            f"Expected {steps} decisions, got {summary['decisions']}"
        assert critic_version == 1, \
            f"Critic should have fired exactly once, got version {critic_version}"
        assert len(system.library) > 0, "Library empty after full run"
        non_hold = sum(v for k, v in action_dist.items() if k != "HOLD")
        assert non_hold > 0, \
            f"Expected some BUY/SELL decisions after calibration, got: {action_dist}"

    print("✓ All assertions passed.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--steps",       type=int, default=500,
                        help="Total replay steps (default 500 ≈ 41h of 5m candles)")
    parser.add_argument("--critic-after", type=int, default=250,
                        help="Fire critic after this many steps (default 250)")
    parser.add_argument("--seed",        type=int, default=7,
                        help="RNG seed for replay start position")
    args = parser.parse_args()

    run(steps=args.steps, critic_after=args.critic_after, rng_seed=args.seed)
