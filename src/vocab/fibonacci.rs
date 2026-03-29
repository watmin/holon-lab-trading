//! vocab/fibonacci — Fibonacci retracement levels
//!
//! Computes proximity to fib levels (0.236, 0.382, 0.500, 0.618, 0.786)
//! using the viewport swing high/low. Pure computation, no encoding.

use crate::candle::Candle;

pub struct FibLevel {
    pub name: &'static str,
    pub touching: bool,
    pub above: bool,
}

pub struct FibonacciFacts {
    pub levels: Vec<FibLevel>,
}

pub fn eval_fibonacci(candles: &[Candle]) -> Option<FibonacciFacts> {
    if candles.len() < 10 { return None; }

    let swing_high = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
    let swing_low = candles.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
    let range = swing_high - swing_low;
    if range < 1e-10 { return None; }

    let close = candles.last().unwrap().close;
    let atr = candles.last().unwrap().atr_r * close;

    let fibs: &[(&str, f64)] = &[
        ("fib-236", 0.236), ("fib-382", 0.382), ("fib-500", 0.500),
        ("fib-618", 0.618), ("fib-786", 0.786),
    ];

    let levels = fibs.iter().map(|&(name, ratio)| {
        let level = swing_low + range * ratio;
        FibLevel {
            name,
            touching: (close - level).abs() < atr * 0.5,
            above: close > level,
        }
    }).collect();

    Some(FibonacciFacts { levels })
}
