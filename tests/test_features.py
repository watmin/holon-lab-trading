"""Unit tests for TechnicalFeatureFactory.

Covers:
- All indicator fields present in output
- NaN replacement on short series
- Determinism (same input → same output)
- Known-value checks on controllable inputs
- Cyclic time features present when timestamp column exists
- compute_returns shape and NaN handling
- Edge: zero volume, flat price, price going to zero
"""

from __future__ import annotations

import math

import numpy as np
import pandas as pd  # noqa: F401 — used in TestComputeIndicators isinstance check
import pytest

from tests.conftest import make_flat_ohlcv, make_trending_ohlcv, make_volatile_ohlcv, make_short_ohlcv
from trading.features import TechnicalFeatureFactory

EXPECTED_FIELDS = {
    "sma_short", "sma_long", "sma_cross",
    "bb_upper", "bb_lower", "bb_width",
    "macd_line", "macd_signal", "macd_hist",
    "rsi", "atr", "adx",
    "vol_regime", "price", "return_1",
}

CYCLIC_FIELDS = {"hour_sin", "hour_cos", "dow_sin", "dow_cos"}


class TestFieldPresence:
    def test_all_base_fields_present(self, flat_df):
        f = TechnicalFeatureFactory()
        result = f.compute(flat_df)
        missing = EXPECTED_FIELDS - result.keys()
        assert not missing, f"Missing fields: {missing}"

    def test_cyclic_fields_present_with_timestamp(self, flat_df):
        f = TechnicalFeatureFactory()
        result = f.compute(flat_df)
        missing = CYCLIC_FIELDS - result.keys()
        assert not missing, f"Missing cyclic fields: {missing}"

    def test_cyclic_fields_absent_without_timestamp(self):
        f = TechnicalFeatureFactory()
        df = make_flat_ohlcv(200).drop(columns=["timestamp"])
        result = f.compute(df)
        for field in CYCLIC_FIELDS:
            assert field not in result

    def test_all_values_are_floats(self, volatile_df):
        f = TechnicalFeatureFactory()
        result = f.compute(volatile_df)
        for k, v in result.items():
            assert isinstance(v, float), f"{k} is {type(v)}, expected float"


class TestNaNHandling:
    def test_no_nans_in_output(self, short_df):
        """Even on a 5-candle series all NaN paths should produce 0.0."""
        f = TechnicalFeatureFactory()
        result = f.compute(short_df)
        for k, v in result.items():
            assert not math.isnan(v), f"NaN in field {k}"

    def test_no_nans_on_full_series(self, volatile_df):
        f = TechnicalFeatureFactory()
        result = f.compute(volatile_df)
        for k, v in result.items():
            assert not math.isnan(v), f"NaN in field {k}"

    def test_compute_returns_no_nans(self, short_df):
        f = TechnicalFeatureFactory()
        returns = f.compute_returns(short_df, periods=5)
        for r in returns:
            assert not math.isnan(r)

    def test_zero_volume_no_crash(self):
        df = make_flat_ohlcv(200, volume=0.0)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert not math.isnan(result["vol_regime"])


class TestDeterminism:
    def test_same_input_same_output(self, volatile_df):
        f = TechnicalFeatureFactory()
        r1 = f.compute(volatile_df)
        r2 = f.compute(volatile_df)
        assert r1 == r2

    def test_independent_instances_agree(self, volatile_df):
        r1 = TechnicalFeatureFactory().compute(volatile_df)
        r2 = TechnicalFeatureFactory().compute(volatile_df)
        assert r1 == r2


class TestKnownValues:
    def test_flat_price_sma_equals_price(self):
        price = 50_000.0
        df = make_flat_ohlcv(200, price=price)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert math.isclose(result["sma_short"], price, rel_tol=1e-9)
        assert math.isclose(result["sma_long"], price, rel_tol=1e-9)

    def test_flat_price_sma_cross_is_zero(self):
        df = make_flat_ohlcv(200)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert math.isclose(result["sma_cross"], 0.0, abs_tol=1e-6)

    def test_flat_price_bb_width_is_zero(self):
        """Flat price → zero std → zero BB width."""
        df = make_flat_ohlcv(200)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert math.isclose(result["bb_width"], 0.0, abs_tol=1e-6)

    def test_flat_price_rsi_is_neutral(self):
        """Flat price → gain=0, loss=0 → RSI=50 (neutral, no direction)."""
        df = make_flat_ohlcv(200)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert math.isclose(result["rsi"], 50.0, abs_tol=0.1)

    def test_uptrend_sma_short_above_sma_long(self):
        """In a long uptrend, short SMA should be above long SMA at the end."""
        df = make_trending_ohlcv(200, start=30_000, end=60_000)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert result["sma_short"] > result["sma_long"]
        assert result["sma_cross"] > 0

    def test_price_field_matches_last_close(self, volatile_df):
        f = TechnicalFeatureFactory()
        result = f.compute(volatile_df)
        assert math.isclose(result["price"], volatile_df["close"].iloc[-1], rel_tol=1e-9)

    def test_vol_regime_flat_volume(self):
        """Flat volume → regime ≈ 1.0."""
        df = make_flat_ohlcv(200, volume=10.0)
        f = TechnicalFeatureFactory(vol_regime_window=10)
        result = f.compute(df)
        assert math.isclose(result["vol_regime"], 1.0, rel_tol=1e-6)

    def test_cyclic_hour_bounds(self, flat_df):
        f = TechnicalFeatureFactory()
        result = f.compute(flat_df)
        assert -1.0 <= result["hour_sin"] <= 1.0
        assert -1.0 <= result["hour_cos"] <= 1.0

    def test_cyclic_dow_bounds(self, flat_df):
        f = TechnicalFeatureFactory()
        result = f.compute(flat_df)
        assert -1.0 <= result["dow_sin"] <= 1.0
        assert -1.0 <= result["dow_cos"] <= 1.0

    def test_rsi_all_gains_near_100(self):
        """Continuous uptrend → RSI near 100."""
        df = make_trending_ohlcv(200, start=1_000, end=100_000)
        f = TechnicalFeatureFactory(rsi_period=14)
        result = f.compute(df)
        assert result["rsi"] > 70.0

    def test_macd_hist_sign_in_uptrend(self):
        """In a sustained uptrend the fast EMA leads the slow, so hist > 0."""
        df = make_trending_ohlcv(200, start=30_000, end=60_000)
        f = TechnicalFeatureFactory()
        result = f.compute(df)
        assert result["macd_hist"] > 0


