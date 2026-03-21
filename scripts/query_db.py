"""Query the analysis database — helper functions + CLI.

Helpers for common analysis patterns. Also works as a CLI for ad-hoc SQL.

Usage:
    # Ad-hoc SQL
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/query_db.py \
        "SELECT year, label_oracle_05, COUNT(*) FROM candles GROUP BY year, label_oracle_05"

    # Built-in reports
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/query_db.py --report separation
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/query_db.py --report labels
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/query_db.py --report stats
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import numpy as np

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def label_distribution(conn: sqlite3.Connection, label_col: str = "label_oracle_05",
                       year: int | None = None) -> list[dict]:
    """Count BUY/SELL/QUIET for a label column, optionally filtered by year."""
    where = f"WHERE year = {year}" if year else ""
    rows = conn.execute(f"""
        SELECT {label_col} as label, COUNT(*) as n,
               ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 1) as pct
        FROM candles {where}
        GROUP BY {label_col}
        ORDER BY {label_col}
    """).fetchall()
    return [dict(r) for r in rows]


def feature_stats_by_label(conn: sqlite3.Connection, features: list[str],
                           label_col: str = "label_oracle_05",
                           years: tuple[int, int] | None = None) -> list[dict]:
    """Compute mean and std of features grouped by label."""
    year_filter = f"AND year BETWEEN {years[0]} AND {years[1]}" if years else ""
    results = []
    for feat in features:
        rows = conn.execute(f"""
            SELECT {label_col} as label,
                   COUNT(*) as n,
                   AVG({feat}) as mean,
                   MIN({feat}) as min_val,
                   MAX({feat}) as max_val
            FROM candles
            WHERE {feat} IS NOT NULL {year_filter}
            GROUP BY {label_col}
            ORDER BY {label_col}
        """).fetchall()

        for r in rows:
            vals = conn.execute(f"""
                SELECT {feat} FROM candles
                WHERE {label_col} = ? AND {feat} IS NOT NULL {year_filter}
            """, (r["label"],)).fetchall()
            arr = np.array([v[0] for v in vals], dtype=float)
            std = float(np.std(arr)) if len(arr) > 1 else 0.0

            results.append({
                "feature": feat,
                "label": r["label"],
                "n": r["n"],
                "mean": r["mean"],
                "std": std,
                "min": r["min_val"],
                "max": r["max_val"],
            })
    return results


def feature_separation(conn: sqlite3.Connection, label_col: str = "label_oracle_05",
                       years: tuple[int, int] | None = None) -> list[dict]:
    """For each feature, compute how different BUY/SELL means are from QUIET.

    Returns features sorted by separation score (higher = more discriminative).
    The separation score is |mean_action - mean_quiet| / pooled_std.
    """
    all_features = [
        "rsi", "adx", "dmi_plus", "dmi_minus", "bb_width", "bb_pos",
        "sma20_r", "sma50_r", "sma200_r",
        "macd_line_r", "macd_signal_r", "macd_hist_r",
        "atr_r", "ret", "vol_r", "open_r", "high_r", "low_r",
        "body", "upper_wick", "lower_wick", "close_pos",
        "vol_rel", "range_chg",
    ]

    stats = feature_stats_by_label(conn, all_features, label_col, years)

    quiet_stats = {s["feature"]: s for s in stats if s["label"] == "QUIET"}
    buy_stats = {s["feature"]: s for s in stats if s["label"] == "BUY"}
    sell_stats = {s["feature"]: s for s in stats if s["label"] == "SELL"}

    results = []
    for feat in all_features:
        q = quiet_stats.get(feat)
        b = buy_stats.get(feat)
        s = sell_stats.get(feat)
        if not q or not b or not s:
            continue

        pooled_std = max(q["std"], 1e-10)

        buy_sep = abs(b["mean"] - q["mean"]) / pooled_std
        sell_sep = abs(s["mean"] - q["mean"]) / pooled_std
        max_sep = max(buy_sep, sell_sep)

        results.append({
            "feature": feat,
            "buy_mean": b["mean"],
            "sell_mean": s["mean"],
            "quiet_mean": q["mean"],
            "quiet_std": q["std"],
            "buy_sep": buy_sep,
            "sell_sep": sell_sep,
            "max_sep": max_sep,
        })

    results.sort(key=lambda x: x["max_sep"], reverse=True)
    return results


def normalization_stats(conn: sqlite3.Connection) -> list[dict]:
    """Read the feature_stats table."""
    rows = conn.execute("SELECT * FROM feature_stats ORDER BY feature").fetchall()
    return [dict(r) for r in rows]


def run_sql(conn: sqlite3.Connection, sql: str) -> list[dict]:
    """Execute arbitrary SQL and return results as dicts."""
    rows = conn.execute(sql).fetchall()
    if rows:
        return [dict(r) for r in rows]
    return []


def print_table(rows: list[dict], max_col_width: int = 20):
    """Pretty-print a list of dicts as a table."""
    if not rows:
        print("(no results)")
        return

    cols = list(rows[0].keys())
    widths = {c: min(max(len(c), max(len(_fmt(r.get(c))) for r in rows)), max_col_width) for c in cols}

    header = " | ".join(c.ljust(widths[c]) for c in cols)
    print(header)
    print("-+-".join("-" * widths[c] for c in cols))
    for r in rows:
        print(" | ".join(_fmt(r.get(c)).ljust(widths[c]) for c in cols))


def _fmt(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float):
        if abs(v) < 0.001 and v != 0:
            return f"{v:.6f}"
        if abs(v) > 1000:
            return f"{v:,.1f}"
        return f"{v:.4f}"
    if isinstance(v, int):
        return f"{v:,}"
    return str(v)


def report_labels(conn):
    """Print label distributions across years and thresholds."""
    for label_col in ["label_oracle_02", "label_oracle_05", "label_oracle_10", "label_oracle_20"]:
        threshold = label_col.replace("label_oracle_", "").lstrip("0") or "0"
        threshold = {"2": "0.2%", "5": "0.5%", "02": "0.2%", "05": "0.5%", "10": "1.0%", "20": "2.0%"}.get(
            label_col[-2:], label_col
        )
        print(f"\n=== {label_col} (min move {threshold}, 3h horizon) ===")
        for year in [2019, 2020, 2021, 2022, 2023, 2024, 2025, None]:
            dist = label_distribution(conn, label_col, year)
            yr = str(year) if year else "ALL"
            parts = [f"{d['label']}:{d['n']:>7,} ({d['pct']}%)" for d in dist]
            print(f"  {yr:5s}  {'  '.join(parts)}")


def report_separation(conn, label_col="label_oracle_05", years=None):
    """Print feature separation scores."""
    yr_desc = f"{years[0]}-{years[1]}" if years else "all years"
    print(f"\n=== Feature separation ({label_col}, {yr_desc}) ===")
    print(f"  Separation = |mean_action - mean_quiet| / quiet_std")
    print(f"  Higher = feature looks more different at labeled moments\n")

    seps = feature_separation(conn, label_col, years)
    print(f"  {'Feature':<16s} | {'BUY mean':>10s} | {'SELL mean':>10s} | {'QUIET mean':>10s} | {'Q std':>10s} | {'BUY sep':>8s} | {'SELL sep':>8s}")
    print(f"  {'-'*16}-+-{'-'*10}-+-{'-'*10}-+-{'-'*10}-+-{'-'*10}-+-{'-'*8}-+-{'-'*8}")

    for s in seps:
        print(f"  {s['feature']:<16s} | {s['buy_mean']:>10.5f} | {s['sell_mean']:>10.5f} | {s['quiet_mean']:>10.5f} | {s['quiet_std']:>10.5f} | {s['buy_sep']:>8.3f} | {s['sell_sep']:>8.3f}")


def report_stats(conn):
    """Print normalization stats."""
    print("\n=== Feature normalization stats (2019-2020 training period) ===\n")
    stats = normalization_stats(conn)
    print(f"  {'Feature':<16s} | {'Mean':>10s} | {'Std':>10s} | {'Min':>10s} | {'Max':>10s} | {'P01':>10s} | {'P99':>10s}")
    print(f"  {'-'*16}-+-{'-'*10}-+-{'-'*10}-+-{'-'*10}-+-{'-'*10}-+-{'-'*10}-+-{'-'*10}")
    for s in stats:
        print(f"  {s['feature']:<16s} | {s['mean']:>10.5f} | {s['std']:>10.5f} | {s['min']:>10.5f} | {s['max']:>10.5f} | {s['p01']:>10.5f} | {s['p99']:>10.5f}")


def main():
    if not DB_PATH.exists():
        print(f"Database not found: {DB_PATH}")
        print("Run build_analysis_db.py first.")
        sys.exit(1)

    conn = get_conn()

    if len(sys.argv) < 2:
        print("Usage:")
        print("  query_db.py 'SELECT ...'          — run ad-hoc SQL")
        print("  query_db.py --report labels        — label distributions")
        print("  query_db.py --report separation     — feature separation scores")
        print("  query_db.py --report separation-train — separation on 2019-2020 only")
        print("  query_db.py --report stats          — normalization stats")
        sys.exit(0)

    if sys.argv[1] == "--report":
        report_name = sys.argv[2] if len(sys.argv) > 2 else "labels"
        if report_name == "labels":
            report_labels(conn)
        elif report_name == "separation":
            report_separation(conn)
        elif report_name == "separation-train":
            report_separation(conn, years=(2019, 2020))
        elif report_name == "separation-test":
            report_separation(conn, years=(2021, 2024))
        elif report_name == "stats":
            report_stats(conn)
        else:
            print(f"Unknown report: {report_name}")
    else:
        sql = " ".join(sys.argv[1:])
        try:
            results = run_sql(conn, sql)
            print_table(results)
        except Exception as e:
            print(f"SQL error: {e}")

    conn.close()


if __name__ == "__main__":
    main()
