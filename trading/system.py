"""Two-phase self-tuning BTC engram trading system.

Phase 1 (main thread): RealTimeConsumer
  - Encodes live 5m candles via OHLCVEncoder (window-snapshot, StripedSubspace)
  - Probes EngramLibrary for known reversal patterns (match_striped)
  - Papers trades based on recalled action/confidence
  - Mints new engrams on genuine surprise (residual > threshold)
  - Stores raw stripe_vecs in SQLite for later critic consolidation

Phase 2 (daemon thread): AsyncCritic
  - Scores engrams against realized returns; updates action/confidence labels
  - Clusters thin engrams by mutual residual (same manifold = redundant)
  - Consolidates each cluster into one thick regime engram (50-200 samples)
  - Prunes thin originals and weak performers
  - Ships atomically to disk; consumer hot-reloads on next interval

Architecture notes (HOLON_CONTEXT.md):
  - encode_walkable_striped on client.encoder, NOT client
  - Score FIRST (residual), THEN update subspace — never reversed
  - K=32 per stripe dominates quality; DIM barely matters for rank-1 data
  - Engrams are subspace manifolds, not prototypes — consolidation re-trains
    from raw windows, not from averaging snapshot vectors
  - RWLock guards shared EngramLibrary — critic holds write lock during
    consolidation; consumer holds read lock during match/mint
"""

from __future__ import annotations

import json
import math
import os
import signal
import sys
import threading
import time
from pathlib import Path

import numpy as np

from holon import HolonClient
from holon.memory import EngramLibrary, StripedSubspace

from .darwinism import FeatureDarwinism
from .encoder import OHLCVEncoder
from .feed import LiveFeed, ReplayFeed
from .tracker import ExperimentTracker

ENGRAM_PATH  = "data/live_engrams.json"
WEIGHTS_PATH = "data/feature_weights.json"


# ---------------------------------------------------------------------------
# Reader-writer lock for shared EngramLibrary
# ---------------------------------------------------------------------------

class _RWLock:
    """Simple readers-writer lock. Many concurrent readers, exclusive writer."""

    def __init__(self) -> None:
        self._read_ready = threading.Condition(threading.Lock())
        self._readers = 0

    def acquire_read(self) -> None:
        with self._read_ready:
            self._readers += 1

    def release_read(self) -> None:
        with self._read_ready:
            self._readers -= 1
            if self._readers == 0:
                self._read_ready.notify_all()

    def acquire_write(self) -> None:
        self._read_ready.acquire()
        while self._readers > 0:
            self._read_ready.wait()

    def release_write(self) -> None:
        self._read_ready.release()

    class _ReadCtx:
        def __init__(self, lock: "_RWLock") -> None:
            self._lock = lock
        def __enter__(self) -> None:
            self._lock.acquire_read()
        def __exit__(self, *_) -> None:
            self._lock.release_read()

    class _WriteCtx:
        def __init__(self, lock: "_RWLock") -> None:
            self._lock = lock
        def __enter__(self) -> None:
            self._lock.acquire_write()
        def __exit__(self, *_) -> None:
            self._lock.release_write()

    def reading(self) -> "_RWLock._ReadCtx":
        return self._ReadCtx(self)

    def writing(self) -> "_RWLock._WriteCtx":
        return self._WriteCtx(self)


# ---------------------------------------------------------------------------
# Phase 1 — RealTimeConsumer
# ---------------------------------------------------------------------------

