//! candle.wat -- the enriched candle struct
//! Depends on: indicator-bank.wat (produced by tick)

/// The enriched candle. Raw OHLCV in, 100+ computed indicators out.
/// Produced by IndicatorBank.tick(raw_candle).
#[derive(Clone, Debug)]
pub struct Candle {
    // Raw
    pub ts: String,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    // Moving averages
    pub sma20: f64,
    pub sma50: f64,
    pub sma200: f64,
    // Bollinger
    pub bb_upper: f64,
    pub bb_lower: f64,
    pub bb_width: f64,
    pub bb_pos: f64,
    // RSI, MACD, DMI, ATR
    pub rsi: f64,
    pub macd: f64,
    pub macd_signal: f64,
    pub macd_hist: f64,
    pub plus_di: f64,
    pub minus_di: f64,
    pub adx: f64,
    pub atr: f64,
    pub atr_r: f64,
    // Stochastic, CCI, MFI, OBV, Williams %R
    pub stoch_k: f64,
    pub stoch_d: f64,
    pub williams_r: f64,
    pub cci: f64,
    pub mfi: f64,
    pub obv_slope_12: f64,
    pub volume_accel: f64,
    // Keltner, squeeze
    pub kelt_upper: f64,
    pub kelt_lower: f64,
    pub kelt_pos: f64,
    pub squeeze: f64,
    // Rate of Change
    pub roc_1: f64,
    pub roc_3: f64,
    pub roc_6: f64,
    pub roc_12: f64,
    // ATR rate of change
    pub atr_roc_6: f64,
    pub atr_roc_12: f64,
    // Trend consistency
    pub trend_consistency_6: f64,
    pub trend_consistency_12: f64,
    pub trend_consistency_24: f64,
    // Range position
    pub range_pos_12: f64,
    pub range_pos_24: f64,
    pub range_pos_48: f64,
    // Multi-timeframe
    pub tf_1h_close: f64,
    pub tf_1h_high: f64,
    pub tf_1h_low: f64,
    pub tf_1h_ret: f64,
    pub tf_1h_body: f64,
    pub tf_4h_close: f64,
    pub tf_4h_high: f64,
    pub tf_4h_low: f64,
    pub tf_4h_ret: f64,
    pub tf_4h_body: f64,
    // Ichimoku
    pub tenkan_sen: f64,
    pub kijun_sen: f64,
    pub senkou_span_a: f64,
    pub senkou_span_b: f64,
    pub cloud_top: f64,
    pub cloud_bottom: f64,
    // Persistence
    pub hurst: f64,
    pub autocorrelation: f64,
    pub vwap_distance: f64,
    // Regime
    pub kama_er: f64,
    pub choppiness: f64,
    pub dfa_alpha: f64,
    pub variance_ratio: f64,
    pub entropy_rate: f64,
    pub aroon_up: f64,
    pub aroon_down: f64,
    pub fractal_dim: f64,
    // Divergence
    pub rsi_divergence_bull: f64,
    pub rsi_divergence_bear: f64,
    // Ichimoku cross delta
    pub tk_cross_delta: f64,
    // Stochastic cross delta
    pub stoch_cross_delta: f64,
    // Price action
    pub range_ratio: f64,
    pub gap: f64,
    pub consecutive_up: f64,
    pub consecutive_down: f64,
    // Timeframe agreement
    pub tf_agreement: f64,
    // Time -- circular scalars
    pub minute: f64,
    pub hour: f64,
    pub day_of_week: f64,
    pub day_of_month: f64,
    pub month_of_year: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a Candle with known values for every field.
    fn make_test_candle() -> Candle {
        Candle {
            // Raw
            ts: "2025-01-01T00:00:00Z".to_string(),
            open: 100.0,
            high: 110.0,
            low: 90.0,
            close: 105.0,
            volume: 5000.0,
            // Moving averages
            sma20: 101.0,
            sma50: 99.0,
            sma200: 95.0,
            // Bollinger
            bb_upper: 115.0,
            bb_lower: 85.0,
            bb_width: 30.0,
            bb_pos: 0.67,
            // RSI, MACD, DMI, ATR
            rsi: 55.0,
            macd: 1.2,
            macd_signal: 0.8,
            macd_hist: 0.4,
            plus_di: 25.0,
            minus_di: 20.0,
            adx: 30.0,
            atr: 5.0,
            atr_r: 0.05,
            // Stochastic, CCI, MFI, OBV, Williams %R
            stoch_k: 70.0,
            stoch_d: 65.0,
            williams_r: -30.0,
            cci: 100.0,
            mfi: 60.0,
            obv_slope_12: 0.01,
            volume_accel: 0.5,
            // Keltner, squeeze
            kelt_upper: 112.0,
            kelt_lower: 88.0,
            kelt_pos: 0.7,
            squeeze: 0.0,
            // Rate of Change
            roc_1: 0.01,
            roc_3: 0.03,
            roc_6: 0.05,
            roc_12: 0.10,
            // ATR rate of change
            atr_roc_6: 0.02,
            atr_roc_12: 0.04,
            // Trend consistency
            trend_consistency_6: 0.8,
            trend_consistency_12: 0.7,
            trend_consistency_24: 0.6,
            // Range position
            range_pos_12: 0.75,
            range_pos_24: 0.65,
            range_pos_48: 0.55,
            // Multi-timeframe
            tf_1h_close: 104.0,
            tf_1h_high: 111.0,
            tf_1h_low: 89.0,
            tf_1h_ret: 0.02,
            tf_1h_body: 0.5,
            tf_4h_close: 103.0,
            tf_4h_high: 112.0,
            tf_4h_low: 88.0,
            tf_4h_ret: 0.03,
            tf_4h_body: 0.4,
            // Ichimoku
            tenkan_sen: 102.0,
            kijun_sen: 100.0,
            senkou_span_a: 101.0,
            senkou_span_b: 98.0,
            cloud_top: 101.0,
            cloud_bottom: 98.0,
            // Persistence
            hurst: 0.55,
            autocorrelation: 0.3,
            vwap_distance: 0.01,
            // Regime
            kama_er: 0.5,
            choppiness: 50.0,
            dfa_alpha: 0.6,
            variance_ratio: 1.1,
            entropy_rate: 0.9,
            aroon_up: 80.0,
            aroon_down: 20.0,
            fractal_dim: 1.5,
            // Divergence
            rsi_divergence_bull: 0.0,
            rsi_divergence_bear: 0.0,
            // Ichimoku cross delta
            tk_cross_delta: 2.0,
            // Stochastic cross delta
            stoch_cross_delta: 5.0,
            // Price action
            range_ratio: 0.2,
            gap: 0.0,
            consecutive_up: 3.0,
            consecutive_down: 0.0,
            // Timeframe agreement
            tf_agreement: 0.8,
            // Time
            minute: 30.0,
            hour: 14.0,
            day_of_week: 3.0,
            day_of_month: 15.0,
            month_of_year: 6.0,
        }
    }

