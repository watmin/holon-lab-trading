use rusqlite::Connection;
use std::path::Path;

#[allow(dead_code)]
pub struct Candle {
    pub ts: String,
    pub year: i32,
    pub close: f64,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub volume: f64,
    pub sma20: f64,
    pub sma50: f64,
    pub sma200: f64,
    pub bb_upper: f64,
    pub bb_lower: f64,
    pub rsi: f64,
    pub macd_line: f64,
    pub macd_signal: f64,
    pub macd_hist: f64,
    pub dmi_plus: f64,
    pub dmi_minus: f64,
    pub adx: f64,
    pub atr_r: f64,
    pub label: String,
}

fn sf(row: &rusqlite::Row, idx: usize) -> f64 {
    row.get::<_, Option<f64>>(idx).unwrap_or(None).unwrap_or(0.0)
}

pub fn load_candles(db_path: &Path, label_col: &str) -> Vec<Candle> {
    let conn = Connection::open(db_path).expect("failed to open database");

    let sql = format!(
        "SELECT ts, year, close, open, high, low, volume, \
         sma20, sma50, sma200, bb_upper, bb_lower, rsi, \
         macd_line, macd_signal, macd_hist, \
         dmi_plus, dmi_minus, adx, atr_r, \
         {label_col} \
         FROM candles ORDER BY ts"
    );

    let mut stmt = conn.prepare(&sql).expect("failed to prepare query");
    let candles = stmt
        .query_map([], |row| {
            Ok(Candle {
                ts: row.get::<_, String>(0)?,
                year: row.get::<_, i32>(1)?,
                close: sf(row, 2),
                open: sf(row, 3),
                high: sf(row, 4),
                low: sf(row, 5),
                volume: sf(row, 6),
                sma20: sf(row, 7),
                sma50: sf(row, 8),
                sma200: sf(row, 9),
                bb_upper: sf(row, 10),
                bb_lower: sf(row, 11),
                rsi: sf(row, 12),
                macd_line: sf(row, 13),
                macd_signal: sf(row, 14),
                macd_hist: sf(row, 15),
                dmi_plus: sf(row, 16),
                dmi_minus: sf(row, 17),
                adx: sf(row, 18),
                atr_r: sf(row, 19),
                label: row
                    .get::<_, Option<String>>(20)?
                    .unwrap_or_else(|| "QUIET".to_string()),
            })
        })
        .expect("query failed")
        .filter_map(|r| r.ok())
        .collect();

    candles
}
