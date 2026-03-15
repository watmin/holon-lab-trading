"""Unit tests for ExperimentTracker.

Covers:
- BUY/SELL/HOLD simulation math (fees, slippage, portfolio state)
- PnL sign correctness
- Equity curve grows correctly
- SQLite persistence: records written, readable
- summary() metrics: total_return, trades, decisions count
- recent_decisions() returns a DataFrame with right columns
- export_csv() writes a file
- Trade count increments only on actual trades, not HOLDs
- Double-BUY idempotence: second BUY does nothing when already in
- Double-SELL idempotence: second SELL does nothing when flat
"""

from __future__ import annotations

import math
import sqlite3
import tempfile
from pathlib import Path

import pytest

from trading.tracker import ExperimentTracker


@pytest.fixture
def tracker(tmp_path):
    """Fresh tracker backed by a temp SQLite file."""
    return ExperimentTracker(
        initial_usdt=10_000.0,
        fee=0.001,
        slippage_bp=5.0,
        db_path=str(tmp_path / "test.db"),
    )


# ---------------------------------------------------------------------------
# Portfolio state after trades
# ---------------------------------------------------------------------------

class TestBuySimulation:
    def test_buy_depletes_usdt(self, tracker):
        tracker.record("BUY", 0.8, price=50_000.0)
        # 99% is deployed; 1% ($100) is kept as a buffer
        assert tracker.portfolio["usdt"] <= 100.0

    def test_buy_acquires_btc(self, tracker):
        tracker.record("BUY", 0.8, price=50_000.0)
        assert tracker.portfolio["btc"] > 0.0

    def test_buy_respects_fee_and_slippage(self, tracker):
        price = 50_000.0
        initial = 10_000.0
        size_usdt = initial * 0.99           # 99% deployed
        effective = price * (1 + 5 / 10_000)  # +5bp slippage
        expected_btc = size_usdt / effective * (1 - 0.001)  # minus fee
        tracker.record("BUY", 1.0, price=price)
        assert math.isclose(tracker.portfolio["btc"], expected_btc, rel_tol=1e-6)

    def test_second_buy_when_mostly_deployed(self, tracker):
        """After first BUY, 1% USDT buffer remains. A second BUY deploys it too."""
        tracker.record("BUY", 1.0, price=50_000.0)
        btc_after_first = tracker.portfolio["btc"]
        usdt_after_first = tracker.portfolio["usdt"]
        assert usdt_after_first > 0  # small buffer exists
        tracker.record("BUY", 1.0, price=55_000.0)
        # Second BUY consumes the residual USDT → more BTC
        assert tracker.portfolio["btc"] > btc_after_first
        assert tracker.portfolio["usdt"] < usdt_after_first


