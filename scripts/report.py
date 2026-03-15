"""Read-only status report for the holon-lab-trading system.

Reads from the SQLite database and JSON files that the live system writes.
Safe to run while the live system is running — never modifies anything.

Usage:
    ./scripts/run_with_venv.sh python scripts/report.py
    ./scripts/run_with_venv.sh python scripts/report.py --db data/discovery.db
    ./scripts/run_with_venv.sh python scripts/report.py --hours 6
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

# ---------------------------------------------------------------------------
# Data loaders
# ---------------------------------------------------------------------------

def load_decisions(db_path: str, hours: int) -> pd.DataFrame:
    if not Path(db_path).exists():
        return pd.DataFrame()
    conn = sqlite3.connect(db_path)
    df = pd.read_sql(
        f"SELECT * FROM decisions WHERE ts > datetime('now', '-{hours} hours')",
        conn,
    )
    conn.close()
    return df


def load_all_decisions(db_path: str) -> pd.DataFrame:
    if not Path(db_path).exists():
        return pd.DataFrame()
    conn = sqlite3.connect(db_path)
    df = pd.read_sql("SELECT * FROM decisions ORDER BY ts", conn)
    conn.close()
    return df


def load_engrams(engram_path: str) -> dict:
    if not Path(engram_path).exists():
        return {}
    try:
        with open(engram_path) as f:
            return json.load(f)
    except Exception:
        return {}


def load_feature_weights(weights_path: str) -> dict:
    if not Path(weights_path).exists():
        return {}
    try:
        with open(weights_path) as f:
            return json.load(f)
    except Exception:
        return {}


# ---------------------------------------------------------------------------
# Metric computation
# ---------------------------------------------------------------------------

def compute_metrics(df: pd.DataFrame, initial_usdt: float = 10_000.0) -> dict:
    if df.empty or "equity" not in df.columns:
        return {}

    equity = df["equity"].astype(float)
    prices = df["price"].astype(float)

    returns = equity.pct_change().dropna()
    total_return = (equity.iloc[-1] / initial_usdt) - 1.0

    sharpe = 0.0
    if len(returns) > 30 and returns.std() > 0:
        sharpe = float(returns.mean() / returns.std() * np.sqrt(288 * 365))

    max_dd = 0.0
    roll_max = equity.cummax()
    if roll_max.max() > 0:
        drawdowns = (roll_max - equity) / roll_max
        max_dd = float(drawdowns.max())

    trades = df[df["action"].isin(["BUY", "SELL"])]
    win_rate = 0.0
    if len(trades) > 0:
        winning = (trades["simulated_pnl"].astype(float) > 0).sum()
        win_rate = winning / len(trades)

    action_counts = df["action"].value_counts().to_dict()

    # Estimate start time from first record
    first_ts = pd.to_datetime(df["ts"].iloc[0])
    last_ts  = pd.to_datetime(df["ts"].iloc[-1])
    run_hours = (last_ts - first_ts).total_seconds() / 3600

    return {
        "total_return":    total_return,
        "sharpe":          sharpe,
        "max_drawdown":    max_dd,
        "win_rate":        win_rate,
        "decisions":       len(df),
        "trades":          len(trades),
        "buys":            action_counts.get("BUY", 0),
        "sells":           action_counts.get("SELL", 0),
        "holds":           action_counts.get("HOLD", 0),
        "current_equity":  float(equity.iloc[-1]),
        "current_price":   float(prices.iloc[-1]) if not prices.empty else 0.0,
        "run_hours":       run_hours,
        "first_ts":        str(first_ts),
        "last_ts":         str(last_ts),
    }


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def bar(value: float, width: int = 20, lo: float = 0.0, hi: float = 1.0) -> str:
    """ASCII progress bar."""
    frac = max(0.0, min(1.0, (value - lo) / (hi - lo) if hi != lo else 0.0))
    filled = int(frac * width)
    return "[" + "█" * filled + "░" * (width - filled) + "]"


def sign(v: float) -> str:
    return "+" if v >= 0 else ""


def render_report(
    metrics: dict,
    engrams: dict,
    weights: dict,
    window_hours: int,
    db_path: str,
) -> str:
    lines = []
    w = 62

    lines.append("=" * w)
    lines.append(f"  Holon Lab: Trading — Status Report")
    lines.append(f"  Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append(f"  Source: {db_path}  (last {window_hours}h)")
    lines.append("=" * w)

    if not metrics:
        lines.append("  No data found. Has the system run yet?")
        lines.append("=" * w)
        return "\n".join(lines)

    # --- Portfolio ---
    lines.append("")
    lines.append("  PORTFOLIO")
    lines.append(f"  {'Equity':<22} ${metrics['current_equity']:>10,.2f}")
    ret = metrics["total_return"]
    lines.append(f"  {'Total Return':<22} {sign(ret)}{ret:.2%}  {bar(ret, lo=-0.2, hi=0.2)}")
    lines.append(f"  {'Run Time':<22} {metrics['run_hours']:.1f} hours")
    lines.append(f"  {'Current BTC Price':<22} ${metrics['current_price']:>10,.0f}")

    # --- Performance ---
    lines.append("")
    lines.append("  PERFORMANCE")
    sharpe = metrics["sharpe"]
    lines.append(f"  {'Sharpe (annualized)':<22} {sign(sharpe)}{sharpe:.3f}  {bar(sharpe, lo=-1.0, hi=3.0)}")
    dd = metrics["max_drawdown"]
    lines.append(f"  {'Max Drawdown':<22} -{dd:.2%}  {bar(1-dd, lo=0.0, hi=1.0)}")
    wr = metrics["win_rate"]
    lines.append(f"  {'Win Rate':<22} {wr:.1%}  {bar(wr)}")

    # --- Activity ---
    lines.append("")
    lines.append("  ACTIVITY")
    lines.append(f"  {'Decisions':<22} {metrics['decisions']:,}")
    lines.append(f"  {'Trades (B+S)':<22} {metrics['trades']:,}  "
                 f"(BUY={metrics['buys']}, SELL={metrics['sells']}, HOLD={metrics['holds']})")

    # --- Engram Library ---
    lines.append("")
    lines.append("  ENGRAM LIBRARY")
    if engrams:
        n = len(engrams.get("engrams", engrams))
        lines.append(f"  {'Engrams stored':<22} {n}")
    else:
        lines.append(f"  {'Engrams stored':<22} 0  (run discovery first)")

    # --- Feature Darwinism ---
    lines.append("")
    lines.append("  FEATURE IMPORTANCE (Algebraic Darwinism)")
    if weights and "importance" in weights and "weights" in weights:
        imp = weights["importance"]
        wts = weights["weights"]
        ranked = sorted(imp.items(), key=lambda x: x[1], reverse=True)
        lines.append(f"  {'Field':<20} {'Importance':>10}  {'Weight':>8}  Status")
        lines.append(f"  {'-'*20}  {'-'*10}  {'-'*8}  ------")
        for field, score in ranked:
            w_val = wts.get(field, 0.0)
            status = "PRUNED" if w_val < 0.15 else "active"
            marker = "▼" if status == "PRUNED" else " "
            lines.append(
                f"  {marker}{field:<19} {score:>10.3f}  {w_val:>8.3f}  {status}"
            )
    else:
        lines.append(f"  No weight data. Run discovery first.")

    lines.append("")
    lines.append("=" * w)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Holon Lab Trading status report")
    parser.add_argument("--db",      default="data/live_experiment.db",
                        help="SQLite database path")
    parser.add_argument("--engrams", default="data/live_engrams.json",
                        help="Engram library JSON path")
    parser.add_argument("--weights", default="data/feature_weights.json",
                        help="Feature weights JSON path")
    parser.add_argument("--hours",   type=int, default=48,
                        help="Recent decision window (hours)")
    parser.add_argument("--initial", type=float, default=10_000.0,
                        help="Initial USDT balance")
    parser.add_argument("--discovery", action="store_true",
                        help="Report on discovery run (uses data/discovery.db)")
    args = parser.parse_args()

    if args.discovery:
        db = "data/discovery.db"
        eng = "data/seed_engrams.json"
    else:
        db = args.db
        eng = args.engrams

    df = load_decisions(db, hours=args.hours)
    if df.empty:
        df = load_all_decisions(db)

    metrics = compute_metrics(df, initial_usdt=args.initial)
    engrams = load_engrams(eng)
    weights = load_feature_weights(args.weights)

    print(render_report(metrics, engrams, weights, args.hours, db))


if __name__ == "__main__":
    main()
