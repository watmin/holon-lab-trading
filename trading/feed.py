"""BTC OHLCV data feed — live polling and historical replay.

No holon imports. Pure data plumbing via ccxt + pandas.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterator

import pandas as pd

_COLUMNS = ["timestamp", "open", "high", "low", "close", "volume"]


class LiveFeed:
    """Polls exchange for latest candles every interval, yields DataFrames."""

    def __init__(
        self,
        symbol: str = "BTC/USDT",
        timeframe: str = "5m",
        window: int = 200,
    ):
        self.symbol = symbol
        self.timeframe = timeframe
        self.window = window

    def stream(self) -> Iterator[pd.DataFrame]:
        """Yield the latest `window` candles every 5 minutes, aligned to candle close."""
        import ccxt

        exchange = ccxt.binance({"enableRateLimit": True})
        while True:
            ohlcv = exchange.fetch_ohlcv(
                self.symbol, self.timeframe, limit=self.window
            )
            df = pd.DataFrame(ohlcv, columns=_COLUMNS)
            df["timestamp"] = pd.to_datetime(df["timestamp"], unit="ms")
            yield df

            now = time.time()
            sleep_seconds = 300 - (now % 300) + 1
            time.sleep(sleep_seconds)


class HistoricalFeed:
    """Cached historical data for offline replay and discovery harness."""

    def __init__(
        self,
        parquet_path: str = "data/btc_5m.parquet",
        symbol: str = "BTC/USDT",
        days: int = 730,
    ):
        self.parquet_path = Path(parquet_path)
        self.symbol = symbol
        self.days = days
        self._df: pd.DataFrame | None = None

    def ensure_data(self) -> pd.DataFrame:
        """Download history if not cached, return the full DataFrame."""
        if self._df is not None:
            return self._df

        if self.parquet_path.exists():
            self._df = pd.read_parquet(self.parquet_path)
            print(f"Loaded {len(self._df):,} cached candles from {self.parquet_path}")
            return self._df

        self._df = self._download()
        return self._df

    def random_episode(
        self, length: int = 200, window: int = 12, rng: "np.random.Generator | None" = None
    ) -> Iterator[pd.DataFrame]:
        """Pick a random offset and yield sliding windows of `window` candles."""
        import numpy as np

        if rng is None:
            rng = np.random.default_rng()

        df = self.ensure_data()
        max_start = len(df) - length - window - 1
        start = rng.integers(window, max_start)

        for step in range(length):
            yield df.iloc[start + step : start + step + window].copy()

    def replay(
        self, start_idx: int, length: int, window: int = 12
    ) -> Iterator[pd.DataFrame]:
        """Deterministic replay from a fixed offset."""
        df = self.ensure_data()
        for step in range(length):
            yield df.iloc[start_idx + step : start_idx + step + window].copy()

    def get_next_candle(self, window_end_idx: int) -> pd.Series:
        """Return the candle immediately after a window (for scoring)."""
        df = self.ensure_data()
        return df.iloc[window_end_idx]

    def _download(self) -> pd.DataFrame:
        import ccxt

        print(f"Downloading {self.days} days of 5m {self.symbol} (first run only)...")
        exchange = ccxt.binance({"enableRateLimit": True})
        since = int(
            (datetime.utcnow() - timedelta(days=self.days)).timestamp() * 1000
        )
        all_ohlcv: list = []

        while True:
            batch = exchange.fetch_ohlcv(
                self.symbol, "5m", since=since, limit=1000
            )
            if not batch:
                break
            all_ohlcv.extend(batch)
            since = batch[-1][0] + 1
            time.sleep(0.2)

        df = pd.DataFrame(all_ohlcv, columns=_COLUMNS)
        df["timestamp"] = pd.to_datetime(df["timestamp"], unit="ms")
        df.drop_duplicates(subset=["timestamp"], inplace=True)
        df.reset_index(drop=True, inplace=True)

        self.parquet_path.parent.mkdir(parents=True, exist_ok=True)
        df.to_parquet(self.parquet_path)
        print(f"Saved {len(df):,} candles to {self.parquet_path}")

        self._df = df
        return df