class RealTimeConsumer:
    """Consume live feed, encode, recall/mint, paper trade."""

    # match_threshold is auto-calibrated from the first CALIBRATION_STEPS
    # windows. Until then, no engram matches fire (threshold = inf).
    # After calibration, threshold = p25 of observed top-1 residuals.
    CALIBRATION_STEPS = 50

    def __init__(
        self,
        encoder: OHLCVEncoder,
        library: EngramLibrary,
        library_lock: _RWLock,
        subspace: StripedSubspace,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        engram_path: str = ENGRAM_PATH,
        match_threshold: float | None = None,
        reload_interval_s: int = 600,
    ):
        self.encoder = encoder
        self.library = library
        self.library_lock = library_lock
        self.subspace = subspace
        self.tracker = tracker
        self.darwinism = darwinism
        self.engram_path = Path(engram_path)
        # None = auto-calibrate from first CALIBRATION_STEPS windows
        self.match_threshold = match_threshold
        self.reload_interval_s = reload_interval_s
        self._last_reload = time.time()
        self._engram_counter = 0
        self._stop = threading.Event()
        self._calibration_residuals: list[float] = []

    def stop(self) -> None:
        self._stop.set()

    def run(
        self,
        symbol: str = "BTC/USDT",
        timeframe: str = "5m",
        feed=None,
    ) -> None:
        """Run the consumer loop.

        feed: any object with a .stream() -> Iterator[DataFrame] method.
              Defaults to LiveFeed (OKX). Pass a ReplayFeed for local testing.
        """
        if feed is None:
            feed = LiveFeed(symbol=symbol, timeframe=timeframe,
                            window=OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES)
        print(f"[consumer] started: {getattr(feed, 'symbol', 'replay')}", flush=True)
        prev_price: float | None = None

        for window_df in feed.stream():
            if self._stop.is_set():
                break

            t0 = time.perf_counter()
            stripe_vecs, walkable = self.encoder.encode_with_walkable(window_df)
            latency_ms = (time.perf_counter() - t0) * 1000

            action, confidence, used_ids, surprise_profile = self._decide(
                stripe_vecs, walkable
            )

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

            with self.library_lock.reading():
                lib_size = len(self.library)

            print(
                f"[{entry['ts'][-8:]}] {action:4s} | "
                f"conf={confidence:.2f} | "
                f"equity=${entry['equity']:>10,.0f} | "
                f"lat={latency_ms:.0f}ms | "
                f"lib={lib_size}",
                flush=True,
            )

            self._maybe_reload()

    def _decide(
        self,
        stripe_vecs: list[np.ndarray],
        walkable: dict | None = None,
    ) -> tuple[str, float, list[str], dict[str, float]]:
        """Probe library; update subspace; mint on surprise."""
        with self.library_lock.reading():
            matches = self.library.match_striped(stripe_vecs, top_k=3)

        # Auto-calibrate match threshold from first N observations
        if self.match_threshold is None:
            if matches:
                self._calibration_residuals.append(matches[0][1])
            if len(self._calibration_residuals) >= self.CALIBRATION_STEPS:
                # p25 of seen residuals — matches the best-fit quarter of patterns
                self.match_threshold = float(
                    np.percentile(self._calibration_residuals, 25)
                )
                print(
                    f"[consumer] match_threshold calibrated: {self.match_threshold:.2f} "
                    f"(p25 of {len(self._calibration_residuals)} observations)",
                    flush=True,
                )

        if matches and self.match_threshold is not None and matches[0][1] < self.match_threshold:
            name, _res = matches[0]
            with self.library_lock.reading():
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
            surprise_profile = self.encoder.build_surprise_profile(
                anomalous, hot_stripe, walkable
            )

        if (
            not math.isinf(pre_residual)
            and not math.isinf(self.subspace.threshold)
            and pre_residual > self.subspace.threshold
        ):
            self._engram_counter += 1
            engram_name = f"live_{int(time.time())}_{self._engram_counter}"
            # Store raw windows in SQLite BEFORE acquiring write lock on library
            # (store is thread-safe via tracker's internal lock)
            self.tracker.store_engram_windows(engram_name, [stripe_vecs])

            with self.library_lock.writing():
                self.library.add_striped(
                    engram_name,
                    self.subspace,
                    surprise_profile or None,
                    action="HOLD",
                    confidence=0.5,
                    score=0.0,
                    origin="live",
                    minted_at=time.time(),
                )

        return "HOLD", 0.5, [], surprise_profile

    def _maybe_reload(self) -> None:
        """Hot-reload engram library and weights when critic ships a new version."""
        if time.time() - self._last_reload < self.reload_interval_s:
            return
        self._last_reload = time.time()

        if self.engram_path.exists():
            try:
                new_lib = EngramLibrary.load(str(self.engram_path))
                with self.library_lock.writing():
                    # Swap reference — replace contents of shared object
                    self.library.__dict__.update(new_lib.__dict__)
                with self.library_lock.reading():
                    size = len(self.library)
                print(f"[consumer] hot-reloaded engrams ({size})", flush=True)
            except Exception as e:
                print(f"[consumer] engram reload failed: {e}", flush=True)

        weights_path = Path(WEIGHTS_PATH)
        if weights_path.exists():
            try:
                darwin = FeatureDarwinism.load(str(weights_path))
                self.encoder.update_weights(darwin.get_weights())
                print("[consumer] hot-reloaded feature weights", flush=True)
            except Exception as e:
                print(f"[consumer] weight reload failed: {e}", flush=True)


