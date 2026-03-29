use rusqlite::Connection;
use std::path::Path;

#[allow(dead_code)]
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

    // Time
    pub hour: f64,
    pub day_of_week: f64,

    // Label (oracle — prophetic, not causal)
    pub label: String,
}

fn sf(row: &rusqlite::Row, idx: usize) -> f64 {
    row.get::<_, Option<f64>>(idx).unwrap_or(None).unwrap_or(0.0)
}

pub fn load_candles(db_path: &Path, label_col: &str) -> Vec<Candle> {
    let conn = Connection::open(db_path).expect("failed to open database");

    let sql = format!(
        "SELECT ts, year, open, high, low, close, volume, \
         sma20, sma50, sma200, \
         bb_upper, bb_lower, bb_width, \
         rsi, \
         macd_line, macd_signal, macd_hist, \
         dmi_plus, dmi_minus, adx, \
         atr, atr_r, \
         stoch_k, stoch_d, \
         williams_r, \
         cci, \
         mfi, \
         roc_1, roc_3, roc_6, roc_12, \
         obv_slope_12, \
         volume_sma_20, \
         tf_1h_close, tf_1h_high, tf_1h_low, tf_1h_ret, tf_1h_body, \
         tf_4h_close, tf_4h_high, tf_4h_low, tf_4h_ret, tf_4h_body, \
         bb_pos, kelt_upper, kelt_lower, kelt_pos, squeeze, \
         range_pos_12, range_pos_24, range_pos_48, \
         trend_consistency_6, trend_consistency_12, trend_consistency_24, \
         atr_roc_6, atr_roc_12, \
         vol_accel, \
         hour, day_of_week, \
         {label_col} \
         FROM candles ORDER BY ts"
    );

    let mut stmt = conn.prepare(&sql).expect("failed to prepare query");
    let candles = stmt
        .query_map([], |row| {
            Ok(Candle {
                ts: row.get::<_, String>(0)?,
                year: row.get::<_, i32>(1)?,
                open: sf(row, 2),
                high: sf(row, 3),
                low: sf(row, 4),
                close: sf(row, 5),
                volume: sf(row, 6),
                sma20: sf(row, 7),
                sma50: sf(row, 8),
                sma200: sf(row, 9),
                bb_upper: sf(row, 10),
                bb_lower: sf(row, 11),
                bb_width: sf(row, 12),
                rsi: sf(row, 13),
                macd_line: sf(row, 14),
                macd_signal: sf(row, 15),
                macd_hist: sf(row, 16),
                dmi_plus: sf(row, 17),
                dmi_minus: sf(row, 18),
                adx: sf(row, 19),
                atr: sf(row, 20),
                atr_r: sf(row, 21),
                stoch_k: sf(row, 22),
                stoch_d: sf(row, 23),
                williams_r: sf(row, 24),
                cci: sf(row, 25),
                mfi: sf(row, 26),
                roc_1: sf(row, 27),
                roc_3: sf(row, 28),
                roc_6: sf(row, 29),
                roc_12: sf(row, 30),
                obv_slope_12: sf(row, 31),
                volume_sma_20: sf(row, 32),
                tf_1h_close: sf(row, 33),
                tf_1h_high: sf(row, 34),
                tf_1h_low: sf(row, 35),
                tf_1h_ret: sf(row, 36),
                tf_1h_body: sf(row, 37),
                tf_4h_close: sf(row, 38),
                tf_4h_high: sf(row, 39),
                tf_4h_low: sf(row, 40),
                tf_4h_ret: sf(row, 41),
                tf_4h_body: sf(row, 42),
                bb_pos: sf(row, 43),
                kelt_upper: sf(row, 44),
                kelt_lower: sf(row, 45),
                kelt_pos: sf(row, 46),
                squeeze: row.get::<_, Option<i32>>(47)?.unwrap_or(0) != 0,
                range_pos_12: sf(row, 48),
                range_pos_24: sf(row, 49),
                range_pos_48: sf(row, 50),
                trend_consistency_6: sf(row, 51),
                trend_consistency_12: sf(row, 52),
                trend_consistency_24: sf(row, 53),
                atr_roc_6: sf(row, 54),
                atr_roc_12: sf(row, 55),
                vol_accel: sf(row, 56),
                hour: sf(row, 57),
                day_of_week: sf(row, 58),
                label: row
                    .get::<_, Option<String>>(59)?
                    .unwrap_or_else(|| "Noise".to_string()),
            })
        })
        .expect("query failed")
        .filter_map(|r| r.ok())
        .collect();

    candles
}
