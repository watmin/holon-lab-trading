"""Two-phase self-tuning BTC trading system.

Architecture: Static rule tree with dynamic Holon gate.
  - Holon classifies the current market into regimes (TREND_UP, TREND_DOWN,
    CONSOLIDATION, VOLATILE) using StripedSubspace engrams.
  - When the regime changes, a GateSignal fires into the RuleTree.
  - The RuleTree evaluates the transition type, applies history guards,
    cost gates, and risk checks, then produces BUY/SELL/HOLD.
  - Holon decides *when* to pay attention. The tree decides *what to do*.

Phase 1 (main thread): RealTimeConsumer
  - Encodes live 5m candles and passes to HolonGate for regime classification
  - Gate fires on regime transitions → RuleTree evaluates
  - Records decisions via ExperimentTracker

Phase 2 (daemon thread): AsyncCritic
  - Scores engrams against realized returns; validates/flips action labels
  - Clusters thin engrams by dual-signal similarity (magnitude + direction)
  - Consolidates same-action clusters into thick regime engrams
  - Prunes thin originals and weak performers
  - Ships atomically to disk; consumer hot-reloads on next interval

Core Holon principles enforced:
  - Regime engrams are subspace recognizers, not prototypes
  - Score FIRST, THEN update — never reversed
  - Self-calibrating thresholds from observed data, never hardcoded
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
from .gate import HolonGate, label_regimes
from .rule_tree import RuleTree, TradeAction
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
    """Consume live feed, classify regime via HolonGate, decide via RuleTree.

    Architecture (regime-first, gate + tree):
      1. Receive candle window from feed
      2. Pass to HolonGate for regime classification
      3. If regime transition → GateSignal fires into RuleTree
      4. RuleTree evaluates: transition filter, history guard, cost, risk
      5. Produce BUY/SELL/HOLD action
      6. Record decision and paper-trade via ExperimentTracker
    """

    def __init__(
        self,
        encoder: OHLCVEncoder,
        gate: HolonGate,
        tree: RuleTree,
        library: EngramLibrary,
        library_lock: _RWLock,
        subspace: StripedSubspace,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        engram_path: str = ENGRAM_PATH,
        reload_interval_s: int = 600,
    ):
        self.encoder = encoder
        self.gate = gate
        self.tree = tree
        self.library = library
        self.library_lock = library_lock
        self.subspace = subspace
        self.tracker = tracker
        self.darwinism = darwinism
        self.engram_path = Path(engram_path)
        self.reload_interval_s = reload_interval_s
        self._last_reload = time.time()
        self._step = 0
        self._stop = threading.Event()

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

        for window_df in feed.stream():
            if self._stop.is_set():
                break

            t0 = time.perf_counter()

            # Compute indicators for the window
            from .features import TechnicalFeatureFactory
            factory = TechnicalFeatureFactory()
            df_ind = factory.compute_indicators(window_df)
            if len(df_ind) < self.gate.WINDOW:
                continue

            # Gate: regime classification + transition detection
            idx = len(df_ind) - 1
            signal = self.gate.check(df_ind, idx)

            # Tree: evaluate the signal
            price = float(df_ind.iloc[-1]["close"])
            equity = self.tracker.equity(price)
            self._step += 1
            result = self.tree.evaluate(signal, equity=equity, step=self._step)

            action = result.action.value
            confidence = result.confidence

            latency_ms = (time.perf_counter() - t0) * 1000

            candle_ts_col = "ts" if "ts" in window_df.columns else "timestamp"
            candle_ts = str(window_df[candle_ts_col].iloc[-1]) if candle_ts_col in window_df.columns else None

            notes = ""
            if signal.transition_type:
                notes = f"regime:{signal.transition_type}"

            entry = self.tracker.record(
                action, confidence, price,
                latency_ms=latency_ms,
                candle_ts=candle_ts,
                notes=notes,
            )

            regime_str = signal.current_regime.value[:8]
            print(
                f"[{entry['ts'][-8:]}] {action:4s} | "
                f"regime={regime_str:8s} | "
                f"conf={confidence:.2f} | "
                f"equity=${entry['equity']:>10,.0f} | "
                f"lat={latency_ms:.0f}ms",
                flush=True,
            )

            self._maybe_reload()

    def _maybe_reload(self) -> None:
        """Hot-reload engram library and weights when critic ships a new version."""
        if time.time() - self._last_reload < self.reload_interval_s:
            return
        self._last_reload = time.time()

        if self.engram_path.exists():
            try:
                new_lib = EngramLibrary.load(str(self.engram_path))
                with self.library_lock.writing():
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

    # Minimum samples in a consolidated subspace before it's considered stable.
    # Lower = more aggressive consolidation. 10 gives ~1 match per 200 decisions
    # per engram across a 2k-candle chunk, which is realistic for 33 engrams.
    MIN_CONSOLIDATION_SAMPLES = 10
    # Mutual-residual threshold below which two engrams are considered redundant.
    # This is in RSS space; needs to be calibrated to the actual residual distribution.
    # Set relative to the match_threshold: engrams with mutual residual < 10% of
    # the match threshold are on the same manifold.
    REDUNDANCY_THRESHOLD = 0.25

    def __init__(
        self,
        library: EngramLibrary,
        library_lock: _RWLock,
        tracker: ExperimentTracker,
        darwinism: FeatureDarwinism,
        dimensions: int,
        k: int = 4,
        n_stripes: int = OHLCVEncoder.N_STRIPES,
        interval_minutes: int = 30,
        prune_fraction: float = 0.35,
        min_library_size: int = 10,
        engram_path: str = ENGRAM_PATH,
        score_window_n: int | None = None,
    ):
        """
        score_window_n: if set, critic scores only the last N decisions by step
                        (replay mode). If None, uses hours=48 (live mode).
        """
        super().__init__(daemon=True, name="AsyncCritic")
        self.library = library
        self.library_lock = library_lock
        self.tracker = tracker
        self.darwinism = darwinism
        self.dimensions = dimensions
        self.k = k
        self.n_stripes = n_stripes
        self.interval = interval_minutes * 60
        self.prune_fraction = prune_fraction
        self.min_library_size = min_library_size
        self.engram_path = Path(engram_path)
        self.score_window_n = score_window_n
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
        if self.score_window_n is not None:
            df = self.tracker.recent_decisions(last_n=self.score_window_n)
        else:
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
        """Validate engram actions against realized returns, update scores.

        Engrams are now minted with BUY/SELL labels from the surprise profile.
        The critic validates these labels: correct predictions boost score,
        incorrect predictions penalize. Consistently wrong engrams get their
        action flipped by the labeling logic below.
        """
        import pandas as pd

        df = df.copy()
        df["used_list"] = df["used_engrams"].apply(
            lambda x: json.loads(x) if isinstance(x, str) else []
        )
        if "candle_ts" in df.columns:
            df = df.sort_values("candle_ts").reset_index(drop=True)
        elif "step" in df.columns:
            df = df.sort_values("step").reset_index(drop=True)
        df["actual_return"] = df["price"].pct_change().shift(-1).fillna(0.0)

        with self.library_lock.reading():
            all_names = set(self.library.names(kind="striped"))

        for _, row in df.iterrows():
            for eng_name in row["used_list"]:
                if eng_name not in all_names:
                    continue

                with self.library_lock.reading():
                    eng = self.library.get(eng_name)
                if eng is None or eng.metadata is None:
                    continue

                acted = row["action"]
                ret = row["actual_return"]

                # Score: reward correct direction, punish wrong
                direction_ok = (
                    (acted == "BUY"  and ret > 0)
                    or (acted == "SELL" and ret < 0)
                )
                delta = abs(ret) * 100.0 * (1.0 if direction_ok else -1.0)

                old_score = eng.metadata.get("score", 0.0)
                new_score = old_score * 0.7 + delta * 0.3
                eng.metadata["score"] = new_score

                # Track hit/miss for potential label correction
                hits = eng.metadata.get("hits", 0)
                misses = eng.metadata.get("misses", 0)
                if acted in ("BUY", "SELL"):
                    if direction_ok:
                        eng.metadata["hits"] = hits + 1
                    else:
                        eng.metadata["misses"] = misses + 1

                # Confidence adjusts with accumulated evidence
                total = eng.metadata.get("hits", 0) + eng.metadata.get("misses", 0)
                if total >= 5:
                    hit_rate = eng.metadata.get("hits", 0) / total
                    eng.metadata["confidence"] = min(0.5 + hit_rate * 0.4, 0.95)

                    # Flip label if consistently wrong (hit_rate < 30%)
                    if hit_rate < 0.3 and total >= 10:
                        current = eng.metadata.get("action", "HOLD")
                        if current == "BUY":
                            eng.metadata["action"] = "SELL"
                        elif current == "SELL":
                            eng.metadata["action"] = "BUY"
                        eng.metadata["hits"] = 0
                        eng.metadata["misses"] = 0
                        print(
                            f"[critic] flipped {eng_name} from {current} "
                            f"(hit_rate={hit_rate:.0%} over {total} decisions)",
                            flush=True,
                        )

    def _consolidate(self) -> int:
        """Cluster thin engrams by dual-signal similarity; merge each cluster.

        Uses both magnitude (mutual RSS residual) and direction (residual profile
        cosine alignment) to determine which engrams are truly redundant.
        Only consolidates engrams with the same action label — never merges
        BUY and SELL manifolds.
        """
        with self.library_lock.reading():
            names = self.library.names(kind="striped")

        if len(names) < 4:
            return 0

        # Group by action first — only consolidate within same action
        action_groups: dict[str, list[str]] = {}
        for name in names:
            with self.library_lock.reading():
                eng = self.library.get(name)
            if eng is None or eng.metadata is None:
                continue
            act = eng.metadata.get("action", "HOLD")
            action_groups.setdefault(act, []).append(name)

        n_consolidated = 0
        for action, group_names in action_groups.items():
            if len(group_names) < 2:
                continue
            n_consolidated += self._consolidate_group(group_names, action)
        return n_consolidated

    def _consolidate_group(self, names: list[str], action: str) -> int:
        """Consolidate within a single action group using dual-signal similarity."""
        # Build pairwise similarity: mutual residual + profile alignment
        similarities: dict[tuple[str, str], float] = {}
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
                    sub_a = eng_a.subspace
                    sub_b = eng_b.subspace
                    means_b = [sub_b.stripe(j).mean for j in range(self.n_stripes)]
                    means_a = [sub_a.stripe(j).mean for j in range(self.n_stripes)]

                    # Magnitude: mutual RSS residual
                    r_ab = eng_a.residual_striped(means_b)
                    r_ba = eng_b.residual_striped(means_a)
                    mutual_residual = (r_ab + r_ba) / 2.0

                    # Direction: profile alignment
                    profile_a = sub_a.residual_profile(means_b)
                    profile_b = sub_b.residual_profile(means_a)
                    pa_norm = float(np.linalg.norm(profile_a))
                    pb_norm = float(np.linalg.norm(profile_b))
                    if pa_norm > 0 and pb_norm > 0:
                        alignment = float(
                            np.dot(profile_a, profile_b) / (pa_norm * pb_norm)
                        )
                    else:
                        alignment = 0.0

                    # Combined score: low residual AND high alignment → similar
                    # We store both for the threshold computation
                    similarities[(name_a, name_b)] = (mutual_residual, alignment)
                except Exception:
                    pass

        if not similarities:
            return 0

        # Data-relative threshold: p25 of mutual residuals AND alignment > 0.7
        all_residuals = [r for r, _ in similarities.values()]
        residual_cutoff = float(np.percentile(all_residuals, 25))

        clusters: list[set[str]] = []
        for (a, b), (res, align) in similarities.items():
            if res < residual_cutoff and align > 0.7:
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
            all_windows: list[list[np.ndarray]] = []
            for name in cluster_names:
                windows = self.tracker.load_engram_windows(name, self.dimensions)
                all_windows.extend(windows)

            if len(all_windows) < self.MIN_CONSOLIDATION_SAMPLES:
                continue

            ss = StripedSubspace(
                dim=self.dimensions, k=self.k, n_stripes=self.n_stripes
            )
            for stripe_vecs in all_windows:
                ss.update(stripe_vecs)

            total_score = 0.0
            with self.library_lock.reading():
                for name in cluster_names:
                    eng = self.library.get(name)
                    if eng and eng.metadata:
                        total_score += eng.metadata.get("score", 0.0)

            avg_score = total_score / max(len(cluster_names), 1)
            confidence = min(0.5 + abs(avg_score) / 20.0, 0.95) if avg_score > 0 else 0.5

            regime_name = f"regime_{int(time.time())}_{n_consolidated}"
            self.tracker.store_engram_windows(regime_name, all_windows)

            with self.library_lock.writing():
                self.library.add_striped(
                    regime_name, ss, None,
                    action=action,
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
                f"({len(all_windows)} windows, action={action})",
                flush=True,
            )

        return n_consolidated

    def _prune(self) -> int:
        """Remove engrams with clearly negative scores, respecting min_library_size.

        Only prunes engrams with score < -1.0 that have been seen enough to
        have a reliable score (stored window count >= 3). This prevents the
        library from being eaten alive before engrams accumulate feedback.
        """
        with self.library_lock.reading():
            all_names = self.library.names(kind="striped")

        if len(all_names) <= self.min_library_size:
            return 0

        window_counts = self.tracker.engram_window_counts()
        candidates_to_prune = []
        for name in all_names:
            with self.library_lock.reading():
                eng = self.library.get(name)
            if eng is None or eng.metadata is None:
                continue
            score = eng.metadata.get("score", 0.0)
            seen = window_counts.get(name, 0)
            # Only prune if: clearly negative score AND seen enough times
            if score < -1.0 and seen >= 3:
                candidates_to_prune.append((name, score))

        # Sort worst-first, cap at prune_fraction of library, preserve min_size
        candidates_to_prune.sort(key=lambda x: x[1])
        max_prune = max(0, len(all_names) - self.min_library_size)
        prune_n = min(
            int(len(all_names) * self.prune_fraction),
            len(candidates_to_prune),
            max_prune,
        )

        to_prune = candidates_to_prune[:prune_n]
        pruned = 0
        with self.library_lock.writing():
            for name, _ in to_prune:
                self.library.remove(name)
                pruned += 1

        for name, _ in to_prune[:pruned]:
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
    """Wire up gate, tree, consumer, and critic. Handles graceful shutdown."""

    ANOMALY_SIGMA = 3.5

    def __init__(
        self,
        dimensions: int = OHLCVEncoder.DEFAULT_DIM,
        k: int = 4,
        n_stripes: int = OHLCVEncoder.N_STRIPES,
        seed_engrams: str = "data/seed_engrams.json",
        live_engrams: str = ENGRAM_PATH,
        db_path: str = "data/live_experiment.db",
        critic_interval_minutes: int = 30,
        anomaly_sigma: float | None = None,
        gate: HolonGate | None = None,
        tree: RuleTree | None = None,
    ):
        self.client   = HolonClient(dimensions=dimensions)
        self.encoder  = OHLCVEncoder(self.client)
        self.darwinism = FeatureDarwinism(list(self.encoder.feature_weights.keys()))
        sigma = anomaly_sigma if anomaly_sigma is not None else self.ANOMALY_SIGMA
        self.subspace = StripedSubspace(
            dim=dimensions, k=k, n_stripes=n_stripes, sigma_mult=sigma
        )
        self.tracker  = ExperimentTracker(db_path=db_path)
        self.library_lock = _RWLock()
        self._dimensions = dimensions
        self._k = k
        self._n_stripes = n_stripes
        self._critic_interval = critic_interval_minutes
        self._live_engrams = live_engrams

        self.gate = gate if gate is not None else HolonGate(self.client)
        self.tree = tree if tree is not None else RuleTree()

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
            k=self._k,
            n_stripes=self._n_stripes,
            interval_minutes=self._critic_interval,
            engram_path=self._live_engrams,
        )
        consumer = RealTimeConsumer(
            encoder=self.encoder,
            gate=self.gate,
            tree=self.tree,
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
