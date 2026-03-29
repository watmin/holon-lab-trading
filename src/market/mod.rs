//! Market domain — shared primitives for market-level modules.
//!
//! Time encoding, candle helpers, and re-exports for market::manager, etc.

pub mod manager;

/// Parse hour-of-day from candle timestamp "YYYY-MM-DD HH:MM:SS".
pub fn parse_candle_hour(ts: &str) -> f64 {
    ts.get(11..13).and_then(|s| s.parse().ok()).unwrap_or(12.0)
}

/// Parse day-of-week from candle timestamp (Zeller-like formula). 0=Sunday..6=Saturday.
pub fn parse_candle_day(ts: &str) -> f64 {
    let y: i32 = ts.get(..4).and_then(|s| s.parse().ok()).unwrap_or(2019);
    let m: i32 = ts.get(5..7).and_then(|s| s.parse().ok()).unwrap_or(1);
    let d: i32 = ts.get(8..10).and_then(|s| s.parse().ok()).unwrap_or(1);
    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    let y2 = if m < 3 { y - 1 } else { y };
    ((y2 + y2 / 4 - y2 / 100 + y2 / 400 + t[(m - 1) as usize] + d) % 7) as f64
}
