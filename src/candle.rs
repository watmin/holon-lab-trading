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
