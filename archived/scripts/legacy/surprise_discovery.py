"""Surprise-Driven Fact Discovery

Train a "normal market" subspace on 2019 data, then use recursive
surprise_fingerprint (drilldown probe) to identify which encoded facts
are anomalously different at BUY vs SELL moments in 2020.

This mirrors the spectral firewall architecture: learn the subspace of
normal, measure residual anomaly, attribute it to specific fields.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/surprise_discovery.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/surprise_discovery.py --quick 2000
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent.parent))

from categorical_refine import ALL_DB_COLS, build_categorical_data, sf

from holon import DeterministicVectorManager, Encoder
from holon.memory.subspace import OnlineSubspace

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# =========================================================================
# Recursive drilldown probe (from spectral firewall batch 018)
# =========================================================================

def _drilldown_probe(anomaly: np.ndarray, data, vm) -> List[Tuple[str, float]]:
    """Recursively probe each leaf-level field for anomaly attribution.

    Walks the data structure the same way the encoder does:
    - Map keys:  unbind with key role vector
    - List items: unbind with position vector
    - Sets: unbind with set_indicator, then each member
    - Scalars: leaf — measure norm

    Returns [(path, norm), ...] for every leaf.
    """
    results = []

    def _walk(current_anomaly, d, path_prefix):
        if isinstance(d, dict):
            for key, value in d.items():
                role_vec = vm.get_vector(str(key))
                child_anomaly = role_vec * current_anomaly
                child_path = f"{path_prefix}.{key}" if path_prefix else str(key)
                _walk(child_anomaly, value, child_path)

        elif isinstance(d, (set, frozenset)):
            set_indicator = vm.get_vector("set_indicator")
            set_anomaly = set_indicator * current_anomaly
            for item in sorted(d):
                item_vec = vm.get_vector(str(item))
                item_anomaly = item_vec * set_anomaly
                norm = float(np.linalg.norm(item_anomaly))
                results.append((f"{path_prefix}.{item}", norm))

        elif isinstance(d, list):
            for i, item in enumerate(d):
                pos_vec = vm.get_position_vector(i)
                child_anomaly = pos_vec * current_anomaly
                child_path = f"{path_prefix}.[{i}]"
                _walk(child_anomaly, item, child_path)

        elif isinstance(d, bool):
            norm = float(np.linalg.norm(current_anomaly))
            results.append((path_prefix, norm))

        else:
            norm = float(np.linalg.norm(current_anomaly))
            results.append((path_prefix, norm))

    _walk(anomaly, data, "")
    return results


def surprise_fingerprint(vec, subspace, data, vm):
    """Compute per-leaf anomaly attribution via recursive drilldown."""
    anomaly = subspace.anomalous_component(vec)
    probes = _drilldown_probe(anomaly, data, vm)

    total = sum(norm for _, norm in probes)
    if total < 1e-12:
        return []

    scored = []
    for path, norm in probes:
        scored.append({"path": path, "raw": norm, "share": norm / total})

    scored.sort(key=lambda x: x["raw"], reverse=True)
    return scored


# =========================================================================
# Main
# =========================================================================

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=8192,
                        help="Higher dims = less cross-talk in drilldown")
    parser.add_argument("--k", type=int, default=32,
                        help="Principal components for normal-market subspace")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--n-train", type=int, default=None,
                        help="Limit training candles (None = all 2019)")
    parser.add_argument("--n-probe", type=int, default=3000,
                        help="Max BUY/SELL candles to probe each")
    parser.add_argument("--quick", type=int, default=None,
                        help="Quick mode: N train + N/5 probe per class")
    args = parser.parse_args()

    if args.quick:
        args.n_train = args.quick
        args.n_probe = max(args.quick // 5, 200)

    log("=" * 70)
    log("SURPRISE-DRIVEN FACT DISCOVERY")
    log(f"  dims={args.dims}, k={args.k}, window={args.window}")
    log(f"  n_train={args.n_train or 'all'}, n_probe={args.n_probe}")
    log("=" * 70)

    # ------------------------------------------------------------------
    # Load candles
    # ------------------------------------------------------------------
    conn = sqlite3.connect(str(DB_PATH))
    cols_str = ", ".join(ALL_DB_COLS)
    rows = conn.execute(
        f"SELECT {cols_str} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{ALL_DB_COLS[j]: r[j] for j in range(len(ALL_DB_COLS))}
               for r in rows]
    log(f"Loaded {len(candles):,} candles ({len(ALL_DB_COLS)} columns)")

    # ------------------------------------------------------------------
    # Split indices
    # ------------------------------------------------------------------
    train_indices = []
    probe_buy = []
    probe_sell = []

    for i in range(args.window - 1, len(candles)):
        year = candles[i].get("year")
        label = candles[i].get("label_oracle_10")
        atr_r = candles[i].get("atr_r") or 0

        if year == 2019:
            train_indices.append(i)
        elif year == 2020 and atr_r > args.vol_threshold:
            if label == "BUY":
                probe_buy.append(i)
            elif label == "SELL":
                probe_sell.append(i)

    if args.n_train and len(train_indices) > args.n_train:
        train_indices = train_indices[:args.n_train]

    rng = np.random.default_rng(42)
    if len(probe_buy) > args.n_probe:
        probe_buy = list(rng.choice(probe_buy, args.n_probe, replace=False))
    if len(probe_sell) > args.n_probe:
        probe_sell = list(rng.choice(probe_sell, args.n_probe, replace=False))

    log(f"Train (2019): {len(train_indices):,}")
    log(f"Probe BUY (2020 volatile): {len(probe_buy):,}")
    log(f"Probe SELL (2020 volatile): {len(probe_sell):,}")

    # ------------------------------------------------------------------
    # Phase 1: Encode & train normal-market subspace
    # ------------------------------------------------------------------
    vm = DeterministicVectorManager(dimensions=args.dims)
    encoder = Encoder(vm)
    subspace = OnlineSubspace(dim=args.dims, k=args.k, amnesia=2.0)

    log(f"\nPhase 1: Training normal-market subspace on {len(train_indices):,} candles...")
    t0 = time.time()

    for step, idx in enumerate(train_indices):
        data = build_categorical_data(candles, idx, args.window)
        vec = encoder.encode_walkable(data)
        subspace.update(vec)

        if (step + 1) % 2000 == 0:
            elapsed = time.time() - t0
            rate = (step + 1) / elapsed
            remaining = len(train_indices) - step - 1
            log(f"  {step+1:,}/{len(train_indices):,} ({rate:.0f}/s) "
                f"ETA {remaining / rate:.0f}s")

    train_time = time.time() - t0
    log(f"  Done in {train_time:.1f}s — n={subspace.n}, "
        f"threshold={subspace.threshold:.2f}")
    eig = subspace.eigenvalues[:8]
    log(f"  Top eigenvalues: [{', '.join(f'{e:.1f}' for e in eig)}]")

    # ------------------------------------------------------------------
    # Phase 2: Probe BUY and SELL candles
    # ------------------------------------------------------------------
    log(f"\nPhase 2: Probing BUY and SELL candles with surprise_fingerprint...")

    buy_profiles: Dict[str, List[float]] = defaultdict(list)
    sell_profiles: Dict[str, List[float]] = defaultdict(list)

    for label_name, indices, profiles in [
        ("BUY", probe_buy, buy_profiles),
        ("SELL", probe_sell, sell_profiles),
    ]:
        t0 = time.time()
        for step, idx in enumerate(indices):
            data = build_categorical_data(candles, idx, args.window)
            vec = encoder.encode_walkable(data)
            scored = surprise_fingerprint(vec, subspace, data, vm)

            for entry in scored:
                profiles[entry["path"]].append(entry["share"])

            if (step + 1) % 500 == 0:
                elapsed = time.time() - t0
                rate = (step + 1) / elapsed
                log(f"  [{label_name}] {step+1:,}/{len(indices):,} "
                    f"({rate:.0f}/s, {len(profiles):,} paths)")

        elapsed = time.time() - t0
        log(f"  [{label_name}] Done: {len(indices):,} in {elapsed:.1f}s, "
            f"{len(profiles):,} unique paths")

    # ------------------------------------------------------------------
    # Phase 3: Compare BUY vs SELL anomaly profiles
    # ------------------------------------------------------------------
    log(f"\nPhase 3: Comparing BUY vs SELL anomaly profiles...")

    all_paths = set(buy_profiles.keys()) | set(sell_profiles.keys())
    results = []

    for path in all_paths:
        buy_vals = buy_profiles.get(path, [])
        sell_vals = sell_profiles.get(path, [])

        if len(buy_vals) < 10 or len(sell_vals) < 10:
            continue

        buy_arr = np.array(buy_vals)
        sell_arr = np.array(sell_vals)

        buy_mean = float(np.mean(buy_arr))
        sell_mean = float(np.mean(sell_arr))
        buy_std = float(np.std(buy_arr, ddof=1))
        sell_std = float(np.std(sell_arr, ddof=1))

        pooled_std = np.sqrt((buy_std ** 2 + sell_std ** 2) / 2)
        d = abs(buy_mean - sell_mean) / pooled_std if pooled_std > 1e-10 else 0.0

        direction = "BUY>" if buy_mean > sell_mean else "SELL>"

        results.append({
            "path": path,
            "cohens_d": d,
            "direction": direction,
            "buy_mean": buy_mean,
            "sell_mean": sell_mean,
            "buy_std": buy_std,
            "sell_std": sell_std,
            "buy_n": len(buy_vals),
            "sell_n": len(sell_vals),
        })

    results.sort(key=lambda x: x["cohens_d"], reverse=True)

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------
    log(f"\n{'=' * 70}")
    log("TOP 40 DISCRIMINATIVE FACTS (by Cohen's d)")
    log(f"{'=' * 70}")
    log(f"{'Path':<55} {'d':>6} {'Dir':>5} "
        f"{'BUY_mu':>8} {'SELL_mu':>8} {'BUY_n':>6} {'SELL_n':>6}")
    log("-" * 100)

    for r in results[:40]:
        log(f"{r['path']:<55} {r['cohens_d']:6.3f} {r['direction']:>5} "
            f"{r['buy_mean']:8.5f} {r['sell_mean']:8.5f} "
            f"{r['buy_n']:6} {r['sell_n']:6}")

    high_d = [r for r in results if r["cohens_d"] > 0.5]
    med_d = [r for r in results if 0.2 < r["cohens_d"] <= 0.5]
    low_d = [r for r in results if r["cohens_d"] <= 0.2]

    log(f"\n  Total fact paths analyzed: {len(results)}")
    log(f"  Cohen's d > 0.5 (large effect): {len(high_d)}")
    log(f"  Cohen's d 0.2-0.5 (medium):     {len(med_d)}")
    log(f"  Cohen's d < 0.2 (small/none):    {len(low_d)}")

    if high_d:
        log(f"\n  === HIGH-SIGNAL FACTS (d > 0.5) ===")
        for r in high_d:
            log(f"    {r['path']}: d={r['cohens_d']:.3f} ({r['direction']})")

    # Conditional key analysis: which conditional facts appear
    # more at BUY vs SELL?
    cond_keys = [
        "oversold", "overbought", "bb_breakout_up", "bb_breakout_down",
        "macd_cross_bull", "macd_cross_bear", "volume_spike",
        "stoch_oversold", "stoch_overbought",
        "williams_oversold", "williams_overbought",
        "cci_oversold", "cci_overbought",
        "mfi_oversold", "mfi_overbought",
        "squeeze_active", "engulfing_bull", "engulfing_bear",
        "return_extreme_up", "return_extreme_down",
        "vol_extreme", "streak_up", "streak_down",
        "higher_high", "lower_low",
    ]

    log(f"\n{'=' * 70}")
    log("CONDITIONAL KEY PRESENCE ANALYSIS")
    log(f"{'=' * 70}")
    log(f"  These keys are ONLY present when their condition is true.")
    log(f"  Presence rate difference between BUY and SELL moments:")
    log(f"  {'Key':<30} {'BUY%':>7} {'SELL%':>7} {'Diff':>7}")
    log(f"  {'-'*55}")

    for key in cond_keys:
        buy_count = 0
        sell_count = 0
        for path in all_paths:
            if path.endswith(f".{key}"):
                buy_count += len(buy_profiles.get(path, []))
                sell_count += len(sell_profiles.get(path, []))

        total_buy = len(probe_buy) * args.window
        total_sell = len(probe_sell) * args.window
        buy_pct = buy_count / total_buy * 100 if total_buy > 0 else 0
        sell_pct = sell_count / total_sell * 100 if total_sell > 0 else 0
        diff = buy_pct - sell_pct

        if abs(diff) > 0.1:
            marker = " ***" if abs(diff) > 2.0 else " *" if abs(diff) > 1.0 else ""
            log(f"  {key:<30} {buy_pct:6.2f}% {sell_pct:6.2f}% "
                f"{diff:+6.2f}%{marker}")

    if not high_d and not med_d:
        log(f"\n  CONCLUSION: No discriminative facts found in anomalous component.")
        log(f"  TA indicators carry no directional information even in the")
        log(f"  out-of-subspace residual. Need different features entirely.")
    elif high_d:
        log(f"\n  CONCLUSION: Found {len(high_d)} high-signal facts!")
        log(f"  The subspace residual contains directional information.")
        log(f"  Proceed to Phase 2 (engram pattern library).")
    else:
        log(f"\n  CONCLUSION: Found {len(med_d)} medium-signal facts.")
        log(f"  Marginal signal exists — may be exploitable with engrams.")


if __name__ == "__main__":
    main()
