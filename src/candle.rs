// Candle struct — the computed indicator values for one candle.
// Built by IndicatorBank::tick() from raw OHLCV.

#[allow(dead_code)]
#[derive(Clone, Debug)]
pub struct Candle {
    // Raw OHLCV
    pub ts: String,
    pub year: i32,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,

    // Moving averages
    pub sma20: f64,
    pub sma50: f64,
    pub sma200: f64,

    // Bollinger Bands
    pub bb_upper: f64,
    pub bb_lower: f64,
    pub bb_width: f64,

    // RSI (14-period Wilder)
    pub rsi: f64,

    // MACD (12, 26, 9)
    pub macd_line: f64,
    pub macd_signal: f64,
    pub macd_hist: f64,

    // DMI / ADX (14-period)
    pub dmi_plus: f64,
    pub dmi_minus: f64,
    pub adx: f64,

    // ATR (14-period)
    pub atr: f64,
    pub atr_r: f64,

    // Stochastic (14-period)
    pub stoch_k: f64,
    pub stoch_d: f64,

    // Williams %R (14-period)
    pub williams_r: f64,

    // CCI (20-period)
    pub cci: f64,

    // MFI (14-period)
    pub mfi: f64,

    // Rate of change
    pub roc_1: f64,
    pub roc_3: f64,
    pub roc_6: f64,
    pub roc_12: f64,

    // OBV slope (12-period)
    pub obv_slope_12: f64,

    // Volume SMA
    pub volume_sma_20: f64,

    // Multi-timeframe (1h = 12 candles, 4h = 48 candles)
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

    // Derived
    pub bb_pos: f64,
    pub kelt_upper: f64,
    pub kelt_lower: f64,
    pub kelt_pos: f64,
    pub squeeze: bool,
    pub range_pos_12: f64,
    pub range_pos_24: f64,
    pub range_pos_48: f64,
    pub trend_consistency_6: f64,
    pub trend_consistency_12: f64,
    pub trend_consistency_24: f64,
    pub atr_roc_6: f64,
    pub atr_roc_12: f64,
    pub vol_accel: f64,

    // Time — f64 because they feed encode_circular as continuous scalars.
    pub hour: f64,
    pub day_of_week: f64,

    // Label (oracle — prophetic, not causal)
}

// load_candles and sf() removed — the enterprise streams from parquet now.
// The IndicatorBank computes indicators per-desk. No pre-computed SQLite.
