"""Brute-force engram discovery via historical replay.

Runs N random episodes through the encoder + subspace, mints engrams for
surprising patterns, scores them by realized outcomes, and saves the best
as seed_engrams.json for the live system.
"""

from __future__ import annotations

import json
import time

import numpy as np

from holon import HolonClient
from holon.memory import EngramLibrary, OnlineSubspace

from .darwinism import FeatureDarwinism
from .encoder import OHLCVEncoder
from .feed import HistoricalFeed
from .tracker import ExperimentTracker


class DiscoveryHarness:
    """Run brute-force engram discovery on historical data."""

    def __init__(
        self,
        dim: int = 4096,
        k: int = 32,
        initial_usdt: float = 10000.0,
        data_path: str = "data/btc_5m.parquet",
    ):
        self.client = HolonClient(dim=dim)
        self.encoder = OHLCVEncoder(self.client)
        self.library = EngramLibrary(dim=dim)
        self.feed = HistoricalFeed(parquet_path=data_path)
        self.tracker = ExperimentTracker(initial_usdt=initial_usdt)
        self.darwinism = FeatureDarwinism(list(self.encoder.feature_weights.keys()))
        self.dim = dim
        self.k = k
        self._engram_counter = 0

    def run(
        self,
        num_episodes: int = 50,
        episode_length: int = 200,
        window_candles: int = 12,
    ) -> None:
        """Run the full discovery process."""
        self.feed.ensure_data()
        rng = np.random.default_rng(42)

        print(f"Starting discovery: {num_episodes} episodes x {episode_length} steps")

        for ep in range(num_episodes):
            subspace = OnlineSubspace(dim=self.dim, k=self.k)
            ep_engrams = 0
            windows = list(self.feed.random_episode(episode_length, window_candles, rng))

            for step, window_df in enumerate(windows):
                t0 = time.perf_counter()
                vec = self.encoder.encode(window_df)
                latency_ms = (time.perf_counter() - t0) * 1000

                # Try to match existing engrams
                matches = self.library.match(vec, top_k=3)
                action, confidence, used_ids = "HOLD", 0.5, []

                if matches and matches[0][1] < 0.3:
                    name, residual = matches[0]
                    eng = self.library.get(name)
                    if eng and eng.metadata:
                        action = eng.metadata.get("action", "HOLD")
                        confidence = eng.metadata.get("confidence", 0.6)
                        used_ids = [name]
                else:
                    # Update subspace, check for surprise
                    residual_val = subspace.update(vec)
                    if residual_val > subspace.threshold:
                        snap = subspace.snapshot()
                        self._engram_counter += 1
                        name = f"disc_ep{ep}_s{step}_{self._engram_counter}"
                        self.library.add(
                            name,
                            subspace,
                            metadata={"action": "HOLD", "confidence": 0.5, "origin": "discovery"},
                        )
                        ep_engrams += 1

                # Score against next candle
                price = window_df["close"].iloc[-1]
                self.tracker.record(
                    action, confidence, price, latency_ms, used_ids,
                    notes=f"ep={ep},step={step}",
                )

                # Forward-looking score for engram refinement
                if step < len(windows) - 1:
                    next_price = windows[step + 1]["close"].iloc[-1]
                    actual_return = (next_price / price) - 1
                    self._score_used_engrams(used_ids, action, actual_return)

            print(
                f"  Episode {ep + 1}/{num_episodes} | "
                f"engrams minted: {ep_engrams} | "
                f"library size: {len(self.library.names())}"
            )

        self._save_results()

    def _score_used_engrams(
        self, used_ids: list[str], action: str, actual_return: float
    ) -> None:
        """Reinforce or penalize engrams based on realized outcome."""
        for name in used_ids:
            eng = self.library.get(name)
            if eng is None or eng.metadata is None:
                continue

            direction_correct = (
                (action == "BUY" and actual_return > 0)
                or (action == "SELL" and actual_return < 0)
            )
            score = abs(actual_return) * 100 * (1 if direction_correct else -1)

            old_score = eng.metadata.get("score", 0.0)
            eng.metadata["score"] = old_score * 0.7 + score * 0.3
            eng.metadata["last_return"] = actual_return

    def _save_results(self) -> None:
        self.library.save("data/seed_engrams.json")
        self.tracker.export_csv("data/discovery_log.csv")
        self.darwinism.save("data/feature_weights.json")

        summary = self.tracker.summary()
        print("\n=== Discovery Complete ===")
        print(f"  Engrams: {len(self.library.names())}")
        print(f"  Decisions: {summary['decisions']}")
        print(f"  Total return: {summary['total_return']:+.2%}")
        print(f"  Sharpe: {summary['sharpe']:.2f}")
        print(f"  Saved: data/seed_engrams.json, data/discovery_log.csv")

    def results(self) -> dict:
        return {
            "summary": self.tracker.summary(),
            "engram_count": len(self.library.names()),
            "feature_report": self.darwinism.report(),
        }


if __name__ == "__main__":
    harness = DiscoveryHarness()
    harness.run(num_episodes=50, episode_length=200)
