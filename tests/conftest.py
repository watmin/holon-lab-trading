"""Shared fixtures for holon-lab-trading tests."""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest


# ---------------------------------------------------------------------------
# OHLCV DataFrame builders
# ---------------------------------------------------------------------------

def make_flat_ohlcv(n: int, price: float = 50_000.0, volume: float = 10.0) -> pd.DataFrame:
    """Perfectly flat price series — every candle identical."""
    ts = pd.date_range("2024-01-01", periods=n, freq="5min")
    return pd.DataFrame(
        {
            "timestamp": ts,
            "open": price,
            "high": price,
            "low": price,
            "close": price,
            "volume": volume,
        }
    )


def make_trending_ohlcv(
    n: int,
    start: float = 40_000.0,
    end: float = 60_000.0,
    volume: float = 10.0,
) -> pd.DataFrame:
    """Linear uptrend from start to end over n candles."""
    prices = np.linspace(start, end, n)
    ts = pd.date_range("2024-01-01", periods=n, freq="5min")
    return pd.DataFrame(
        {
            "timestamp": ts,
            "open": prices,
            "high": prices * 1.001,
            "low": prices * 0.999,
            "close": prices,
            "volume": volume,
        }
    )


def make_volatile_ohlcv(n: int, seed: int = 42) -> pd.DataFrame:
    """Random-walk price series with realistic BTC-scale prices."""
    rng = np.random.default_rng(seed)
    returns = rng.normal(0, 0.005, n)
    prices = 50_000.0 * np.exp(np.cumsum(returns))
    ts = pd.date_range("2024-01-01", periods=n, freq="5min")
    return pd.DataFrame(
        {
            "timestamp": ts,
            "open": prices,
            "high": prices * (1 + rng.uniform(0, 0.003, n)),
            "low": prices * (1 - rng.uniform(0, 0.003, n)),
            "close": prices,
            "volume": rng.uniform(5.0, 50.0, n),
        }
    )


def make_short_ohlcv(n: int = 5, price: float = 50_000.0) -> pd.DataFrame:
    """Very short DataFrame — triggers NaN paths in rolling indicators."""
    return make_flat_ohlcv(n, price)


# ---------------------------------------------------------------------------
# Pytest fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def flat_df():
    return make_flat_ohlcv(200)


@pytest.fixture
def trending_df():
    return make_trending_ohlcv(200)


@pytest.fixture
def volatile_df():
    return make_volatile_ohlcv(200)


@pytest.fixture
def short_df():
    return make_short_ohlcv(5)


@pytest.fixture
def holon_client():
    """Shared HolonClient at dimensions=512 — fast for tests."""
    from holon import HolonClient
    return HolonClient(dimensions=512)