# ---------------------------------------------------------------------------
# Phase 2 — AsyncCritic
# ---------------------------------------------------------------------------

class AsyncCritic(threading.Thread):
    """Background refinement: score → label → consolidate → prune → ship."""

    # Minimum samples in a consolidated subspace before it's considered stable
    MIN_CONSOLIDATION_SAMPLES = 30
    # Mutual-residual threshold below which two engrams are considered redundant
    REDUNDANCY_THRESHOLD = 0.25

    def __init__(
        self,
        library: EngramLibrary,
        library_lock: _RWLock,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        dimensions: int,
        n_stripes: int = OHLCVEncoder.N_STRIPES,
        interval_minutes: int = 30,
        prune_fraction: float = 0.35,
        min_library_size: int = 10,
        engram_path: str = ENGRAM_PATH,
    ):
        super().__init__(daemon=True, name="AsyncCritic")
        self.library = library
        self.library_lock = library_lock
        self.tracker = tracker
        self.darwinism = darwinism
        self.dimensions = dimensions
        self.n_stripes = n_stripes
        self.interval = interval_minutes * 60
        self.prune_fraction = prune_fraction
        self.min_library_size = min_library_size
        self.engram_path = Path(engram_path)
        self._version = 0
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        print(
            f"[critic] started (interval={self.interval // 60}m, "
            f"prune={self.prune_fraction:.0%}, min_lib={self.min_library_size})",
            flush=True,
        )
        while not self._stop.is_set():
            self._stop.wait(timeout=self.interval)
            if self._stop.is_set():
                break
            try:
                self._critic_cycle()
            except Exception as e:
                print(f"[critic] error: {e}", flush=True)

    def _critic_cycle(self) -> None:
        df = self.tracker.recent_decisions(hours=48)
        if len(df) < 20:
            print("[critic] not enough decisions yet, skipping", flush=True)
            return

        print(f"[critic] analyzing {len(df)} decisions...", flush=True)

        # --- 1. Score and label engrams from realized returns ---
        self._score_and_label(df)

        # --- 2. Consolidate redundant thin engrams ---
        n_consolidated = self._consolidate()

        # --- 3. Prune weakest performers ---
        n_pruned = self._prune()

        # --- 4. Ship atomically ---
        self._ship()

        self._version += 1
        with self.library_lock.reading():
            lib_size = len(self.library)
        print(
            f"[critic] v{self._version} shipped | "
            f"lib={lib_size} | "
            f"consolidated={n_consolidated} | "
            f"pruned={n_pruned} | "
            f"pruned_fields={self.darwinism.pruned_fields()}",
            flush=True,
        )

    def _score_and_label(self, df: "pd.DataFrame") -> None:  # noqa: F821
        """Update engram score and promote action/confidence from realized returns."""
        import pandas as pd

        df = df.copy()
        df["used_list"] = df["used_engrams"].apply(
            lambda x: json.loads(x) if isinstance(x, str) else []
        )
        # next-candle realized return as the ground truth signal
        df["actual_return"] = df["price"].pct_change().shift(-1).fillna(0.0)

        with self.library_lock.reading():
            all_names = set(self.library.names(kind="striped"))

        for _, row in df.iterrows():
            for eng_name in row["used_list"]:
                if eng_name not in all_names:
                    continue

                direction_ok = (
                    (row["action"] == "BUY"  and row["actual_return"] > 0)
                    or (row["action"] == "SELL" and row["actual_return"] < 0)
                )
                delta = abs(row["actual_return"]) * 100.0 * (1.0 if direction_ok else -1.0)

                with self.library_lock.reading():
                    eng = self.library.get(eng_name)
                if eng is None or eng.metadata is None:
                    continue

                old_score = eng.metadata.get("score", 0.0)
                new_score = old_score * 0.7 + delta * 0.3
                eng.metadata["score"] = new_score

                # Promote action/confidence once we have enough directional evidence
                # Confidence rises toward 1.0 as score accumulates positively
                if new_score > 2.0 and eng.metadata.get("action", "HOLD") == "HOLD":
                    eng.metadata["action"] = row["action"]
                    eng.metadata["confidence"] = min(0.5 + new_score / 20.0, 0.95)

    def _consolidate(self) -> int:
        """Cluster thin engrams by mutual residual; merge each cluster into one."""
        with self.library_lock.reading():
            names = self.library.names(kind="striped")

        if len(names) < 4:
            return 0

        # Build mutual residual matrix (lower = more similar manifolds)
        residuals: dict[tuple[str, str], float] = {}
        for i, name_a in enumerate(names):
            with self.library_lock.reading():
                eng_a = self.library.get(name_a)
            if eng_a is None:
                continue
            for name_b in names[i + 1:]:
                with self.library_lock.reading():
                    eng_b = self.library.get(name_b)
                if eng_b is None:
                    continue
                try:
                    # Probe each engram's subspace with the other's per-stripe means.
                    # stripe(i).mean is the CCIPCA running mean — a representative
                    # vector in that stripe's space. Low mutual residual → same manifold.
                    means_b = [eng_b._subspace.stripe(i).mean
                                for i in range(self.n_stripes)]
                    means_a = [eng_a._subspace.stripe(i).mean
                                for i in range(self.n_stripes)]
                    r_ab = eng_a.residual_striped(means_b)
                    r_ba = eng_b.residual_striped(means_a)
                    residuals[(name_a, name_b)] = (r_ab + r_ba) / 2.0
                except Exception:
                    pass

        # Single-linkage clustering: group pairs below REDUNDANCY_THRESHOLD
        clusters: list[set[str]] = []
        for (a, b), r in residuals.items():
            if r < self.REDUNDANCY_THRESHOLD:
                merged = False
                for cluster in clusters:
                    if a in cluster or b in cluster:
                        cluster.add(a)
                        cluster.add(b)
                        merged = True
                        break
                if not merged:
                    clusters.append({a, b})

        if not clusters:
            return 0

        n_consolidated = 0
        for cluster in clusters:
            cluster_names = list(cluster)
            # Gather all training windows for this cluster
            all_windows: list[list[np.ndarray]] = []
            for name in cluster_names:
                windows = self.tracker.load_engram_windows(name, self.dimensions)
                all_windows.extend(windows)

            if len(all_windows) < self.MIN_CONSOLIDATION_SAMPLES:
                # Not enough data yet — leave thin engrams alone, accumulate more
                continue

            # Re-train one consolidated subspace from the union of all windows
            ss = StripedSubspace(
                dim=self.dimensions, k=32, n_stripes=self.n_stripes
            )
            for stripe_vecs in all_windows:
                ss.update(stripe_vecs)

            # Derive consolidated metadata from the cluster members
            action_votes: dict[str, float] = {}
            total_score = 0.0
            with self.library_lock.reading():
                for name in cluster_names:
                    eng = self.library.get(name)
                    if eng and eng.metadata:
                        act = eng.metadata.get("action", "HOLD")
                        sc  = eng.metadata.get("score", 0.0)
                        action_votes[act] = action_votes.get(act, 0.0) + max(sc, 0.0)
                        total_score += sc

            best_action = max(action_votes, key=action_votes.get) if action_votes else "HOLD"
            avg_score = total_score / max(len(cluster_names), 1)
            confidence = min(0.5 + avg_score / 20.0, 0.95) if avg_score > 0 else 0.5

            regime_name = f"regime_{int(time.time())}_{n_consolidated}"
            self.tracker.store_engram_windows(regime_name, all_windows)

            with self.library_lock.writing():
                self.library.add_striped(
                    regime_name, ss, None,
                    action=best_action,
                    confidence=confidence,
                    score=avg_score,
                    origin="consolidated",
                    minted_at=time.time(),
                    consolidated_from=cluster_names,
                )
                for name in cluster_names:
                    self.library.remove(name)

            for name in cluster_names:
                self.tracker.delete_engram_windows(name)

            n_consolidated += 1
            print(
                f"[critic] consolidated {len(cluster_names)} → {regime_name} "
                f"({len(all_windows)} windows, action={best_action})",
                flush=True,
            )

        return n_consolidated

    def _prune(self) -> int:
        """Remove lowest-scoring engrams, respecting min_library_size."""
        with self.library_lock.reading():
            all_names = self.library.names(kind="striped")

        if len(all_names) <= self.min_library_size:
            return 0

        scored = []
        for name in all_names:
            with self.library_lock.reading():
                eng = self.library.get(name)
            score = eng.metadata.get("score", 0.0) if (eng and eng.metadata) else 0.0
            scored.append((name, score))

        scored.sort(key=lambda x: x[1])
        prune_n = min(
            int(len(scored) * self.prune_fraction),
            len(scored) - self.min_library_size,
        )

        pruned = 0
        with self.library_lock.writing():
            for name, _ in scored[:prune_n]:
                self.library.remove(name)
                pruned += 1

        for name, _ in scored[:pruned]:
            self.tracker.delete_engram_windows(name)

        return pruned

    def _ship(self) -> None:
        """Atomically write library to disk for consumer hot-reload."""
        os.makedirs(self.engram_path.parent, exist_ok=True)
        tmp = self.engram_path.with_suffix(".tmp")
        with self.library_lock.reading():
            self.library.save(str(tmp))
        tmp.rename(self.engram_path)
        self.darwinism.save(WEIGHTS_PATH)


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

