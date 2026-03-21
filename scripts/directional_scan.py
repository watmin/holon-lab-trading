"""Scan all features for BUY vs SELL directional separation during high-volatility.

Filters to high-vol candles (atr_r > threshold), then for each feature computes:
  - Mean/std for BUY vs SELL oracle labels
  - Cohen's d (effect size)
  - AUC (area under ROC curve) for BUY vs SELL classification
  - Edge at various thresholds (what % are BUY vs SELL when feature is extreme)

Outputs ranked tables showing which features carry the most directional signal.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/directional_scan.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/directional_scan.py --label label_oracle_10
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/directional_scan.py --vol-threshold 0.003
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/directional_scan.py --years 2021-2024
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

import numpy as np

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

SKIP_COLS = {
    "ts", "open", "high", "low", "close", "volume",
    "sma20", "sma50", "sma200",
    "bb_upper", "bb_lower",
    "macd_line", "macd_signal", "macd_hist",
    "atr", "range_raw",
    "label_oracle_02", "label_oracle_05", "label_oracle_10", "label_oracle_20",
    "year", "hour", "dow",
}


def get_feature_cols(conn: sqlite3.Connection) -> list[str]:
    cursor = conn.execute("PRAGMA table_info(candles)")
    cols = [row[1] for row in cursor.fetchall()]
    return [c for c in cols if c not in SKIP_COLS]


def cohens_d(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = len(a), len(b)
    if na < 2 or nb < 2:
        return 0.0
    pooled_std = np.sqrt(((na - 1) * a.std(ddof=1)**2 + (nb - 1) * b.std(ddof=1)**2) / (na + nb - 2))
    if pooled_std < 1e-12:
        return 0.0
    return (a.mean() - b.mean()) / pooled_std


def auc_mannwhitney(a: np.ndarray, b: np.ndarray, max_sample: int = 50000) -> float:
    """Fast AUC via Mann-Whitney U statistic. > 0.5 means feature is higher for group A."""
    if len(a) < 10 or len(b) < 10:
        return 0.5
    if len(a) > max_sample:
        a = np.random.choice(a, max_sample, replace=False)
    if len(b) > max_sample:
        b = np.random.choice(b, max_sample, replace=False)
    combined = np.concatenate([a, b])
    labels = np.concatenate([np.ones(len(a)), np.zeros(len(b))])
    order = combined.argsort()
    labels = labels[order]
    ranks = np.arange(1, len(combined) + 1)
    r1 = ranks[labels == 1].sum()
    n1, n2 = len(a), len(b)
    u = r1 - n1 * (n1 + 1) / 2
    return u / (n1 * n2)


def edge_at_extremes(vals: np.ndarray, labels: np.ndarray, feature: str) -> list[dict]:
    """Compute BUY vs SELL edge at percentile extremes of a feature."""
    results = []
    for pct, direction in [(10, "low"), (25, "low"), (75, "high"), (90, "high")]:
        threshold = np.percentile(vals, pct)
        if direction == "low":
            mask = vals <= threshold
        else:
            mask = vals >= threshold
        sub_labels = labels[mask]
        n = len(sub_labels)
        if n < 50:
            continue
        n_buy = (sub_labels == "BUY").sum()
        n_sell = (sub_labels == "SELL").sum()
        total = n_buy + n_sell
        if total == 0:
            continue
        buy_pct = n_buy / total * 100
        sell_pct = n_sell / total * 100
        edge = buy_pct - sell_pct
        results.append({
            "feature": feature,
            "filter": f"p{pct} {direction}",
            "threshold": threshold,
            "n": n,
            "buy%": buy_pct,
            "sell%": sell_pct,
            "edge": edge,
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="label_oracle_05", help="Oracle label column")
    parser.add_argument("--vol-threshold", type=float, default=0.002, help="atr_r threshold for high-vol filter")
    parser.add_argument("--years", default=None, help="Year range, e.g. 2021-2024")
    parser.add_argument("--no-vol-filter", action="store_true", help="Skip volatility filter")
    parser.add_argument("--top", type=int, default=30, help="Show top N features")
    args = parser.parse_args()

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    feature_cols = get_feature_cols(conn)
    print(f"Scanning {len(feature_cols)} features for BUY vs SELL separation")
    print(f"Label: {args.label}, Vol filter: {'OFF' if args.no_vol_filter else f'atr_r > {args.vol_threshold}'}")

    where = f"{args.label} IN ('BUY', 'SELL')"
    if not args.no_vol_filter:
        where += f" AND atr_r > {args.vol_threshold}"
    if args.years:
        y1, y2 = args.years.split("-")
        where += f" AND year BETWEEN {y1} AND {y2}"

    cols_str = ", ".join(feature_cols + [args.label, "year"])
    query = f"SELECT {cols_str} FROM candles WHERE {where}"
    print(f"Query: SELECT ... FROM candles WHERE {where}")

    rows = conn.execute(query).fetchall()
    n_total = len(rows)
    print(f"Loaded {n_total:,} rows")

    if n_total < 100:
        print("Too few rows for analysis")
        return

    labels = np.array([r[args.label] for r in rows])
    n_buy = (labels == "BUY").sum()
    n_sell = (labels == "SELL").sum()
    base_buy_pct = n_buy / (n_buy + n_sell) * 100
    print(f"  BUY: {n_buy:,} ({base_buy_pct:.1f}%)  SELL: {n_sell:,} ({100 - base_buy_pct:.1f}%)")
    print()

    # --- Per-feature analysis ---
    results = []
    all_edges = []

    for col in feature_cols:
        vals = np.array([r[col] if r[col] is not None else 0.0 for r in rows], dtype=float)
        buy_vals = vals[labels == "BUY"]
        sell_vals = vals[labels == "SELL"]

        d = cohens_d(buy_vals, sell_vals)
        auc = auc_mannwhitney(buy_vals, sell_vals)

        results.append({
            "feature": col,
            "buy_mean": buy_vals.mean(),
            "sell_mean": sell_vals.mean(),
            "cohen_d": d,
            "auc": auc,
            "auc_dist": abs(auc - 0.5),
        })

        edges = edge_at_extremes(vals, labels, col)
        all_edges.extend(edges)

    # --- Rank by AUC distance from 0.5 ---
    results.sort(key=lambda r: r["auc_dist"], reverse=True)

    print("=" * 100)
    print(f"TOP {args.top} FEATURES BY AUC (BUY vs SELL directional separation)")
    print("=" * 100)
    print(f"{'Feature':<25} {'AUC':>6} {'Cohen d':>9} {'BUY mean':>12} {'SELL mean':>12} {'Direction':<12}")
    print("-" * 100)
    for r in results[:args.top]:
        direction = "BUY higher" if r["auc"] > 0.5 else "SELL higher"
        print(f"{r['feature']:<25} {r['auc']:>6.4f} {r['cohen_d']:>+9.4f} {r['buy_mean']:>12.6f} {r['sell_mean']:>12.6f} {direction:<12}")

    # --- Edge at extremes (top findings) ---
    all_edges.sort(key=lambda e: abs(e["edge"]), reverse=True)
    print()
    print("=" * 100)
    print(f"TOP {args.top} DIRECTIONAL EDGES AT FEATURE EXTREMES")
    print("(Edge = BUY% - SELL%.  Positive = BUY-favored, Negative = SELL-favored)")
    print("=" * 100)
    print(f"{'Feature':<25} {'Filter':<12} {'Threshold':>10} {'N':>8} {'BUY%':>7} {'SELL%':>7} {'Edge':>8}")
    print("-" * 100)
    for e in all_edges[:args.top]:
        print(f"{e['feature']:<25} {e['filter']:<12} {e['threshold']:>10.4f} {e['n']:>8,} {e['buy%']:>7.1f} {e['sell%']:>7.1f} {e['edge']:>+8.1f}")

    # --- Year stability check for top 10 ---
    print()
    print("=" * 100)
    print("YEAR STABILITY: Top 10 features AUC by year")
    print("=" * 100)
    top10 = [r["feature"] for r in results[:10]]
    header = f"{'Feature':<25}"
    years = sorted(set(int(r["year"]) for r in rows))
    for y in years:
        header += f" {y:>6}"
    print(header)
    print("-" * (25 + 7 * len(years)))

    for col in top10:
        vals = np.array([r[col] if r[col] is not None else 0.0 for r in rows], dtype=float)
        line = f"{col:<25}"
        for y in years:
            yr_mask = np.array([int(r["year"]) == y for r in rows])
            yr_labels = labels[yr_mask]
            yr_vals = vals[yr_mask]
            buy_v = yr_vals[yr_labels == "BUY"]
            sell_v = yr_vals[yr_labels == "SELL"]
            yr_auc = auc_mannwhitney(buy_v, sell_v)
            line += f" {yr_auc:>6.3f}"
        print(line)

    # --- Combination scan: find 2-feature combos that amplify edge ---
    print()
    print("=" * 100)
    print("COMBINATION EDGES: Top features paired for amplified directional signal")
    print("=" * 100)
    top_features = [r["feature"] for r in results[:15]]
    combo_results = []

    for i, f1 in enumerate(top_features):
        v1 = np.array([r[f1] if r[f1] is not None else 0.0 for r in rows], dtype=float)
        med1 = np.median(v1)
        auc1 = results[i]["auc"]
        f1_high_is_buy = auc1 > 0.5

        for j, f2 in enumerate(top_features):
            if j <= i:
                continue
            v2 = np.array([r[f2] if r[f2] is not None else 0.0 for r in rows], dtype=float)
            med2 = np.median(v2)
            auc2 = next(r["auc"] for r in results if r["feature"] == f2)
            f2_high_is_buy = auc2 > 0.5

            # Try: f1 favors BUY direction AND f2 favors BUY direction
            if f1_high_is_buy:
                buy_mask = v1 > np.percentile(v1, 75)
            else:
                buy_mask = v1 < np.percentile(v1, 25)
            if f2_high_is_buy:
                buy_mask &= v2 > np.percentile(v2, 75)
            else:
                buy_mask &= v2 < np.percentile(v2, 25)

            sub = labels[buy_mask]
            n = len(sub)
            if n < 100:
                continue
            nb = (sub == "BUY").sum()
            ns = (sub == "SELL").sum()
            total = nb + ns
            if total == 0:
                continue
            buy_pct = nb / total * 100
            edge = buy_pct - base_buy_pct

            # Also try SELL direction
            if f1_high_is_buy:
                sell_mask = v1 < np.percentile(v1, 25)
            else:
                sell_mask = v1 > np.percentile(v1, 75)
            if f2_high_is_buy:
                sell_mask &= v2 < np.percentile(v2, 25)
            else:
                sell_mask &= v2 > np.percentile(v2, 75)

            sub_s = labels[sell_mask]
            n_s = len(sub_s)
            if n_s >= 100:
                nb_s = (sub_s == "BUY").sum()
                ns_s = (sub_s == "SELL").sum()
                total_s = nb_s + ns_s
                if total_s > 0:
                    sell_pct = ns_s / total_s * 100
                    sell_edge = sell_pct - (100 - base_buy_pct)
                    combo_results.append({
                        "combo": f"{f1} + {f2}",
                        "direction": "SELL",
                        "n": n_s,
                        "pct": sell_pct,
                        "edge": sell_edge,
                    })

            combo_results.append({
                "combo": f"{f1} + {f2}",
                "direction": "BUY",
                "n": n,
                "pct": buy_pct,
                "edge": edge,
            })

    combo_results.sort(key=lambda c: abs(c["edge"]), reverse=True)
    print(f"{'Combo':<50} {'Dir':<5} {'N':>8} {'Hit%':>7} {'Edge':>8}")
    print("-" * 100)
    for c in combo_results[:40]:
        print(f"{c['combo']:<50} {c['direction']:<5} {c['n']:>8,} {c['pct']:>7.1f} {c['edge']:>+8.1f}")

    conn.close()


if __name__ == "__main__":
    main()