class TestSellSimulation:
    def test_sell_without_btc_is_noop(self, tracker):
        usdt_before = tracker.portfolio["usdt"]
        tracker.record("SELL", 1.0, price=50_000.0)
        assert math.isclose(tracker.portfolio["usdt"], usdt_before, rel_tol=1e-9)

    def test_sell_after_buy_clears_btc(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=55_000.0)
        assert math.isclose(tracker.portfolio["btc"], 0.0, abs_tol=1e-12)

    def test_sell_returns_usdt(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=55_000.0)
        assert tracker.portfolio["usdt"] > 0.0

    def test_profitable_sell_positive_pnl(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        entry = tracker.record("SELL", 1.0, price=60_000.0)
        assert entry["simulated_pnl"] > 0.0

    def test_losing_sell_negative_pnl(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        entry = tracker.record("SELL", 1.0, price=40_000.0)
        assert entry["simulated_pnl"] < 0.0


class TestHoldSimulation:
    def test_hold_does_not_change_portfolio(self, tracker):
        usdt_before = tracker.portfolio["usdt"]
        tracker.record("HOLD", 0.5, price=50_000.0)
        assert math.isclose(tracker.portfolio["usdt"], usdt_before, rel_tol=1e-9)
        assert math.isclose(tracker.portfolio["btc"], 0.0, abs_tol=1e-12)


# ---------------------------------------------------------------------------
# Trade count
# ---------------------------------------------------------------------------

class TestTradeCount:
    def test_hold_does_not_increment_trade_count(self, tracker):
        tracker.record("HOLD", 0.5, price=50_000.0)
        tracker.record("HOLD", 0.5, price=50_000.0)
        assert tracker._trade_count == 0

    def test_buy_increments_trade_count(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        assert tracker._trade_count == 1

    def test_sell_increments_trade_count(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=55_000.0)
        assert tracker._trade_count == 2

    def test_noop_sells_do_not_increment(self, tracker):
        tracker.record("SELL", 1.0, price=50_000.0)  # no BTC, noop
        assert tracker._trade_count == 0


# ---------------------------------------------------------------------------
# Equity curve
# ---------------------------------------------------------------------------

class TestEquityCurve:
    def test_initial_equity_equals_usdt(self, tracker):
        assert math.isclose(tracker.equity_curve[0], 10_000.0, rel_tol=1e-9)

    def test_equity_grows_after_profitable_round_trip(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=60_000.0)
        assert tracker.equity_curve[-1] > 10_000.0

    def test_equity_shrinks_after_losing_round_trip(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=40_000.0)
        assert tracker.equity_curve[-1] < 10_000.0

    def test_equity_at_price_method(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        # equity(price) = usdt + btc * price
        computed = tracker.equity(50_000.0)
        assert computed > 0.0


# ---------------------------------------------------------------------------
# SQLite persistence
# ---------------------------------------------------------------------------

class TestSQLite:
    def test_record_written_to_db(self, tracker):
        tracker.record("BUY", 0.9, price=50_000.0, notes="test")
        rows = tracker.db.execute("SELECT * FROM decisions").fetchall()
        assert len(rows) == 1

    def test_multiple_records_all_written(self, tracker):
        for _ in range(5):
            tracker.record("HOLD", 0.5, price=50_000.0)
        rows = tracker.db.execute("SELECT * FROM decisions").fetchall()
        assert len(rows) == 5

    def test_used_engrams_serialized(self, tracker):
        tracker.record("BUY", 0.9, price=50_000.0, used_engrams=["eng_1", "eng_2"])
        row = tracker.db.execute("SELECT used_engrams FROM decisions").fetchone()
        import json
        assert json.loads(row[0]) == ["eng_1", "eng_2"]

    def test_notes_persisted(self, tracker):
        tracker.record("HOLD", 0.5, price=50_000.0, notes="hello world")
        row = tracker.db.execute("SELECT notes FROM decisions").fetchone()
        assert row[0] == "hello world"

    def test_table_survives_new_connection(self, tmp_path):
        db_path = str(tmp_path / "persist.db")
        t = ExperimentTracker(db_path=db_path)
        t.record("BUY", 1.0, price=50_000.0)
        del t  # close

        conn = sqlite3.connect(db_path)
        rows = conn.execute("SELECT * FROM decisions").fetchall()
        assert len(rows) == 1
        conn.close()


# ---------------------------------------------------------------------------
# summary() metrics
# ---------------------------------------------------------------------------

class TestSummary:
    def test_summary_empty_returns_zeros(self, tracker):
        s = tracker.summary()
        assert s["total_return"] == 0.0
        assert s["trades"] == 0

    def test_total_return_after_profit(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=60_000.0)
        s = tracker.summary()
        assert s["total_return"] > 0.0

    def test_decisions_count(self, tracker):
        for _ in range(10):
            tracker.record("HOLD", 0.5, price=50_000.0)
        s = tracker.summary()
        assert s["decisions"] == 10

    def test_summary_trade_count(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        tracker.record("SELL", 1.0, price=55_000.0)
        s = tracker.summary()
        assert s["trades"] == 2

    def test_max_drawdown_zero_on_monotone_equity(self, tracker):
        # HOLD with flat price → equity is constant → no drawdown
        for _ in range(50):
            tracker.record("HOLD", 0.5, price=50_000.0)
        s = tracker.summary()
        assert math.isclose(s["max_drawdown"], 0.0, abs_tol=1e-9)


# ---------------------------------------------------------------------------
# recent_decisions()
# ---------------------------------------------------------------------------

class TestRecentDecisions:
    def test_returns_dataframe(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        df = tracker.recent_decisions(hours=1)
        import pandas as pd
        assert isinstance(df, pd.DataFrame)

    def test_columns_present(self, tracker):
        tracker.record("BUY", 1.0, price=50_000.0)
        df = tracker.recent_decisions(hours=1)
        for col in ("ts", "action", "confidence", "price", "equity"):
            assert col in df.columns

    def test_correct_row_count(self, tracker):
        for _ in range(3):
            tracker.record("HOLD", 0.5, price=50_000.0)
        df = tracker.recent_decisions(hours=1)
        assert len(df) == 3


# ---------------------------------------------------------------------------
# export_csv()
# ---------------------------------------------------------------------------

class TestExportCsv:
    def test_csv_file_created(self, tracker, tmp_path):
        tracker.record("HOLD", 0.5, price=50_000.0)
        path = str(tmp_path / "log.csv")
        tracker.export_csv(path)
        assert Path(path).exists()

    def test_csv_has_rows(self, tracker, tmp_path):
        for _ in range(3):
            tracker.record("HOLD", 0.5, price=50_000.0)
        path = str(tmp_path / "log.csv")
        tracker.export_csv(path)
        import pandas as pd
        df = pd.read_csv(path)
        assert len(df) == 3
