//! vocab/ichimoku — Ichimoku Cloud system
//!
//! Cloud zone (above/below/in) and TK cross detection.
//! Ichimoku levels are streaming per-candle fields on the Candle struct
//! (computed by IndicatorBank from rolling 9/26/52-period high/low buffers).
//!
//! The 7 comparison pairs (close vs tenkan, kijun, cloud, spans) are handled
//! by COMPARISON_PAIRS in eval_comparisons — not duplicated here.

use crate::candle::Candle;
use super::Fact;

pub fn eval_ichimoku(candles: &[Candle]) -> Option<Vec<Fact<'static>>> {
    let n = candles.len();
    if n < 2 { return None; }

    let now = candles.last().unwrap();
    // Ichimoku fields are 0.0 during warmup (< 52 candles in IndicatorBank).
    // field_value filters 0.0 as None for non-derived fields.
    if now.cloud_top <= 0.0 { return None; }

    let close = now.close;
    let cloud_top = now.cloud_top;
    let cloud_bottom = now.cloud_bottom;
    let tenkan = now.tenkan_sen;
    let kijun = now.kijun_sen;

    let mut facts: Vec<Fact<'static>> = Vec::new();

    // Cloud zone
    let cloud_zone = if close > cloud_top { "above-cloud" }
                     else if close < cloud_bottom { "below-cloud" }
                     else { "in-cloud" };
    facts.push(Fact::Zone { indicator: "close", zone: cloud_zone });

    // Tenkan-kijun cross: compare current vs previous candle's streaming values
    let prev = &candles[n - 2];
    if prev.tenkan_sen > 0.0 {
        let prev_tenkan = prev.tenkan_sen;
        let prev_kijun = prev.kijun_sen;
        if prev_tenkan < prev_kijun && tenkan >= kijun {
            facts.push(Fact::Comparison { predicate: "crosses-above", a: "tenkan-sen", b: "kijun-sen" });
        } else if prev_tenkan > prev_kijun && tenkan <= kijun {
            facts.push(Fact::Comparison { predicate: "crosses-below", a: "tenkan-sen", b: "kijun-sen" });
        }
    }

    Some(facts)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_candle() -> Candle {
        Candle {
            ts: String::new(), open: 100.0, high: 105.0, low: 95.0, close: 100.0, volume: 50.0,
            sma20: 100.0, sma50: 100.0, sma200: 100.0,
            bb_upper: 105.0, bb_lower: 95.0, bb_width: 0.0,
            rsi: 50.0, macd_line: 0.0, macd_signal: 0.0, macd_hist: 0.0,
            dmi_plus: 20.0, dmi_minus: 15.0, adx: 25.0,
            atr: 2.0, atr_r: 0.02, stoch_k: 50.0, stoch_d: 45.0,
            williams_r: -50.0, cci: 0.0, mfi: 50.0,
            roc_1: 0.0, roc_3: 0.0, roc_6: 0.0, roc_12: 0.0,
            obv_slope_12: 0.0, volume_sma_20: 0.0,
            tf_1h_close: 0.0, tf_1h_high: 0.0, tf_1h_low: 0.0, tf_1h_ret: 0.0, tf_1h_body: 0.0,
            tf_4h_close: 0.0, tf_4h_high: 0.0, tf_4h_low: 0.0, tf_4h_ret: 0.0, tf_4h_body: 0.0,
            tenkan_sen: 0.0, kijun_sen: 0.0, senkou_span_a: 0.0, senkou_span_b: 0.0,
            cloud_top: 0.0, cloud_bottom: 0.0,
            bb_pos: 0.5, kelt_upper: 0.0, kelt_lower: 0.0, kelt_pos: 0.5,
            squeeze: false,
            range_pos_12: 0.5, range_pos_24: 0.5, range_pos_48: 0.5,
            trend_consistency_6: 0.5, trend_consistency_12: 0.5, trend_consistency_24: 0.5,
            atr_roc_6: 0.0, atr_roc_12: 0.0, vol_accel: 0.0,
            hour: 0.0, day_of_week: 0.0,
        }
    }

    fn with_ichimoku(close: f64, tenkan: f64, kijun: f64, span_a: f64, span_b: f64) -> Candle {
        let mut c = base_candle();
        c.close = close;
        c.tenkan_sen = tenkan;
        c.kijun_sen = kijun;
        c.senkou_span_a = span_a;
        c.senkou_span_b = span_b;
        c.cloud_top = span_a.max(span_b);
        c.cloud_bottom = span_a.min(span_b);
        c
    }

    #[test]
    fn ichimoku_above_cloud() {
        let c = with_ichimoku(110.0, 105.0, 100.0, 102.5, 98.0);
        let facts = eval_ichimoku(&[c.clone(), c]).unwrap();
        assert!(facts.iter().any(|f| matches!(f, Fact::Zone { zone: "above-cloud", .. })));
    }

    #[test]
    fn ichimoku_below_cloud() {
        let c = with_ichimoku(90.0, 105.0, 100.0, 102.5, 98.0);
        let facts = eval_ichimoku(&[c.clone(), c]).unwrap();
        assert!(facts.iter().any(|f| matches!(f, Fact::Zone { zone: "below-cloud", .. })));
    }

    #[test]
    fn ichimoku_in_cloud() {
        let c = with_ichimoku(100.0, 105.0, 100.0, 102.5, 98.0);
        let facts = eval_ichimoku(&[c.clone(), c]).unwrap();
        assert!(facts.iter().any(|f| matches!(f, Fact::Zone { zone: "in-cloud", .. })));
    }

    #[test]
    fn ichimoku_tk_cross_above() {
        let prev = with_ichimoku(100.0, 99.0, 101.0, 100.0, 98.0);
        let now = with_ichimoku(102.0, 101.0, 100.0, 100.5, 98.0);
        let facts = eval_ichimoku(&[prev, now]).unwrap();
        assert!(facts.iter().any(|f| matches!(f, Fact::Comparison { predicate: "crosses-above", .. })));
    }

    #[test]
    fn ichimoku_returns_none_during_warmup() {
        let c = base_candle(); // cloud_top = 0.0
        assert!(eval_ichimoku(&[c.clone(), c]).is_none());
    }
}
