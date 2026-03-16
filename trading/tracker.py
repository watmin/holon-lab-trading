"""Paper trading engine with full audit trail.

No holon imports. Simulates trades, logs to SQLite, computes rolling metrics.

SQLite schema:
  decisions       — one row per 5-min candle decision
  engram_windows  — raw stripe_vecs per engram, for AsyncCritic consolidation
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd


class ExperimentTracker:
    """Simulated portfolio + metrics + SQLite audit trail."""

    def __init__(
        self,
        initial_usdt: float = 10000.0,
        fee: float = 0.001,
        slippage_bp: float = 5.0,
        db_path: str = "data/experiment.db",
    ):
        self.initial_usdt = initial_usdt
        self.fee = fee
        self.slippage = slippage_bp / 10_000
        self.portfolio = {"usdt": initial_usdt, "btc": 0.0}
        self.equity_curve: list[float] = [initial_usdt]
        self._trade_count = 0

        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = __import__("threading").Lock()
        self._init_db()
        self._start = datetime.utcnow()

    def _init_db(self) -> None:
        self.db.execute("""
            CREATE TABLE IF NOT EXISTS decisions (
                ts TEXT,
                action TEXT,
                confidence REAL,
                price REAL,
                equity REAL,
                simulated_pnl REAL,
                latency_ms REAL,
                used_engrams TEXT,
                notes TEXT
            )
        """)
        # Raw stripe_vecs stored here so AsyncCritic can re-train consolidated subspaces.
        # Each row is one stripe vector (numpy array serialized as blob) for one engram window.
        # The critic fetches all rows for a given engram_name and re-trains from them.
        self.db.execute("""
            CREATE TABLE IF NOT EXISTS engram_windows (
                engram_name TEXT NOT NULL,
                window_idx  INTEGER NOT NULL,
                stripe_idx  INTEGER NOT NULL,
                vec         BLOB NOT NULL
            )
        """)
        self.db.execute("""
            CREATE INDEX IF NOT EXISTS idx_engram_windows_name
            ON engram_windows (engram_name)
        """)
        self.db.commit()

    def record(
        self,
        action: str,
        confidence: float,
        price: float,
        latency_ms: float = 0.0,
        used_engrams: list[str] | None = None,
        notes: str = "",
    ) -> dict:
        """Record a decision, simulate trade, return the log entry."""
        with self._lock:
            pnl = self._simulate(action, price)
            equity = self.portfolio["usdt"] + self.portfolio["btc"] * price
            self.equity_curve.append(equity)

            entry = {
                "ts": datetime.utcnow().isoformat(),
                "action": action,
                "confidence": confidence,
                "price": price,
                "equity": equity,
                "simulated_pnl": pnl,
                "latency_ms": latency_ms,
                "used_engrams": json.dumps(used_engrams or []),
                "notes": notes,
            }
            self.db.execute(
                "INSERT INTO decisions VALUES (?,?,?,?,?,?,?,?,?)",
                tuple(entry.values()),
            )
            self.db.commit()
            return entry

    def store_engram_windows(
        self,
        engram_name: str,
        stripe_vecs_list: list[list[np.ndarray]],
    ) -> None:
        """Persist raw stripe vectors for an engram so the critic can re-train.

        stripe_vecs_list is a list of window observations, each a list of N stripe
        vectors (one per stripe). Stored as blobs; retrieved by load_engram_windows().
        """
        with self._lock:
            rows = []
            for w_idx, stripe_vecs in enumerate(stripe_vecs_list):
                for s_idx, vec in enumerate(stripe_vecs):
                    rows.append((
                        engram_name,
                        w_idx,
                        s_idx,
                        vec.astype(np.int8).tobytes(),
                    ))
            self.db.executemany(
                "INSERT INTO engram_windows VALUES (?,?,?,?)", rows
            )
            self.db.commit()

    def load_engram_windows(
        self,
        engram_name: str,
        dim: int,
    ) -> list[list[np.ndarray]]:
        """Load raw stripe vectors for an engram, reconstructed as numpy arrays.

        Returns a list of window observations, each a list of stripe vectors.
        dim must match the dimensionality used when the engram was minted.
        """
        rows = self.db.execute(
            "SELECT window_idx, stripe_idx, vec FROM engram_windows "
            "WHERE engram_name = ? ORDER BY window_idx, stripe_idx",
            (engram_name,),
        ).fetchall()

        if not rows:
            return []

        # Group by window_idx then stripe_idx
        windows: dict[int, dict[int, np.ndarray]] = {}
        for w_idx, s_idx, blob in rows:
            windows.setdefault(w_idx, {})[s_idx] = np.frombuffer(blob, dtype=np.int8).copy()

        return [
            [windows[w][s] for s in sorted(windows[w])]
            for w in sorted(windows)
        ]

    def delete_engram_windows(self, engram_name: str) -> None:
        """Remove stored training windows for a pruned or consolidated engram."""
        with self._lock:
            self.db.execute(
                "DELETE FROM engram_windows WHERE engram_name = ?", (engram_name,)
            )
            self.db.commit()

    def engram_window_counts(self) -> dict[str, int]:
        """Return {engram_name: window_count} for all stored engrams."""
        rows = self.db.execute(
            "SELECT engram_name, COUNT(DISTINCT window_idx) "
            "FROM engram_windows GROUP BY engram_name"
        ).fetchall()
        return dict(rows)

    def equity(self, price: float | None = None) -> float:
        if price is None:
            return self.equity_curve[-1]
        return self.portfolio["usdt"] + self.portfolio["btc"] * price

    def summary(self) -> dict:
        """Current metric snapshot."""
        if len(self.equity_curve) < 2:
            return {"total_return": 0.0, "trades": 0}

        returns = pd.Series(self.equity_curve).pct_change().dropna()
        eq = pd.Series(self.equity_curve)

        sharpe = 0.0
        if len(returns) > 30 and returns.std() > 0:
            sharpe = float(returns.mean() / returns.std() * np.sqrt(288 * 365))

        max_dd = float((eq.cummax() - eq).max() / eq.cummax().max()) if eq.max() > 0 else 0.0

        return {
            "total_return": self.equity_curve[-1] / self.initial_usdt - 1,
            "sharpe": sharpe,
            "max_drawdown": max_dd,
            "win_rate": float((returns > 0).mean()) if len(returns) > 0 else 0.0,
            "trades": self._trade_count,
            "decisions": len(self.equity_curve) - 1,
            "run_hours": (datetime.utcnow() - self._start).total_seconds() / 3600,
        }

    def recent_decisions(self, hours: int = 48) -> pd.DataFrame:
        """Load recent decisions from SQLite."""
        with self._lock:
            return pd.read_sql(
                f"SELECT * FROM decisions WHERE ts > datetime('now', '-{hours} hours')",
                self.db,
            )

    def export_csv(self, path: str = "data/experiment_log.csv") -> None:
        df = pd.read_sql("SELECT * FROM decisions", self.db)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(path, index=False)

    def _simulate(self, action: str, price: float) -> float:
        """Execute paper trade, return realized PnL."""
        if action == "BUY" and self.portfolio["usdt"] > 0:
            size_usdt = self.portfolio["usdt"] * 0.99
            effective = price * (1 + self.slippage)
            self.portfolio["btc"] += size_usdt / effective * (1 - self.fee)
            self.portfolio["usdt"] -= size_usdt
            self._trade_count += 1
            return 0.0  # PnL realized on sell

        if action == "SELL" and self.portfolio["btc"] > 0:
            size_btc = self.portfolio["btc"]
            effective = price * (1 - self.slippage)
            proceeds = size_btc * effective * (1 - self.fee)
            # Cost basis = USDT spent on the open BUY position
            cost_basis = self.initial_usdt - self.portfolio["usdt"]
            pnl = proceeds - cost_basis
            self.portfolio["usdt"] += proceeds
            self.portfolio["btc"] = 0.0
            self._trade_count += 1
            return pnl

        return 0.0
