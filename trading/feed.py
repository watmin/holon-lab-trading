"""BTC OHLCV data feed — live polling and historical replay.

No holon imports. Pure data plumbing via ccxt + pandas.

Window indexing:
  Each yielded DataFrame is df.iloc[start + step : start + step + window].
  The window must fit inside the full DataFrame, so:
    max_start = len(df) - window - length
  where `length` is the number of steps the episode will take.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterator

import numpy as np
import pandas as pd

_COLUMNS = ["timestamp", "open", "high", "low", "close", "volume"]


class LiveFeed:
    """Polls exchange for latest candles on each 5-minute boundary."""

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
            df = df.reset_index(drop=True)
            yield df

            # Sleep until the next 5-minute boundary + 1s buffer
            now = time.time()
            interval_s = _timeframe_to_seconds(self.timeframe)
            sleep_s = interval_s - (now % interval_s) + 1.0
            time.sleep(sleep_s)


class HistoricalFeed:
    """Cached historical data for offline replay and discovery harness.

    Downloads from Binance on first use and caches as Parquet.
    """

    def __init__(
        self,
        parquet_path: str = "data/btc_5m.parquet",
        symbol: str = "BTC/USDT",
        timeframe: str = "5m",
        days: int = 730,
    ):
        self.parquet_path = Path(parquet_path)
        self.symbol = symbol
        self.timeframe = timeframe
        self.days = days
        self._df: pd.DataFrame | None = None

    def ensure_data(self) -> pd.DataFrame:
        """Load cached parquet or download. Returns the full DataFrame."""
        if self._df is not None:
            return self._df

        if self.parquet_path.exists():
            self._df = pd.read_parquet(self.parquet_path)
            print(f"Loaded {len(self._df):,} cached candles from {self.parquet_path}")
            return self._df

        self._df = self._download()
        return self._df

    def random_episode(
        self,
        length: int = 200,
        window: int = 200,
        rng: np.random.Generator | None = None,
    ) -> Iterator[pd.DataFrame]:
        """Pick a random start, yield `length` sliding windows of `window` candles.

        Each yielded window is the `window` candles ending just before the
        next scoring candle, so the consumer always has a complete lookback.

        Args:
            length: number of steps (decision points) in the episode.
            window: candles per window fed to the encoder.
            rng: optional seeded generator for reproducibility.
        """
        if rng is None:
            rng = np.random.default_rng()

        df = self.ensure_data()

        # Need `window` candles as lookback + `length` steps, each shifting by 1
        required = window + length
        if required > len(df):
            raise ValueError(
                f"Episode requires {required} candles but only {len(df)} available. "
                f"Reduce length or window."
            )

        max_start = len(df) - required
        start = int(rng.integers(0, max_start + 1))

        for step in range(length):
            yield df.iloc[start + step : start + step + window].reset_index(drop=True)

    def replay(
        self,
        start_idx: int,
        length: int,
        window: int = 200,
    ) -> Iterator[pd.DataFrame]:
        """Deterministic replay from a fixed start index.

        Args:
            start_idx: position of the first window's first candle.
            length: number of steps.
            window: candles per window.
        """
        df = self.ensure_data()
        for step in range(length):
            end = start_idx + step + window
            if end > len(df):
                break
            yield df.iloc[start_idx + step : end].reset_index(drop=True)

    def next_close(self, window_start_idx: int, window_size: int) -> float | None:
        """Return the close price of the candle immediately after a window.

        Used by the harness to score decisions against realized return.

        Args:
            window_start_idx: start row of the current window.
            window_size: number of candles in the window.
        Returns:
            Close price of the candle after the window, or None if out of range.
        """
        df = self.ensure_data()
        next_idx = window_start_idx + window_size
        if next_idx >= len(df):
            return None
        return float(df.iloc[next_idx]["close"])

    def _download(self) -> pd.DataFrame:
        import ccxt

        print(f"Downloading {self.days} days of {self.timeframe} {self.symbol}...")
        exchange = ccxt.binance({"enableRateLimit": True})
        since_ms = int(
            (datetime.utcnow() - timedelta(days=self.days)).timestamp() * 1000
        )
        all_rows: list = []

        while True:
            batch = exchange.fetch_ohlcv(
                self.symbol, self.timeframe, since=since_ms, limit=1000
            )
            if not batch:
                break
            all_rows.extend(batch)
            since_ms = batch[-1][0] + 1
            time.sleep(0.2)  # respect rate limit

        df = pd.DataFrame(all_rows, columns=_COLUMNS)
        df["timestamp"] = pd.to_datetime(df["timestamp"], unit="ms")
        df.drop_duplicates(subset=["timestamp"], inplace=True)
        df.sort_values("timestamp", inplace=True)
        df.reset_index(drop=True, inplace=True)

        self.parquet_path.parent.mkdir(parents=True, exist_ok=True)
        df.to_parquet(self.parquet_path)
        print(f"Saved {len(df):,} candles to {self.parquet_path}")

        self._df = df
        return df


def _timeframe_to_seconds(timeframe: str) -> int:
    """Convert ccxt timeframe string to seconds."""
    units = {"m": 60, "h": 3600, "d": 86400}
    return int(timeframe[:-1]) * units[timeframe[-1]]