class TradingSystem:
    """Wire up both phases and start them. Handles graceful shutdown."""

    def __init__(
        self,
        dimensions: int = OHLCVEncoder.DEFAULT_DIM,
        k: int = 32,
        n_stripes: int = OHLCVEncoder.N_STRIPES,
        seed_engrams: str = "data/seed_engrams.json",
        live_engrams: str = ENGRAM_PATH,
        db_path: str = "data/live_experiment.db",
        critic_interval_minutes: int = 30,
    ):
        self.client   = HolonClient(dimensions=dimensions)
        self.encoder  = OHLCVEncoder(self.client)
        self.darwinism = FeatureDarwinism(list(self.encoder.feature_weights.keys()))
        self.subspace = StripedSubspace(dim=dimensions, k=k, n_stripes=n_stripes)
        self.tracker  = ExperimentTracker(db_path=db_path)
        self.library_lock = _RWLock()
        self._dimensions = dimensions
        self._n_stripes = n_stripes
        self._critic_interval = critic_interval_minutes
        self._live_engrams = live_engrams

        seed_path = Path(seed_engrams)
        if seed_path.exists():
            self.library = EngramLibrary.load(str(seed_path))
            print(f"[system] loaded {len(self.library)} seed engrams from {seed_path}",
                  flush=True)
        else:
            self.library = EngramLibrary(dim=dimensions)
            print("[system] starting with empty engram library", flush=True)

        weights_path = Path(WEIGHTS_PATH)
        if weights_path.exists():
            self.darwinism = FeatureDarwinism.load(str(weights_path))
            self.encoder.update_weights(self.darwinism.get_weights())
            print("[system] loaded feature weights from previous run", flush=True)

    def start(
        self,
        symbol: str = "BTC/USDT",
        timeframe: str = "5m",
        feed=None,
    ) -> None:
        """Start critic (daemon) then consumer (blocking). Handles SIGTERM/SIGINT.

        feed: optional ReplayFeed (or any .stream() object) for local testing.
              Defaults to LiveFeed against OKX.
        """
        critic = AsyncCritic(
            library=self.library,
            library_lock=self.library_lock,
            tracker=self.tracker,
            darwinism=self.darwinism,
            dimensions=self._dimensions,
            n_stripes=self._n_stripes,
            interval_minutes=self._critic_interval,
            engram_path=self._live_engrams,
        )
        consumer = RealTimeConsumer(
            encoder=self.encoder,
            library=self.library,
            library_lock=self.library_lock,
            subspace=self.subspace,
            tracker=self.tracker,
            darwinism=self.darwinism,
            engram_path=self._live_engrams,
        )

        def _shutdown(signum, frame):
            print(f"\n[system] signal {signum} received — shutting down...", flush=True)
            consumer.stop()
            critic.stop()
            # Final library save before exit
            try:
                self.library.save(self._live_engrams)
                print(f"[system] final library saved ({len(self.library)} engrams)",
                      flush=True)
            except Exception as e:
                print(f"[system] final save failed: {e}", flush=True)
            sys.exit(0)

        signal.signal(signal.SIGTERM, _shutdown)
        signal.signal(signal.SIGINT,  _shutdown)

        critic.start()
        consumer.run(symbol=symbol, timeframe=timeframe, feed=feed)


if __name__ == "__main__":
    # python -u trading/system.py  ← -u for unbuffered stdout (important for systemd logs)
    system = TradingSystem()
    system.start()