    #[test]
    fn test_candle_raw_fields() {
        let c = make_test_candle();
        assert_eq!(c.ts, "2025-01-01T00:00:00Z");
        assert_eq!(c.open, 100.0);
        assert_eq!(c.high, 110.0);
        assert_eq!(c.low, 90.0);
        assert_eq!(c.close, 105.0);
        assert_eq!(c.volume, 5000.0);
    }

    #[test]
    fn test_candle_oscillators() {
        let c = make_test_candle();
        assert_eq!(c.rsi, 55.0);
        assert_eq!(c.macd, 1.2);
        assert_eq!(c.macd_signal, 0.8);
        assert_eq!(c.macd_hist, 0.4);
        assert_eq!(c.stoch_k, 70.0);
        assert_eq!(c.stoch_d, 65.0);
        assert_eq!(c.williams_r, -30.0);
    }

    #[test]
    fn test_candle_regime() {
        let c = make_test_candle();
        assert_eq!(c.kama_er, 0.5);
        assert_eq!(c.choppiness, 50.0);
        assert_eq!(c.dfa_alpha, 0.6);
        assert_eq!(c.variance_ratio, 1.1);
        assert_eq!(c.entropy_rate, 0.9);
        assert_eq!(c.fractal_dim, 1.5);
    }

    #[test]
    fn test_candle_time_circular() {
        let c = make_test_candle();
        assert_eq!(c.minute, 30.0);
        assert_eq!(c.hour, 14.0);
        assert_eq!(c.day_of_week, 3.0);
        assert_eq!(c.day_of_month, 15.0);
        assert_eq!(c.month_of_year, 6.0);
    }

    #[test]
    fn test_candle_moving_averages() {
        let c = make_test_candle();
        assert_eq!(c.sma20, 101.0);
        assert_eq!(c.sma50, 99.0);
        assert_eq!(c.sma200, 95.0);
    }

    #[test]
    fn test_candle_multi_timeframe() {
        let c = make_test_candle();
        assert_eq!(c.tf_1h_close, 104.0);
        assert_eq!(c.tf_4h_close, 103.0);
        assert_eq!(c.tf_1h_ret, 0.02);
        assert_eq!(c.tf_4h_ret, 0.03);
    }

    #[test]
    fn test_candle_clone() {
        let c = make_test_candle();
        let c2 = c.clone();
        assert_eq!(c2.close, 105.0);
        assert_eq!(c2.rsi, 55.0);
    }
}
