"""Brute-force engram discovery via historical replay.

Runs N random episodes through the encoder + subspace, mints engrams for
surprising patterns, scores them by realized outcomes, and saves the best
as seed_engrams.json for the live system.

Key pattern (from HOLON_CONTEXT.md):
  Score FIRST with subspace.residual(), THEN update with subspace.update().
  Never update before scoring — you'd be measuring yourself.

Engram storage: EngramLibrary.add_striped() / match_striped() — a single
library holds per-stripe snapshots under one name. No N-library workaround.
"""

from __future__ import annotations

import time

import numpy as np

from holon import HolonClient
from holon.memory import EngramLibrary, StripedSubspace

from .darwinism import FeatureDarwinism
from .encoder import OHLCVEncoder
from .feed import HistoricalFeed
from .tracker import ExperimentTracker


class DiscoveryHarness:
    """Run brute-force engram discovery on historical data.

    Each episode:
    1. Random window of historical data → encoder → stripe vectors.
    2. Probe library via match_striped(): low RSS residual → recall action.
    3. No match → score residual FIRST, then update subspace.
    4. If surprising (residual > threshold) → mint via add_striped().
    5. Score decision against next candle's realized return.
    6. After all episodes → save engrams + weights.
    """

    def __init__(
        self,
        dimensions: int = 1024,
        k: int = 4,
        initial_usdt: float = 10_000.0,
        data_path: str = "data/btc_5m.parquet",
        db_path: str = "data/discovery.db",
        save_dir: str = "data",
    ):
        self.client = HolonClient(dimensions=dimensions)
        self.encoder = OHLCVEncoder(self.client)
        self.library = EngramLibrary(dim=dimensions)
        self.feed = HistoricalFeed(parquet_path=data_path)
        self.tracker = ExperimentTracker(initial_usdt=initial_usdt, db_path=db_path)
        self.darwinism = FeatureDarwinism(list(self.encoder.feature_weights.keys()))
        self.dimensions = dimensions
        self.k = k
        self.save_dir = save_dir
        self._engram_counter = 0

    def run(
        self,
        num_episodes: int = 50,
        episode_length: int = 200,
        match_threshold: float = 0.3,
        rng_seed: int = 42,
    ) -> None:
        """Run discovery over num_episodes random historical windows."""
        rng = np.random.default_rng(rng_seed)
        feed_window = OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES

        print(f"Discovery: {num_episodes} episodes × {episode_length} steps")
        print(f"  feed_window={feed_window}, dim={self.dimensions}, k={self.k}")

        for ep in range(num_episodes):
            subspace = StripedSubspace(
                dim=self.dimensions, k=self.k, n_stripes=OHLCVEncoder.N_STRIPES
            )
            ep_engrams = 0
            windows = list(
                self.feed.random_episode(
                    length=episode_length,
                    window=feed_window,
                    rng=rng,
                )
            )

            for step, window_df in enumerate(windows):
                t0 = time.perf_counter()
                stripe_vecs, walkable = self.encoder.encode_with_walkable(window_df)
                encode_ms = (time.perf_counter() - t0) * 1000

                # --- Phase A: probe existing engrams ---
                matches = self.library.match_striped(stripe_vecs, top_k=3)
                action, confidence, used_ids = "HOLD", 0.5, []
                surprise_profile: dict[str, float] = {}

                if matches and matches[0][1] < match_threshold:
                    name, _residual = matches[0]
                    eng = self.library.get(name)
                    if eng and eng.metadata:
                        action = eng.metadata.get("action", "HOLD")
                        confidence = eng.metadata.get("confidence", 0.5)
                        used_ids = [name]

                else:
                    # --- Phase B: score FIRST, then update ---
                    if not np.isinf(subspace.threshold):
                        pre_residual = subspace.residual(stripe_vecs)
                    else:
                        pre_residual = float("inf")

                    subspace.update(stripe_vecs)

                    residual_profile = subspace.residual_profile(stripe_vecs)
                    hot_stripe = int(np.argmax(residual_profile))
                    anomalous = subspace.anomalous_component(stripe_vecs, hot_stripe)
                    surprise_profile = self.encoder.build_surprise_profile(
                        anomalous, hot_stripe, walkable
                    )

                    if (
                        not np.isinf(pre_residual)
                        and not np.isinf(subspace.threshold)
                        and pre_residual > subspace.threshold
                    ):
                        self._engram_counter += 1
                        engram_name = f"disc_ep{ep}_s{step}_{self._engram_counter}"
                        self.library.add_striped(
                            engram_name,
                            subspace,
                            surprise_profile or None,
                            action="HOLD",
                            confidence=0.5,
                            score=0.0,
                            origin="discovery",
                        )
                        ep_engrams += 1

                # --- Record paper trade ---
                price = window_df["close"].iloc[-1]
                self.tracker.record(
                    action, confidence, price,
                    latency_ms=encode_ms,
                    used_engrams=used_ids,
                    notes=f"ep={ep},step={step}",
                )

                # --- Score used engrams + update Darwinism on next candle ---
                if step < len(windows) - 1:
                    next_close = windows[step + 1]["close"].iloc[-1]
                    actual_return = (next_close / price) - 1.0
                    self._score_engrams(used_ids, action, actual_return)
                    if surprise_profile:
                        self.darwinism.update(surprise_profile, actual_return, action)

            print(
                f"  ep {ep + 1:>3}/{num_episodes} | "
                f"minted: {ep_engrams:>3} | "
                f"library: {len(self.library):>4}"
            )

        self._save_results()

    def _score_engrams(
        self, used_ids: list[str], action: str, actual_return: float
    ) -> None:
        """EMA-update each used engram's score from realized return direction."""
        for name in used_ids:
            eng = self.library.get(name)
            if eng is None or eng.metadata is None:
                continue

            direction_correct = (
                (action == "BUY" and actual_return > 0)
                or (action == "SELL" and actual_return < 0)
            )
            score_delta = abs(actual_return) * 100.0 * (1.0 if direction_correct else -1.0)
            old_score = eng.metadata.get("score", 0.0)
            eng.metadata["score"] = old_score * 0.7 + score_delta * 0.3
            eng.metadata["last_return"] = actual_return

    def _save_results(self) -> None:
        import os
        os.makedirs(self.save_dir, exist_ok=True)
        self.library.save(f"{self.save_dir}/seed_engrams.json")
        self.tracker.export_csv(f"{self.save_dir}/discovery_log.csv")
        self.darwinism.save(f"{self.save_dir}/feature_weights.json")

        s = self.tracker.summary()
        print("\n=== Discovery Complete ===")
        print(f"  Engrams minted : {len(self.library)}")
        print(f"  Decisions made : {s['decisions']}")
        print(f"  Total return   : {s['total_return']:+.2%}")
        print(f"  Sharpe         : {s['sharpe']:.3f}")
        print(f"  Saved          : {self.save_dir}/seed_engrams.json")

    def names(self) -> list[str]:
        """Return all engram names."""
        return self.library.names()

    def get_metadata(self, name: str) -> dict | None:
        """Retrieve metadata for a named engram."""
        eng = self.library.get(name)
        return eng.metadata if eng else None

    def results(self) -> dict:
        """Return current state as a plain dict (for tests / inspection)."""
        return {
            "summary": self.tracker.summary(),
            "engram_count": len(self.library),
            "feature_report": self.darwinism.report(),
        }


if __name__ == "__main__":
    harness = DiscoveryHarness()
    harness.run(num_episodes=50, episode_length=200)
