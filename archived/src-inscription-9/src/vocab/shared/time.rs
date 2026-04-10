/// Universal time context — circular scalars that wrap.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

/// Encode time facts from a candle.
/// minute (mod 60), hour (mod 24), day-of-week (mod 7),
/// day-of-month (mod 31), month-of-year (mod 12).
pub fn encode_time_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        ThoughtAST::Circular { name: "minute".into(), value: c.minute, period: 60.0 },
        ThoughtAST::Circular { name: "hour".into(), value: c.hour, period: 24.0 },
        ThoughtAST::Circular { name: "day-of-week".into(), value: c.day_of_week, period: 7.0 },
        ThoughtAST::Circular { name: "day-of-month".into(), value: c.day_of_month, period: 31.0 },
        ThoughtAST::Circular { name: "month-of-year".into(), value: c.month_of_year, period: 12.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candle::Candle;

    fn make_test_candle() -> Candle {
        Candle {
            ts: "2024-01-01T00:00:00".into(),
            open: 42000.0, high: 42500.0, low: 41500.0, close: 42200.0, volume: 100.0,
            sma20: 42000.0, sma50: 41800.0, sma200: 40000.0,
            bb_upper: 43000.0, bb_lower: 41000.0, bb_width: 0.047, bb_pos: 0.6,
            rsi: 0.55, macd: 50.0, macd_signal: 45.0, macd_hist: 5.0,
            plus_di: 25.0, minus_di: 20.0, adx: 30.0, atr: 500.0, atr_r: 0.012,
            stoch_k: 0.7, stoch_d: 0.65, williams_r: 0.3, cci: 80.0, mfi: 0.6,
            obv_slope_12: 100.0, volume_accel: 1.2,
            kelt_upper: 43000.0, kelt_lower: 41000.0, kelt_pos: 0.6, squeeze: 0.95,
            roc_1: 0.005, roc_3: 0.01, roc_6: 0.02, roc_12: 0.03,
            atr_roc_6: 0.01, atr_roc_12: 0.02,
            trend_consistency_6: 0.6, trend_consistency_12: 0.55, trend_consistency_24: 0.5,
            range_pos_12: 0.7, range_pos_24: 0.65, range_pos_48: 0.6,
            tf_1h_close: 42200.0, tf_1h_high: 42500.0, tf_1h_low: 41500.0,
            tf_1h_ret: 0.005, tf_1h_body: 0.4,
            tf_4h_close: 42200.0, tf_4h_high: 42800.0, tf_4h_low: 41200.0,
            tf_4h_ret: 0.01, tf_4h_body: 0.35,
            tenkan_sen: 42100.0, kijun_sen: 41900.0,
            senkou_span_a: 42000.0, senkou_span_b: 41800.0,
            cloud_top: 42000.0, cloud_bottom: 41800.0,
            hurst: 0.55, autocorrelation: 0.1, vwap_distance: 0.002,
            kama_er: 0.3, choppiness: 45.0, dfa_alpha: 0.55, variance_ratio: 1.05,
            entropy_rate: 0.8, aroon_up: 80.0, aroon_down: 20.0, fractal_dim: 1.4,
            rsi_divergence_bull: 0.0, rsi_divergence_bear: 0.0,
            tk_cross_delta: 10.0, stoch_cross_delta: 5.0,
            range_ratio: 1.1, gap: 0.001, consecutive_up: 3.0, consecutive_down: 0.0,
            tf_agreement: 0.67,
            minute: 30.0, hour: 14.0, day_of_week: 3.0, day_of_month: 15.0, month_of_year: 6.0,
        }
    }

    #[test]
    fn test_encode_time_facts_non_empty() {
        let c = make_test_candle();
        let facts = encode_time_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_encode_time_facts_are_circular() {
        let c = make_test_candle();
        let facts = encode_time_facts(&c);
        for fact in &facts {
            match fact {
                ThoughtAST::Circular { .. } => {}
                _ => panic!("Expected all time facts to be Circular"),
            }
        }
    }
}
