"""Two-phase self-tuning BTC engram trading system.

Phase 1 (main thread): RealTimeConsumer — encode live candles, recall engrams,
                        paper trade, mint new engrams on surprise.
Phase 2 (daemon thread): AsyncCritic — score decisions, prune weak engrams,
                          ship updated library, hot-reload weights.

Engram storage: single EngramLibrary using add_striped() / match_striped().
One JSON file holds all stripe snapshots per engram. No per-stripe library hack.

Design notes (HOLON_CONTEXT.md):
- encode_walkable_striped is on client.encoder, NOT client
- Score FIRST with subspace.residual(), THEN call subspace.update()
- EngramLibrary.add_striped() takes StripedSubspace directly
- EngramLibrary.match_striped() returns RSS residual across all stripes
- StripedSubspace does not have .eigenvalues — add_striped handles per-stripe internally
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import numpy as np

from holon import HolonClient
from holon.memory import EngramLibrary, StripedSubspace

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
        subspace: StripedSubspace,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        engram_path: str = ENGRAM_PATH,
        match_threshold: float = 0.3,
        reload_interval_s: int = 600,
    ):
        self.encoder = encoder
        self.library = library
        self.subspace = subspace
        self.tracker = tracker
        self.darwinism = darwinism
        self.engram_path = Path(engram_path)
        self.match_threshold = match_threshold
        self.reload_interval_s = reload_interval_s
        self._last_reload = time.time()
        self._engram_counter = 0

    def run(self, symbol: str = "BTC/USDT", timeframe: str = "5m") -> None:
        feed = LiveFeed(symbol=symbol, timeframe=timeframe, window=OHLCVEncoder.LOOKBACK_CANDLES)
        print(f"Phase 1 started: real-time consumer on {timeframe} {symbol}")
        prev_price: float | None = None

        for window_df in feed.stream():
            t0 = time.perf_counter()
            stripe_vecs, walkable = self.encoder.encode_with_walkable(window_df)
            latency_ms = (time.perf_counter() - t0) * 1000

            action, confidence, used_ids, surprise_profile = self._decide(stripe_vecs, walkable)

            price = float(window_df["close"].iloc[-1])
            entry = self.tracker.record(
                action, confidence, price,
                latency_ms=latency_ms,
                used_engrams=used_ids,
            )

            if prev_price is not None and surprise_profile:
                actual_return = (price / prev_price) - 1.0
                self.darwinism.update(surprise_profile, actual_return, action)
                self.encoder.update_weights(self.darwinism.get_weights())

            prev_price = price

            print(
                f"[{entry['ts'][-8:]}] {action:4s} | "
                f"conf={confidence:.2f} | "
                f"equity=${entry['equity']:>10,.0f} | "
                f"lat={latency_ms:.0f}ms | "
                f"lib={len(self.library)}"
            )

            self._maybe_reload()

    def _decide(
        self, stripe_vecs: list[np.ndarray], walkable: dict | None = None
    ) -> tuple[str, float, list[str], dict[str, float]]:
        """Probe library; if no match, update subspace and maybe mint."""
        import math

        matches = self.library.match_striped(stripe_vecs, top_k=3)

        if matches and matches[0][1] < self.match_threshold:
            name, _res = matches[0]
            eng = self.library.get(name)
            if eng and eng.metadata:
                return (
                    eng.metadata.get("action", "HOLD"),
                    eng.metadata.get("confidence", 0.5),
                    [name],
                    {},
                )

        pre_residual = (
            self.subspace.residual(stripe_vecs)
            if not math.isinf(self.subspace.threshold)
            else float("inf")
        )
        self.subspace.update(stripe_vecs)

        surprise_profile: dict[str, float] = {}
        if walkable is not None:
            rp = self.subspace.residual_profile(stripe_vecs)
            hot_stripe = int(np.argmax(rp))
            anomalous = self.subspace.anomalous_component(stripe_vecs, hot_stripe)
            surprise_profile = self.encoder.build_surprise_profile(anomalous, hot_stripe, walkable)

        if (
            not math.isinf(pre_residual)
            and not math.isinf(self.subspace.threshold)
            and pre_residual > self.subspace.threshold
        ):
            self._engram_counter += 1
            engram_name = f"live_{int(time.time())}_{self._engram_counter}"
            self.library.add_striped(
                engram_name,
                self.subspace,
                surprise_profile or None,
                action="HOLD",
                confidence=0.5,
                score=0.0,
                origin="live",
            )

        return "HOLD", 0.5, [], surprise_profile

    def _maybe_reload(self) -> None:
        """Hot-reload engram library and weights if critic shipped a new version."""
        if time.time() - self._last_reload < self.reload_interval_s:
            return
        self._last_reload = time.time()

        if self.engram_path.exists():
            try:
                self.library = EngramLibrary.load(str(self.engram_path))
                print(f"Hot-reloaded engrams ({len(self.library)} engrams)")
            except Exception as e:
                print(f"Engram reload failed: {e}")

        weights_path = Path(WEIGHTS_PATH)
        if weights_path.exists():
            try:
                darwin = FeatureDarwinism.load(str(weights_path))
                self.encoder.update_weights(darwin.get_weights())
                print("Hot-reloaded feature weights")
            except Exception as e:
                print(f"Weight reload failed: {e}")


class AsyncCritic(threading.Thread):
    """Phase 2: background refinement loop — score, prune, ship."""

    def __init__(
        self,
        library: EngramLibrary,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        interval_minutes: int = 30,
        prune_fraction: float = 0.35,
        min_library_size: int = 10,
        engram_path: str = ENGRAM_PATH,
    ):
        super().__init__(daemon=True, name="AsyncCritic")
        self.library = library
        self.tracker = tracker
        self.darwinism = darwinism
        self.interval = interval_minutes * 60
        self.prune_fraction = prune_fraction
        self.min_library_size = min_library_size
        self.engram_path = Path(engram_path)
        self._version = 0

    def run(self) -> None:
        print(f"Phase 2 started: async critic (interval={self.interval // 60}m)")
        while True:
            time.sleep(self.interval)
            try:
                self._critic_cycle()
            except Exception as e:
                print(f"Critic error: {e}")

    def _critic_cycle(self) -> None:
        df = self.tracker.recent_decisions(hours=48)
        if len(df) < 20:
            print("Critic: not enough decisions yet, skipping")
            return

        print(f"Critic analyzing {len(df)} decisions...")

        df = df.copy()
        df["used_list"] = df["used_engrams"].apply(
            lambda x: json.loads(x) if isinstance(x, str) else []
        )
        df["actual_return"] = df["price"].pct_change().shift(-1).fillna(0.0)

        for _, row in df.iterrows():
            for eng_name in row["used_list"]:
                eng = self.library.get(eng_name)
                if eng is None or eng.metadata is None:
                    continue
                direction_ok = (
                    (row["action"] == "BUY" and row["actual_return"] > 0)
                    or (row["action"] == "SELL" and row["actual_return"] < 0)
                )
                delta = abs(row["actual_return"]) * 100.0 * (1.0 if direction_ok else -1.0)
                old = eng.metadata.get("score", 0.0)
                eng.metadata["score"] = old * 0.7 + delta * 0.3

        # Prune weakest engrams
        all_names = self.library.names(kind="striped")
        if len(all_names) > self.min_library_size:
            scored = [
                (n, self.library.get(n).metadata.get("score", 0.0)
                 if self.library.get(n) and self.library.get(n).metadata else 0.0)
                for n in all_names
            ]
            scored.sort(key=lambda x: x[1])
            prune_n = min(
                int(len(scored) * self.prune_fraction),
                len(scored) - self.min_library_size,
            )
            for name, _ in scored[:prune_n]:
                self.library.remove(name)

        # Ship atomically
        self._version += 1
        import os
        os.makedirs(self.engram_path.parent, exist_ok=True)
        tmp = self.engram_path.with_suffix(".tmp")
        self.library.save(str(tmp))
        tmp.rename(self.engram_path)
        self.darwinism.save(WEIGHTS_PATH)

        print(
            f"Critic v{self._version} shipped | "
            f"engrams={len(self.library)} | "
            f"pruned_fields={self.darwinism.pruned_fields()}"
        )


class TradingSystem:
    """One-command orchestrator: wires up both phases and starts them."""

    def __init__(
        self,
        dimensions: int = OHLCVEncoder.DEFAULT_DIM,
        k: int = 16,
        seed_engrams: str = "data/seed_engrams.json",
        live_engrams: str = ENGRAM_PATH,
        db_path: str = "data/live_experiment.db",
    ):
        self.client = HolonClient(dimensions=dimensions)
        self.encoder = OHLCVEncoder(self.client)
        self.darwinism = FeatureDarwinism(list(self.encoder.feature_weights.keys()))
        self.subspace = StripedSubspace(
            dim=dimensions, k=k, n_stripes=OHLCVEncoder.N_STRIPES
        )
        self.tracker = ExperimentTracker(db_path=db_path)

        seed_path = Path(seed_engrams)
        if seed_path.exists():
            self.library = EngramLibrary.load(str(seed_path))
            print(f"Loaded {len(self.library)} seed engrams from {seed_path}")
        else:
            self.library = EngramLibrary(dim=dimensions)
            print("Starting with empty engram library")

        weights_path = Path(WEIGHTS_PATH)
        if weights_path.exists():
            self.darwinism = FeatureDarwinism.load(str(weights_path))
            self.encoder.update_weights(self.darwinism.get_weights())
            print("Loaded feature weights from previous run")

        self._live_engrams = live_engrams

    def start(self, symbol: str = "BTC/USDT", timeframe: str = "5m") -> None:
        """Start critic (daemon) then consumer (blocking main thread)."""
        critic = AsyncCritic(
            library=self.library,
            tracker=self.tracker,
            darwinism=self.darwinism,
            engram_path=self._live_engrams,
        )
        consumer = RealTimeConsumer(
            encoder=self.encoder,
            library=self.library,
            subspace=self.subspace,
            tracker=self.tracker,
            darwinism=self.darwinism,
            engram_path=self._live_engrams,
        )

        critic.start()
        consumer.run(symbol=symbol, timeframe=timeframe)


if __name__ == "__main__":
    system = TradingSystem()
    system.start()
