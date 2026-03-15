"""Two-phase self-tuning BTC engram trading system.

Phase 1 (main thread): Real-time consumer — encode, recall, paper trade.
Phase 2 (daemon thread): Async critic — score, prune, refine, ship.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import numpy as np
import pandas as pd

from holon import HolonClient
from holon.memory import EngramLibrary, OnlineSubspace

from .darwinism import FeatureDarwinism
from .encoder import OHLCVEncoder
from .feed import LiveFeed
from .tracker import ExperimentTracker

ENGRAM_PATH = "data/live_engrams.json"
WEIGHTS_PATH = "data/feature_weights.json"


class RealTimeConsumer:
    """Phase 1: consume live feed, encode, recall/mint, paper trade."""

    def __init__(
        self,
        encoder: OHLCVEncoder,
        library: EngramLibrary,
        subspace: OnlineSubspace,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        engram_path: str = ENGRAM_PATH,
    ):
        self.encoder = encoder
        self.library = library
        self.subspace = subspace
        self.tracker = tracker
        self.darwinism = darwinism
        self.engram_path = Path(engram_path)
        self._lib_version = 0
        self._last_reload = time.time()
        self._engram_counter = 0

    def run(self) -> None:
        feed = LiveFeed()
        print("Phase 1 started: real-time consumer on 5m BTC")

        for window_df in feed.stream():
            t0 = time.perf_counter()
            vec = self.encoder.encode(window_df)
            latency_ms = (time.perf_counter() - t0) * 1000

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
                residual_val = self.subspace.update(vec)
                if residual_val > self.subspace.threshold:
                    self._engram_counter += 1
                    name = f"live_{int(time.time())}_{self._engram_counter}"
                    self.library.add(
                        name,
                        self.subspace,
                        metadata={"action": "HOLD", "confidence": 0.5, "origin": "live"},
                    )

            price = window_df["close"].iloc[-1]
            entry = self.tracker.record(
                action, confidence, price, latency_ms, used_ids
            )

            equity = entry["equity"]
            print(
                f"[{entry['ts'][-8:]}] {action:4s} | "
                f"conf={confidence:.2f} | "
                f"equity=${equity:,.0f} | "
                f"latency={latency_ms:.0f}ms | "
                f"engrams={len(self.library.names())}"
            )

            self._maybe_reload()

    def _maybe_reload(self) -> None:
        """Hot-reload engram library if critic shipped a new version."""
        if time.time() - self._last_reload < 600:
            return
        self._last_reload = time.time()

        if not self.engram_path.exists():
            return

        try:
            new_lib = EngramLibrary.load(str(self.engram_path))
            self.library = new_lib
            print(f"Hot-reloaded engrams ({len(new_lib.names())} engrams)")
        except Exception as e:
            print(f"Reload failed: {e}")

        if Path(WEIGHTS_PATH).exists():
            try:
                darwin = FeatureDarwinism.load(WEIGHTS_PATH)
                self.encoder.update_weights(darwin.get_weights())
                print("Hot-reloaded feature weights")
            except Exception:
                pass


class AsyncCritic(threading.Thread):
    """Phase 2: background refinement loop."""

    def __init__(
        self,
        library: EngramLibrary,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        interval_minutes: int = 30,
        engram_path: str = ENGRAM_PATH,
    ):
        super().__init__(daemon=True)
        self.library = library
        self.tracker = tracker
        self.darwinism = darwinism
        self.interval = interval_minutes * 60
        self.engram_path = Path(engram_path)
        self._version = 0

    def run(self) -> None:
        print(f"Phase 2 started: async critic (every {self.interval // 60} min)")
        while True:
            time.sleep(self.interval)
            try:
                self._critic_cycle()
            except Exception as e:
                print(f"Critic error: {e}")

    def _critic_cycle(self) -> None:
        df = self.tracker.recent_decisions(hours=48)
        if len(df) < 20:
            return

        print(f"Critic analyzing {len(df)} recent decisions...")

        # Parse used engrams from each decision
        df["used_list"] = df["used_engrams"].apply(
            lambda x: json.loads(x) if isinstance(x, str) else []
        )

        # Approximate actual returns from consecutive prices
        df["actual_return"] = df["price"].pct_change().shift(-1).fillna(0)

        # Score engrams by realized outcome
        for _, row in df.iterrows():
            for eng_name in row["used_list"]:
                eng = self.library.get(eng_name)
                if eng is None or eng.metadata is None:
                    continue

                direction_ok = (
                    (row["action"] == "BUY" and row["actual_return"] > 0)
                    or (row["action"] == "SELL" and row["actual_return"] < 0)
                )
                score = abs(row["actual_return"]) * 100 * (1 if direction_ok else -1)
                old = eng.metadata.get("score", 0.0)
                eng.metadata["score"] = old * 0.7 + score * 0.3

        # Prune low-scoring engrams
        all_names = list(self.library.names())
        if len(all_names) > 20:
            scored = []
            for name in all_names:
                eng = self.library.get(name)
                s = eng.metadata.get("score", 0.0) if eng and eng.metadata else 0.0
                scored.append((name, s))
            scored.sort(key=lambda x: x[1])
            prune_count = int(len(scored) * 0.35)
            for name, _ in scored[:prune_count]:
                self.library.remove(name)

        # Ship updated library
        self._version += 1
        tmp = self.engram_path.with_suffix(".tmp")
        self.library.save(str(tmp))
        tmp.rename(self.engram_path)

        self.darwinism.save(WEIGHTS_PATH)

        print(
            f"Critic shipped v{self._version} | "
            f"engrams={len(self.library.names())} | "
            f"pruned fields={self.darwinism.pruned_fields()}"
        )


class TradingSystem:
    """One-command orchestrator: loads engrams, starts both phases."""

    def __init__(
        self,
        dim: int = 4096,
        k: int = 32,
        engram_path: str = ENGRAM_PATH,
    ):
        self.client = HolonClient(dim=dim)
        self.encoder = OHLCVEncoder(self.client)
        self.darwinism = FeatureDarwinism(list(self.encoder.feature_weights.keys()))
        self.subspace = OnlineSubspace(dim=dim, k=k)
        self.tracker = ExperimentTracker(db_path="data/live_experiment.db")

        engram_file = Path(engram_path)
        if engram_file.exists():
            self.library = EngramLibrary.load(str(engram_file))
            print(f"Loaded {len(self.library.names())} seed engrams")
        else:
            self.library = EngramLibrary(dim=dim)
            print("Starting with empty engram library")

        if Path(WEIGHTS_PATH).exists():
            self.darwinism = FeatureDarwinism.load(WEIGHTS_PATH)
            self.encoder.update_weights(self.darwinism.get_weights())
            print("Loaded feature weights from previous run")

    def start(self) -> None:
        """Start both phases. Blocks on Phase 1 (main thread)."""
        critic = AsyncCritic(
            self.library, self.tracker, self.darwinism
        )
        consumer = RealTimeConsumer(
            self.encoder, self.library, self.subspace,
            self.tracker, self.darwinism,
        )

        critic.start()
        consumer.run()


if __name__ == "__main__":
    system = TradingSystem()
    system.start()
