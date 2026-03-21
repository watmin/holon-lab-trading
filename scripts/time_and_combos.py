"""Deep dive into time effects and multi-feature combos for directional edge.

Investigates:
1. Hour-of-day BUY vs SELL distribution
2. Day-of-week BUY vs SELL distribution
3. 3-feature combo scan on top candidates
4. Stability of best combos across years

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/time_and_combos.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/time_and_combos.py --label label_oracle_10
"""

from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path

import numpy as np

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row

    vol_filter = f"AND atr_r > {args.vol_threshold}"

    # ========================================================================
    # 1. HOUR OF DAY
    # ========================================================================
    print("=" * 90)
    print("HOUR OF DAY: BUY vs SELL distribution (high-vol candles)")
    print("=" * 90)
    rows = conn.execute(f"""
        SELECT hour,
               SUM(CASE WHEN {args.label} = 'BUY' THEN 1 ELSE 0 END) as n_buy,
               SUM(CASE WHEN {args.label} = 'SELL' THEN 1 ELSE 0 END) as n_sell,
               COUNT(*) as n_total
        FROM candles
        WHERE {args.label} IN ('BUY', 'SELL') {vol_filter}
        GROUP BY hour ORDER BY hour
    """).fetchall()

    overall_buy_pct = sum(r["n_buy"] for r in rows) / sum(r["n_buy"] + r["n_sell"] for r in rows) * 100

    print(f"{'Hour':>4} {'N':>8} {'BUY':>7} {'SELL':>7} {'BUY%':>7} {'Edge':>7}")
    print("-" * 50)
    for r in rows:
        total = r["n_buy"] + r["n_sell"]
        buy_pct = r["n_buy"] / total * 100
        edge = buy_pct - overall_buy_pct
        marker = " ***" if abs(edge) > 2 else ""
        print(f"{r['hour']:>4} {total:>8,} {r['n_buy']:>7,} {r['n_sell']:>7,} {buy_pct:>7.1f} {edge:>+7.1f}{marker}")

    # ========================================================================
    # 2. DAY OF WEEK
    # ========================================================================
    print()
    print("=" * 90)
    print("DAY OF WEEK: BUY vs SELL distribution (high-vol candles)")
    print("=" * 90)
    days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    rows = conn.execute(f"""
        SELECT dow,
               SUM(CASE WHEN {args.label} = 'BUY' THEN 1 ELSE 0 END) as n_buy,
               SUM(CASE WHEN {args.label} = 'SELL' THEN 1 ELSE 0 END) as n_sell
        FROM candles
        WHERE {args.label} IN ('BUY', 'SELL') {vol_filter}
        GROUP BY dow ORDER BY dow
    """).fetchall()

    print(f"{'Day':>4} {'N':>8} {'BUY':>7} {'SELL':>7} {'BUY%':>7} {'Edge':>7}")
    print("-" * 50)
    for r in rows:
        total = r["n_buy"] + r["n_sell"]
        buy_pct = r["n_buy"] / total * 100
        edge = buy_pct - overall_buy_pct
        marker = " ***" if abs(edge) > 1.5 else ""
        print(f"{days[r['dow']]:>4} {total:>8,} {r['n_buy']:>7,} {r['n_sell']:>7,} {buy_pct:>7.1f} {edge:>+7.1f}{marker}")

    # ========================================================================
    # 3. HOUR x DOW interaction
    # ========================================================================
    print()
    print("=" * 90)
    print("HOUR x DOW: Top BUY-favored and SELL-favored slots")
    print("=" * 90)
    rows = conn.execute(f"""
        SELECT hour, dow,
               SUM(CASE WHEN {args.label} = 'BUY' THEN 1 ELSE 0 END) as n_buy,
               SUM(CASE WHEN {args.label} = 'SELL' THEN 1 ELSE 0 END) as n_sell
        FROM candles
        WHERE {args.label} IN ('BUY', 'SELL') {vol_filter}
        GROUP BY hour, dow
        HAVING (n_buy + n_sell) > 200
        ORDER BY hour, dow
    """).fetchall()

    slots = []
    for r in rows:
        total = r["n_buy"] + r["n_sell"]
        buy_pct = r["n_buy"] / total * 100
        edge = buy_pct - overall_buy_pct
        slots.append({
            "hour": r["hour"], "dow": r["dow"],
            "n": total, "buy_pct": buy_pct, "edge": edge
        })

    slots.sort(key=lambda s: s["edge"], reverse=True)
    print("BUY-favored slots:")
    print(f"{'Day':>4} {'Hour':>5} {'N':>7} {'BUY%':>7} {'Edge':>7}")
    print("-" * 35)
    for s in slots[:10]:
        print(f"{days[s['dow']]:>4} {s['hour']:>5} {s['n']:>7,} {s['buy_pct']:>7.1f} {s['edge']:>+7.1f}")

    print("\nSELL-favored slots:")
    print(f"{'Day':>4} {'Hour':>5} {'N':>7} {'BUY%':>7} {'Edge':>7}")
    print("-" * 35)
    for s in slots[-10:]:
        print(f"{days[s['dow']]:>4} {s['hour']:>5} {s['n']:>7,} {s['buy_pct']:>7.1f} {s['edge']:>+7.1f}")

    # ========================================================================
    # 4. YEAR STABILITY of time effects
    # ========================================================================
    print()
    print("=" * 90)
    print("YEAR STABILITY: Does the DOW edge persist across years?")
    print("=" * 90)
    rows = conn.execute(f"""
        SELECT year, dow,
               SUM(CASE WHEN {args.label} = 'BUY' THEN 1 ELSE 0 END) as n_buy,
               SUM(CASE WHEN {args.label} = 'SELL' THEN 1 ELSE 0 END) as n_sell
        FROM candles
        WHERE {args.label} IN ('BUY', 'SELL') {vol_filter}
        GROUP BY year, dow
        ORDER BY year, dow
    """).fetchall()

    by_year = {}
    for r in rows:
        y = r["year"]
        if y not in by_year:
            by_year[y] = {}
        total = r["n_buy"] + r["n_sell"]
        by_year[y][r["dow"]] = r["n_buy"] / total * 100 if total > 0 else 50

    years = sorted(by_year.keys())
    header = f"{'Day':>4}"
    for y in years:
        header += f" {y:>7}"
    print(header)
    print("-" * (4 + 8 * len(years)))
    for d in range(7):
        line = f"{days[d]:>4}"
        for y in years:
            v = by_year[y].get(d, 50)
            line += f" {v:>7.1f}"
        print(line)

    # ========================================================================
    # 5. MULTI-FEATURE COMBOS (top candidates from directional scan)
    # ========================================================================
    print()
    print("=" * 90)
    print("3-FEATURE COMBO SCAN (for 1% moves in high vol)")
    print("=" * 90)

    combo_features = [
        "sma_cross_50_200", "sma200_r", "ema100_r",
        "dmi_plus", "dmi_minus",
        "rsi", "trend_consistency_24", "tf_4h_body",
        "macd_line_r", "ema_cross_9_21",
        "kelt_pos", "range_pos_48",
        "dow_sin", "hour_cos",
    ]

    # For each feature, know if high = BUY or high = SELL
    buy_high = {
        "sma_cross_50_200", "sma200_r", "ema100_r",
        "dmi_plus", "rsi", "trend_consistency_24", "tf_4h_body",
        "macd_line_r", "ema_cross_9_21",
        "kelt_pos", "range_pos_48",
        "dow_sin",
    }

    cols_str = ", ".join(combo_features + [args.label, "year"])
    rows = conn.execute(f"""
        SELECT {cols_str} FROM candles
        WHERE {args.label} IN ('BUY', 'SELL') {vol_filter}
    """).fetchall()

    n = len(rows)
    labels = np.array([r[args.label] for r in rows])
    base_buy = (labels == "BUY").sum() / len(labels) * 100

    data = {}
    for f in combo_features:
        data[f] = np.array([r[f] if r[f] is not None else 0.0 for r in rows], dtype=float)

    percentiles = {}
    for f in combo_features:
        percentiles[f] = {
            25: np.percentile(data[f], 25),
            75: np.percentile(data[f], 75),
            33: np.percentile(data[f], 33),
            67: np.percentile(data[f], 67),
        }

    combo_results = []
    for i, f1 in enumerate(combo_features):
        for j, f2 in enumerate(combo_features):
            if j <= i:
                continue
            for k, f3 in enumerate(combo_features):
                if k <= j:
                    continue

                for direction in ["BUY", "SELL"]:
                    mask = np.ones(n, dtype=bool)
                    for f in [f1, f2, f3]:
                        if direction == "BUY":
                            if f in buy_high:
                                mask &= data[f] > percentiles[f][67]
                            else:
                                mask &= data[f] < percentiles[f][33]
                        else:
                            if f in buy_high:
                                mask &= data[f] < percentiles[f][33]
                            else:
                                mask &= data[f] > percentiles[f][67]

                    sub = labels[mask]
                    total = len(sub)
                    if total < 200:
                        continue
                    target = (sub == direction).sum()
                    hit_pct = target / total * 100
                    baseline = base_buy if direction == "BUY" else (100 - base_buy)
                    edge = hit_pct - baseline

                    if abs(edge) > 5:
                        combo_results.append({
                            "combo": f"{f1} + {f2} + {f3}",
                            "dir": direction,
                            "n": total,
                            "hit": hit_pct,
                            "edge": edge,
                        })

    combo_results.sort(key=lambda c: abs(c["edge"]), reverse=True)
    print(f"Baseline: BUY {base_buy:.1f}%, SELL {100 - base_buy:.1f}%")
    print(f"Showing combos with |edge| > 5%")
    print()
    print(f"{'Combo':<60} {'Dir':<5} {'N':>7} {'Hit%':>7} {'Edge':>7}")
    print("-" * 90)
    for c in combo_results[:50]:
        print(f"{c['combo']:<60} {c['dir']:<5} {c['n']:>7,} {c['hit']:>7.1f} {c['edge']:>+7.1f}")

    # ========================================================================
    # 6. BEST COMBO YEAR STABILITY
    # ========================================================================
    if combo_results:
        print()
        print("=" * 90)
        print("YEAR STABILITY of top 5 combos")
        print("=" * 90)
        year_arr = np.array([int(r["year"]) for r in rows])
        all_years = sorted(set(year_arr))

        for c in combo_results[:5]:
            parts = c["combo"].split(" + ")
            f1, f2, f3 = parts
            direction = c["dir"]

            mask = np.ones(n, dtype=bool)
            for f in [f1, f2, f3]:
                if direction == "BUY":
                    if f in buy_high:
                        mask &= data[f] > percentiles[f][67]
                    else:
                        mask &= data[f] < percentiles[f][33]
                else:
                    if f in buy_high:
                        mask &= data[f] < percentiles[f][33]
                    else:
                        mask &= data[f] > percentiles[f][67]

            print(f"\n{c['combo']} ({c['dir']}, overall: {c['hit']:.1f}%, N={c['n']:,})")
            for y in all_years:
                yr_mask = mask & (year_arr == y)
                sub = labels[yr_mask]
                total = len(sub)
                if total < 20:
                    print(f"  {y}: N={total:>5} (too few)")
                    continue
                target = (sub == direction).sum()
                hit = target / total * 100
                print(f"  {y}: N={total:>5,}  hit={hit:>6.1f}%")

    conn.close()


if __name__ == "__main__":
    main()
