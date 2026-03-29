"""Adaptive Composed Signals — Walk-forward regime-conditional trading.

Architecture:
  1. REGIME SUBSPACE: Trained on early data, detects when market character
     shifts via residual spikes. When residual crosses threshold, flush
     the bias table and re-learn from recent outcomes.

  2. CONTEXT BUCKET: Categorical market state from current candle
     (MA alignment, RSI zone, MACD, trend direction/strength).

  3. ADAPTIVE BIAS TABLE: Rolling window of recent resolved trades.
     For each context bucket, tracks BUY/SELL outcomes. Only trades
     when a bucket has enough history AND sufficient directional bias.

  4. REGIME RESET: When the regime subspace detects an anomaly (high
     residual), the bias table is flushed — old rules don't apply in
     a new regime. Re-learning starts from scratch.

Walk-forward protocol:
  - 2019: Warm up regime subspace (no trading)
  - 2020: Begin building bias table from resolved trades (supervised labels)
  - 2021+: Fully blind — predict, wait for resolution, learn from outcome.
           Oracle labels used ONLY for grading.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/adaptive_composed.py \\
        --workers 6
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from collections import defaultdict, deque
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    StripedSubspace,
)

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import (
    build_categorical_data,
    compute_actual,
    ALL_DB_COLS,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
RESOLUTION_CANDLES = 36
MIN_MOVE_PCT = 1.0


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# =========================================================================
# Context bucketing
# =========================================================================

def context_bucket(c: dict) -> str:
    """Coarse context: 3 binary features = 8 buckets max.

    Keeps buckets fat so we accumulate enough samples
    to measure bias reliably.
    """
    close = sf(c.get("close"))
    sma20 = sf(c.get("sma20"))
    sma200 = sf(c.get("sma200"))
    rsi = sf(c.get("rsi"))

    parts = []
    if close > 0 and sma20 > 0:
        parts.append("C>20" if close > sma20 else "C<20")
    if close > 0 and sma200 > 0:
        parts.append("C>200" if close > sma200 else "C<200")
    if rsi > 0:
        parts.append("RSI+" if rsi >= 50 else "RSI-")

    return "|".join(parts) if parts else "UNK"


# =========================================================================
# Adaptive bias table
# =========================================================================

class AdaptiveBiasTable:
    """Weighted bias table with regime-decay capability.

    Instead of hard resets that nuke all history, regime changes
    apply a decay factor — old observations are down-weighted
    rather than erased. This lets the table adapt to regime shifts
    while retaining useful signal from recent history.
    """

    def __init__(self, min_samples: int,
                 bias_threshold: float, decay_factor: float = 0.5):
        self.min_samples = min_samples
        self.bias_threshold = bias_threshold
        self.decay_factor = decay_factor
        # Weighted counts: {context: {"BUY": float, "SELL": float}}
        self.counts: Dict[str, Dict[str, float]] = defaultdict(
            lambda: {"BUY": 0.0, "SELL": 0.0}
        )
        self.total_obs = 0
        self.decays = 0

    def add(self, context: str, outcome: str):
        if outcome in ("BUY", "SELL"):
            self.counts[context][outcome] += 1.0
            self.total_obs += 1

    def decay(self):
        """Apply decay factor to all weights on regime change."""
        for ctx in self.counts:
            self.counts[ctx]["BUY"] *= self.decay_factor
            self.counts[ctx]["SELL"] *= self.decay_factor
        self.decays += 1

    def predict(self, context: str) -> Optional[str]:
        """Return predicted direction if bias is strong enough, else None."""
        c = self.counts.get(context)
        if c is None:
            return None
        buy = c["BUY"]
        sell = c["SELL"]
        total = buy + sell
        if total < self.min_samples:
            return None
        buy_pct = buy / total
        if buy_pct >= self.bias_threshold:
            return "BUY"
        elif (1 - buy_pct) >= self.bias_threshold:
            return "SELL"
        return None

    def stats(self) -> dict:
        actionable = 0
        active_contexts = 0
        for ctx, c in self.counts.items():
            total = c["BUY"] + c["SELL"]
            if total < self.min_samples:
                continue
            active_contexts += 1
            buy_pct = c["BUY"] / total
            bias = max(buy_pct, 1 - buy_pct)
            if bias >= self.bias_threshold:
                actionable += 1
        return {
            "total_obs": self.total_obs,
            "contexts": len(self.counts),
            "active_contexts": active_contexts,
            "actionable": actionable,
            "decays": self.decays,
        }


# =========================================================================
# Pending trade queue
# =========================================================================

class PendingTrade:
    def __init__(self, queue_idx: int, context: str, prediction: Optional[str]):
        self.queue_idx = queue_idx
        self.context = context
        self.prediction = prediction


# =========================================================================
# Parallel encoding
# =========================================================================

_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    data = build_categorical_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


# =========================================================================
# Main
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--k", type=int, default=20)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--n", type=int, default=None,
                        help="Limit total candles to encode (for quick testing)")
    parser.add_argument("--save-cache", type=str, default=None)
    parser.add_argument("--load-cache", type=str, default=None)
    # Bias table parameters
    parser.add_argument("--min-bucket", type=int, default=8,
                        help="Min weighted samples in a context bucket to trade")
    parser.add_argument("--bias-threshold", type=float, default=0.60,
                        help="Minimum directional bias to act")
    # Regime parameters
    parser.add_argument("--regime-sigma", type=float, default=3.5,
                        help="Sigma multiplier for regime anomaly detection")
    parser.add_argument("--decay", type=float, default=0.5,
                        help="Decay factor on regime change (0=full reset, 1=no effect)")
    args = parser.parse_args()

    log("=" * 80)
    log("ADAPTIVE COMPOSED SIGNALS — Walk-Forward")
    log(f"  {args.stripes}×{args.dims}D, window={args.window}")
    log(f"  Bias: min_bucket={args.min_bucket}, "
        f"threshold={args.bias_threshold:.0%}")
    log(f"  Regime: sigma={args.regime_sigma}, decay={args.decay}")
    log("=" * 80)

    # ------------------------------------------------------------------
    # Load data
    # ------------------------------------------------------------------
    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS + [args.label]:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    # ------------------------------------------------------------------
    # Identify volatile indices (chronological)
    # ------------------------------------------------------------------
    all_indices = []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        all_indices.append(i)

    if args.n:
        all_indices = all_indices[:args.n]

    log(f"Volatile candles: {len(all_indices):,}")

    # Year boundaries
    year_starts = {}
    for idx in all_indices:
        year = candles[idx].get("year")
        if year not in year_starts:
            year_starts[year] = idx
    log(f"Years: {sorted(year_starts.keys())}")

    # ------------------------------------------------------------------
    # Encode all (or load from cache)
    # ------------------------------------------------------------------
    n_stripes = args.stripes
    dim = args.dims

    if args.load_cache:
        log(f"\nLoading cache: {args.load_cache}")
        t_load = time.time()
        cached = np.load(args.load_cache)
        cache_indices = cached["indices"]
        cache_vectors = cached["vectors"]
        n_stripes = cache_vectors.shape[1]
        dim = cache_vectors.shape[2]
        mem_gb = cache_vectors.nbytes / 1e9
        idx_to_pos = {int(cache_indices[i]): i for i in range(len(cache_indices))}
        all_indices = [i for i in all_indices if i in idx_to_pos]
        log(f"  {cache_vectors.shape} {cache_vectors.dtype} ({mem_gb:.1f} GB) "
            f"loaded in {time.time() - t_load:.1f}s, "
            f"using {len(all_indices):,} volatile")
    else:
        _g_candles = candles
        _g_window = args.window
        _g_dim = dim
        _g_stripes = n_stripes

        log(f"\nEncoding ({args.workers} workers) ...")
        t_enc = time.time()
        with mp.Pool(args.workers, initializer=_worker_init) as pool:
            results = []
            done = 0
            for result in pool.imap_unordered(
                _worker_encode, all_indices, chunksize=50
            ):
                results.append(result)
                done += 1
                if done % 5000 == 0:
                    elapsed = time.time() - t_enc
                    rate = done / elapsed
                    remaining = len(all_indices) - done
                    log(f"  {done:,}/{len(all_indices):,} ({rate:.0f}/s) "
                        f"ETA {remaining / rate / 60:.1f}min")

        vec_cache_dict = dict(results)
        log(f"Encoded {len(vec_cache_dict):,} in {time.time() - t_enc:.1f}s")

        if args.save_cache:
            indices_arr = np.array(sorted(vec_cache_dict.keys()), dtype=np.int32)
            vectors_arr = np.stack([vec_cache_dict[i] for i in indices_arr]).astype(np.float32)
            np.savez(args.save_cache, indices=indices_arr, vectors=vectors_arr)
            log(f"Saved cache: {args.save_cache} "
                f"({vectors_arr.nbytes / 1e6:.0f} MB)")

        idx_to_pos = None
        cache_vectors = None

    # ------------------------------------------------------------------
    # Walk-forward: run multiple configs in a single pass
    # ------------------------------------------------------------------
    log(f"\n--- WALK-FORWARD SIMULATION ---")

    configs = [
        ("no_regime",   None,  1.0),   # no decay, no regime signal
        ("decay_0.3",   args.regime_sigma, 0.3),
        ("decay_0.5",   args.regime_sigma, 0.5),
        ("decay_0.7",   args.regime_sigma, 0.7),
        ("no_decay",    args.regime_sigma, 1.0),   # regime detection but no action
    ]

    regime_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)
    tables = {
        name: AdaptiveBiasTable(
            min_samples=args.min_bucket,
            bias_threshold=args.bias_threshold,
            decay_factor=decay,
        )
        for name, _, decay in configs
    }
    pending_queues: Dict[str, deque] = {name: deque() for name, _, _ in configs}
    yearly_stats: Dict[str, Dict[int, Dict[str, int]]] = {
        name: defaultdict(lambda: defaultdict(int)) for name, _, _ in configs
    }

    warmup_year = 2019
    supervised_years = {2019, 2020}

    residual_mean = 0.0
    residual_var = 0.0
    residual_n = 0
    regime_change_count = 0
    total_processed = 0

    t_loop = time.time()
    for idx in all_indices:
        year = candles[idx].get("year")
        ctx = context_bucket(candles[idx])

        if idx_to_pos is not None:
            arr = cache_vectors[idx_to_pos[idx]]
        else:
            arr = vec_cache_dict[idx]
        svecs = [arr[s] for s in range(n_stripes)]

        residual = regime_sub.update(svecs)
        total_processed += 1

        if total_processed == 100:
            elapsed_100 = time.time() - t_loop
            rate = 100 / elapsed_100
            est_total = len(all_indices) / rate / 60
            log(f"  [TIMING] First 100 candles: {elapsed_100:.2f}s "
                f"({rate:.0f}/s, est total: {est_total:.1f} min)")

        residual_n += 1
        if residual_n == 1:
            residual_mean = residual
            residual_var = 0.0
        else:
            old_mean = residual_mean
            residual_mean += (residual - residual_mean) / residual_n
            residual_var += (residual - old_mean) * (residual - residual_mean)

        is_regime_change = False
        if residual_n > 50:
            std = max((residual_var / (residual_n - 1)) ** 0.5, 1e-10)
            threshold = residual_mean + args.regime_sigma * std
            if residual > threshold:
                is_regime_change = True
                regime_change_count += 1

        if year == warmup_year:
            continue

        # Apply regime decay to configs that use it
        if is_regime_change:
            for name, sigma, decay in configs:
                if sigma is not None and decay < 1.0:
                    tables[name].decay()

        # Resolve pending trades
        for name, _, _ in configs:
            pq = pending_queues[name]
            tbl = tables[name]
            ys = yearly_stats[name]
            while pq and (idx - pq[0].queue_idx) >= RESOLUTION_CANDLES:
                trade = pq.popleft()
                actual = compute_actual(candles, trade.queue_idx)
                trade_year = candles[trade.queue_idx].get("year")

                if actual in ("BUY", "SELL"):
                    tbl.add(trade.context, actual)

                if trade.prediction is not None and actual in ("BUY", "SELL"):
                    is_correct = trade.prediction == actual
                    ys[trade_year]["trades"] += 1
                    ys[trade_year]["correct" if is_correct else "wrong"] += 1
                elif actual in ("BUY", "SELL"):
                    ys[trade_year]["skipped"] += 1

        # Oracle learning in supervised years
        if year in supervised_years:
            oracle = candles[idx].get("label_oracle_10")
            if oracle in ("BUY", "SELL"):
                for name in tables:
                    tables[name].add(ctx, oracle)

        # Queue predictions
        for name, _, _ in configs:
            pred = tables[name].predict(ctx)
            pending_queues[name].append(PendingTrade(idx, ctx, pred))

        if total_processed % 5000 == 0:
            stats = tables["decay_0.5"].stats()
            ys05 = yearly_stats["decay_0.5"]
            trades = sum(y.get("trades", 0) for y in ys05.values())
            correct = sum(y.get("correct", 0) for y in ys05.values())
            acc = correct / trades * 100 if trades > 0 else 0
            log(f"  [{year}] {total_processed:,} processed | "
                f"trades={trades} acc={acc:.1f}% | "
                f"obs={stats['total_obs']} act={stats['actionable']}/{stats['contexts']} | "
                f"decays={stats['decays']} regime={regime_change_count}")

    # Drain remaining
    for name, _, _ in configs:
        for trade in pending_queues[name]:
            actual = compute_actual(candles, trade.queue_idx)
            trade_year = candles[trade.queue_idx].get("year")
            if actual in ("BUY", "SELL"):
                tables[name].add(trade.context, actual)
            if trade.prediction is not None and actual in ("BUY", "SELL"):
                is_correct = trade.prediction == actual
                yearly_stats[name][trade_year]["trades"] += 1
                yearly_stats[name][trade_year]["correct" if is_correct else "wrong"] += 1

    # ==================================================================
    # Results
    # ==================================================================
    log(f"\n{'='*70}")
    log("RESULTS")
    log(f"{'='*70}")
    log(f"  Regime changes detected: {regime_change_count} (sigma={args.regime_sigma})")

    for name, sigma, decay in configs:
        ys = yearly_stats[name]
        stats = tables[name].stats()

        log(f"\n  --- {name} (decay={decay}, sigma={'N/A' if sigma is None else sigma}) ---")
        log(f"  Table: {stats['total_obs']} obs, "
            f"{stats['actionable']} actionable, "
            f"{stats['decays']} decays")

        log(f"  {'Year':<6} {'Acc':>7} {'Trades':>8} {'Skipped':>8}")
        all_correct = all_trades = 0
        oos_correct = oos_trades = 0
        for year in sorted(ys.keys()):
            trades = ys[year].get("trades", 0)
            correct = ys[year].get("correct", 0)
            skipped = ys[year].get("skipped", 0)
            acc = correct / trades * 100 if trades > 0 else 0
            marker = " *" if year in supervised_years else ""
            log(f"  {year:<6} {acc:6.1f}% {trades:>8,} {skipped:>8,}{marker}")
            all_correct += correct
            all_trades += trades
            if year not in supervised_years:
                oos_correct += correct
                oos_trades += trades

        all_acc = all_correct / all_trades * 100 if all_trades > 0 else 0
        oos_acc = oos_correct / oos_trades * 100 if oos_trades > 0 else 0
        log(f"  {'ALL':<6} {all_acc:6.1f}% {all_trades:>8,}")
        log(f"  {'OOS':<6} {oos_acc:6.1f}% {oos_trades:>8,}")

    # Summary comparison
    log(f"\n{'='*70}")
    log("SUMMARY")
    log(f"{'='*70}")
    log(f"  {'Config':<15} {'OOS Acc':>9} {'OOS Trades':>11} {'Coverage':>9}")
    total_oos_candles = sum(
        1 for idx in all_indices
        if candles[idx].get("year") not in supervised_years
        and candles[idx].get("year") != warmup_year
    )
    for name, sigma, decay in configs:
        ys = yearly_stats[name]
        oos_trades = sum(ys[y].get("trades", 0)
                         for y in ys if y not in supervised_years)
        oos_correct = sum(ys[y].get("correct", 0)
                          for y in ys if y not in supervised_years)
        oos_acc = oos_correct / oos_trades * 100 if oos_trades > 0 else 0
        coverage = oos_trades / total_oos_candles * 100 if total_oos_candles > 0 else 0
        log(f"  {name:<15} {oos_acc:8.1f}% {oos_trades:>11,} {coverage:8.1f}%")


if __name__ == "__main__":
    main()