class TestComputeReturns:
    def test_returns_length(self, volatile_df):
        f = TechnicalFeatureFactory()
        returns = f.compute_returns(volatile_df, periods=5)
        assert len(returns) == 5

    def test_returns_all_floats(self, volatile_df):
        f = TechnicalFeatureFactory()
        returns = f.compute_returns(volatile_df, periods=5)
        for r in returns:
            assert isinstance(r, float)

    def test_returns_on_flat_series_are_zero(self):
        df = make_flat_ohlcv(200)
        f = TechnicalFeatureFactory()
        returns = f.compute_returns(df, periods=5)
        # Last candle pct_change is 0 on a flat series
        for r in returns:
            assert math.isclose(r, 0.0, abs_tol=1e-9)

    def test_short_series_returns_no_nan(self):
        df = make_short_ohlcv(3)
        f = TechnicalFeatureFactory()
        returns = f.compute_returns(df, periods=5)
        for r in returns:
            assert not math.isnan(r)


class TestComputeIndicators:
    """Tests for the new compute_indicators() and compute_candle_row() methods."""

    def test_compute_indicators_returns_dataframe(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        result = f.compute_indicators(df)
        assert isinstance(result, pd.DataFrame)

    def test_compute_indicators_has_expected_columns(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        result = f.compute_indicators(df)
        expected = {
            "sma20", "sma50", "sma200",
            "bb_upper", "bb_lower", "bb_width",
            "macd_line", "macd_signal", "macd_hist",
            "rsi", "atr", "dmi_plus", "dmi_minus", "adx", "ret",
        }
        missing = expected - set(result.columns)
        assert not missing, f"Missing columns: {missing}"

    def test_compute_indicators_no_nan(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        result = f.compute_indicators(df)
        assert not result.isnull().any().any(), "NaN values remain after dropna"

    def test_compute_indicators_shorter_than_input(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        result = f.compute_indicators(df)
        # NaN rows dropped — result should have fewer rows
        assert len(result) < len(df)
        assert len(result) > 0

    def test_compute_candle_row_nested_structure(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        df_ind = f.compute_indicators(df)
        row = f.compute_candle_row(df_ind, len(df_ind) - 1)

        assert "ohlcv" in row
        for k in ("open", "high", "low", "close"):
            assert k in row["ohlcv"]
        for k in ("vol", "atr", "rsi", "ret"):
            assert k in row
        assert "sma" in row
        for k in ("s20", "s50", "s200"):
            assert k in row["sma"]
        assert "macd" in row
        assert "bb" in row
        assert "dmi" in row

    def test_compute_candle_row_values_finite(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        df_ind = f.compute_indicators(df)
        row = f.compute_candle_row(df_ind, len(df_ind) - 1)

        def check_dict(d):
            for v in d.values():
                if isinstance(v, dict):
                    check_dict(v)
                else:
                    assert math.isfinite(v), f"Non-finite value: {v}"

        check_dict(row)

    def test_compute_candle_row_prices_positive(self):
        df = make_volatile_ohlcv(250)
        f = TechnicalFeatureFactory()
        df_ind = f.compute_indicators(df)
        row = f.compute_candle_row(df_ind, len(df_ind) - 1)
        for k in ("open", "high", "low", "close"):
            assert row["ohlcv"][k] > 0


class TestConfigurablePeriods:
    def test_custom_periods_accepted(self, volatile_df):
        f = TechnicalFeatureFactory(
            sma_short=5, sma_long=20, bb_period=10, rsi_period=7, atr_period=7
        )
        result = f.compute(volatile_df)
        assert EXPECTED_FIELDS.issubset(result.keys())

    def test_minimum_period_one_no_crash(self, volatile_df):
        f = TechnicalFeatureFactory(sma_short=1, sma_long=1, rsi_period=1, atr_period=1)
        result = f.compute(volatile_df)
        for v in result.values():
            assert not math.isnan(v)
