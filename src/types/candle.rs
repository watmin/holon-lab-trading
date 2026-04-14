/// The enriched candle — raw OHLCV in, 100+ computed indicators out.
/// Produced by IndicatorBank.tick(ohlcv).

use crate::types::pivot::{PhaseDirection, PhaseLabel, PhaseRecord};

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
    pub bb_width: f64,
    pub bb_pos: f64,
    // RSI, MACD, DMI, ATR
    pub rsi: f64,
    pub macd_hist: f64,
    pub plus_di: f64,
    pub minus_di: f64,
    pub adx: f64,
    pub atr_ratio: f64,
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
    // Range position
    pub range_pos_12: f64,
    pub range_pos_24: f64,
    pub range_pos_48: f64,
    // Multi-timeframe
    pub tf_1h_ret: f64,
    pub tf_1h_body: f64,
    pub tf_4h_ret: f64,
    pub tf_4h_body: f64,
    // Ichimoku
    pub tenkan_sen: f64,
    pub kijun_sen: f64,
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
    // Cross deltas
    pub tk_cross_delta: f64,
    pub stoch_cross_delta: f64,
    // Price action
    pub range_ratio: f64,
    pub gap: f64,
    pub consecutive_up: f64,
    pub consecutive_down: f64,
    // Timeframe agreement
    pub tf_agreement: f64,
    // Time — circular scalars
    pub minute: f64,
    pub hour: f64,
    pub day_of_week: f64,
    pub day_of_month: f64,
    pub month_of_year: f64,
    // Phase labeler — proposal 049
    pub phase_label: PhaseLabel,
    pub phase_direction: PhaseDirection,
    pub phase_duration: usize,
    pub phase_history: Vec<PhaseRecord>,
}

impl Default for Candle {
    fn default() -> Self {
        Candle {
            ts: "2024-01-01T00:00:00".into(),
            open: 42000.0,
            high: 42500.0,
            low: 41500.0,
            close: 42200.0,
            volume: 100.0,
            sma20: 42000.0,
            sma50: 41800.0,
            sma200: 40000.0,
            bb_width: 0.047,
            bb_pos: 0.6,
            rsi: 55.0,
            macd_hist: 5.0,
            plus_di: 25.0,
            minus_di: 20.0,
            adx: 30.0,
            atr_ratio: 0.012,
            stoch_k: 70.0,
            stoch_d: 65.0,
            williams_r: -30.0,
            cci: 80.0,
            mfi: 60.0,
            obv_slope_12: 100.0,
            volume_accel: 1.2,
            kelt_upper: 43000.0,
            kelt_lower: 41000.0,
            kelt_pos: 0.6,
            squeeze: 0.95,
            roc_1: 0.005,
            roc_3: 0.01,
            roc_6: 0.02,
            roc_12: 0.03,
            range_pos_12: 0.7,
            range_pos_24: 0.65,
            range_pos_48: 0.6,
            tf_1h_ret: 0.005,
            tf_1h_body: 0.4,
            tf_4h_ret: 0.01,
            tf_4h_body: 0.35,
            tenkan_sen: 42100.0,
            kijun_sen: 41900.0,
            cloud_top: 42000.0,
            cloud_bottom: 41800.0,
            hurst: 0.55,
            autocorrelation: 0.1,
            vwap_distance: 0.002,
            kama_er: 0.3,
            choppiness: 45.0,
            dfa_alpha: 0.55,
            variance_ratio: 1.05,
            entropy_rate: 0.8,
            aroon_up: 80.0,
            aroon_down: 20.0,
            fractal_dim: 1.4,
            rsi_divergence_bull: 0.0,
            rsi_divergence_bear: 0.0,
            tk_cross_delta: 10.0,
            stoch_cross_delta: 5.0,
            range_ratio: 1.1,
            gap: 0.001,
            consecutive_up: 3.0,
            consecutive_down: 0.0,
            tf_agreement: 0.67,
            minute: 30.0,
            hour: 14.0,
            day_of_week: 3.0,
            day_of_month: 15.0,
            month_of_year: 6.0,
            phase_label: PhaseLabel::Valley,
            phase_direction: PhaseDirection::None,
            phase_duration: 0,
            phase_history: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_candle_construct() {
        let c = Candle::default();
        assert_eq!(c.ts, "2024-01-01T00:00:00");
        assert_eq!(c.close, 42200.0);
        assert_eq!(c.sma20, 42000.0);
        assert_eq!(c.rsi, 55.0);
    }

    #[test]
    fn test_candle_clone() {
        let c = Candle::default();
        let c2 = c.clone();
        assert_eq!(c.close, c2.close);
        assert_eq!(c.ts, c2.ts);
        assert_eq!(c.hurst, c2.hurst);
    }

    #[test]
    fn test_candle_field_count() {
        // Verify all fields exist by constructing explicitly
        let c = Candle {
            ts: String::new(),
            open: 0.0, high: 0.0, low: 0.0, close: 0.0, volume: 0.0,
            sma20: 0.0, sma50: 0.0, sma200: 0.0,
            bb_width: 0.0, bb_pos: 0.0,
            rsi: 0.0, macd_hist: 0.0,
            plus_di: 0.0, minus_di: 0.0, adx: 0.0, atr_ratio: 0.0,
            stoch_k: 0.0, stoch_d: 0.0, williams_r: 0.0, cci: 0.0, mfi: 0.0,
            obv_slope_12: 0.0, volume_accel: 0.0,
            kelt_upper: 0.0, kelt_lower: 0.0, kelt_pos: 0.0, squeeze: 0.0,
            roc_1: 0.0, roc_3: 0.0, roc_6: 0.0, roc_12: 0.0,
            range_pos_12: 0.0, range_pos_24: 0.0, range_pos_48: 0.0,
            tf_1h_ret: 0.0, tf_1h_body: 0.0,
            tf_4h_ret: 0.0, tf_4h_body: 0.0,
            tenkan_sen: 0.0, kijun_sen: 0.0,
            cloud_top: 0.0, cloud_bottom: 0.0,
            hurst: 0.0, autocorrelation: 0.0, vwap_distance: 0.0,
            kama_er: 0.0, choppiness: 0.0, dfa_alpha: 0.0, variance_ratio: 0.0,
            entropy_rate: 0.0, aroon_up: 0.0, aroon_down: 0.0, fractal_dim: 0.0,
            rsi_divergence_bull: 0.0, rsi_divergence_bear: 0.0,
            tk_cross_delta: 0.0, stoch_cross_delta: 0.0,
            range_ratio: 0.0, gap: 0.0, consecutive_up: 0.0, consecutive_down: 0.0,
            tf_agreement: 0.0,
            minute: 0.0, hour: 0.0, day_of_week: 0.0, day_of_month: 0.0, month_of_year: 0.0,
            phase_label: PhaseLabel::Valley, phase_direction: PhaseDirection::None,
            phase_duration: 0, phase_history: Vec::new(),
        };
        assert_eq!(c.close, 0.0);
    }
}
