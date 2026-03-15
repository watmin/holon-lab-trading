"""Technical indicator computation from OHLCV DataFrames.

Pure pandas/numpy — no holon imports. Returns flat dicts ready for
encode_walkable via the OHLCVEncoder.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


class TechnicalFeatureFactory:
    """Compute technical indicators from an OHLCV DataFrame.

    All periods are expressed in candle counts (not minutes). For 5m candles:
    - 10 candles = 50 minutes  (SMA-50 equivalent)
    - 40 candles = 200 minutes (SMA-200 equivalent)
    - 3 candles  = 15 minutes  (fast RSI/ATR)

    The caller can override any period via constructor kwargs.
    """

    def __init__(
        self,
        sma_short: int = 10,
        sma_long: int = 40,
        bb_period: int = 20,
        bb_std: float = 2.0,
        macd_fast: int = 12,
        macd_slow: int = 26,
        macd_signal: int = 9,
        rsi_period: int = 14,
        atr_period: int = 14,
        vol_regime_window: int = 48,
    ):
        self.sma_short = sma_short
        self.sma_long = sma_long
        self.bb_period = bb_period
        self.bb_std = bb_std
        self.macd_fast = macd_fast
        self.macd_slow = macd_slow
        self.macd_signal = macd_signal
        self.rsi_period = rsi_period
        self.atr_period = atr_period
        self.vol_regime_window = vol_regime_window

    def compute(self, df: pd.DataFrame) -> dict[str, float]:
        """Compute all indicators. Returns flat dict with NaNs replaced by 0.0."""
        close = df["close"]
        high = df["high"]
        low = df["low"]
        volume = df["volume"]

        feats: dict[str, float] = {}

        # --- SMA ---
        feats["sma_short"] = close.rolling(self.sma_short).mean().iloc[-1]
        feats["sma_long"] = close.rolling(self.sma_long).mean().iloc[-1]
        feats["sma_cross"] = feats["sma_short"] - feats["sma_long"]

        # --- Bollinger Bands ---
        bb_mid = close.rolling(self.bb_period).mean()
        bb_std = close.rolling(self.bb_period).std()
        bb_upper = (bb_mid + self.bb_std * bb_std).iloc[-1]
        bb_lower = (bb_mid - self.bb_std * bb_std).iloc[-1]
        bb_mid_val = bb_mid.iloc[-1]
        feats["bb_upper"] = bb_upper
        feats["bb_lower"] = bb_lower
        feats["bb_width"] = (bb_upper - bb_lower) / bb_mid_val if bb_mid_val else 0.0

        # --- MACD ---
        ema_fast = close.ewm(span=self.macd_fast, adjust=False).mean()
        ema_slow = close.ewm(span=self.macd_slow, adjust=False).mean()
        macd_line = ema_fast - ema_slow
        macd_signal = macd_line.ewm(span=self.macd_signal, adjust=False).mean()
        feats["macd_line"] = macd_line.iloc[-1]
        feats["macd_signal"] = macd_signal.iloc[-1]
        feats["macd_hist"] = (macd_line - macd_signal).iloc[-1]

        # --- RSI ---
        feats["rsi"] = self._rsi(close, self.rsi_period)

        # --- ATR ---
        feats["atr"] = self._atr(high, low, close, self.atr_period)

        # --- ADX proxy ---
        feats["adx"] = self._adx_proxy(high, low, close, self.atr_period)

        # --- Volume regime ---
        vol_mean = volume.rolling(self.vol_regime_window).mean().iloc[-1]
        feats["vol_regime"] = volume.iloc[-1] / vol_mean if vol_mean else 1.0

        # --- Price context ---
        feats["price"] = close.iloc[-1]
        feats["return_1"] = close.pct_change().iloc[-1]

        # --- Cyclic time features ---
        if "timestamp" in df.columns:
            ts = pd.to_datetime(df["timestamp"].iloc[-1])
            feats["hour_sin"] = np.sin(2 * np.pi * ts.hour / 24)
            feats["hour_cos"] = np.cos(2 * np.pi * ts.hour / 24)
            feats["dow_sin"] = np.sin(2 * np.pi * ts.dayofweek / 7)
            feats["dow_cos"] = np.cos(2 * np.pi * ts.dayofweek / 7)

        # Replace any NaN with 0.0
        return {k: (0.0 if np.isnan(v) else float(v)) for k, v in feats.items()}

    def compute_returns(self, df: pd.DataFrame, periods: int = 5) -> list[float]:
        """Recent pct_change values as a list (for ngram encoding)."""
        returns = df["close"].pct_change().tail(periods).tolist()
        return [0.0 if np.isnan(r) else float(r) for r in returns]

    @staticmethod
    def _rsi(series: pd.Series, period: int) -> float:
        delta = series.diff()
        gain = delta.where(delta > 0, 0.0).rolling(period).mean().iloc[-1]
        loss = (-delta.where(delta < 0, 0.0)).rolling(period).mean().iloc[-1]
        if np.isnan(gain) or np.isnan(loss):
            return 50.0  # not enough data
        if loss == 0:
            return 100.0 if gain > 0 else 50.0  # all gains → overbought
        rs = gain / loss
        return float(100.0 - 100.0 / (1.0 + rs))

    @staticmethod
    def _atr(high: pd.Series, low: pd.Series, close: pd.Series, period: int) -> float:
        tr = pd.concat(
            [high - low, (high - close.shift()).abs(), (low - close.shift()).abs()],
            axis=1,
        ).max(axis=1)
        atr = tr.rolling(period).mean().iloc[-1]
        return 0.0 if np.isnan(atr) else float(atr)

    @staticmethod
    def _adx_proxy(
        high: pd.Series, low: pd.Series, close: pd.Series, period: int
    ) -> float:
        tr = pd.concat(
            [high - low, (high - close.shift()).abs(), (low - close.shift()).abs()],
            axis=1,
        ).max(axis=1)
        atr = tr.rolling(period).mean().iloc[-1]
        price = close.iloc[-1]
        if np.isnan(atr) or price == 0:
            return 0.0
        return float(atr / price)
