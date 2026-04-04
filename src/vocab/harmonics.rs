//! vocab/harmonics — harmonic price patterns (Gartley, Bat, Butterfly, Crab)
//!
//! Detects XABCD patterns from swing points in the candle window.
//! Each pattern is defined by Fibonacci ratio constraints between legs.

use crate::candle::Candle;
use super::Fact;

// ── Swing detection ─────────────────────────────────────────────────────────

/// A swing point: index into the candle window, price, and type.
#[derive(Clone, Copy, Debug)]
struct Swing {
    idx: usize,
    price: f64,
    is_high: bool,
}

/// Find local swing highs: price[i] is strictly greater than all prices
/// within `radius` bars on each side.
fn swing_highs(prices: &[f64], radius: usize) -> Vec<(usize, f64)> {
    let n = prices.len();
    let mut out = Vec::new();
    if n < radius * 2 + 1 { return out; }
    for i in radius..n - radius {
        let v = prices[i];
        if prices[i.saturating_sub(radius)..i].iter().all(|&x| x < v)
            && prices[i + 1..=(i + radius).min(n - 1)].iter().all(|&x| x < v)
        {
            out.push((i, v));
        }
    }
    out
}

/// Find local swing lows: price[i] is strictly less than all prices
/// within `radius` bars on each side.
fn swing_lows(prices: &[f64], radius: usize) -> Vec<(usize, f64)> {
    let n = prices.len();
    let mut out = Vec::new();
    if n < radius * 2 + 1 { return out; }
    for i in radius..n - radius {
        let v = prices[i];
        if prices[i.saturating_sub(radius)..i].iter().all(|&x| x > v)
            && prices[i + 1..=(i + radius).min(n - 1)].iter().all(|&x| x > v)
        {
            out.push((i, v));
        }
    }
    out
}

/// Merge highs and lows into an alternating zigzag sequence.
/// Consecutive same-type swings are resolved by keeping the most extreme.
fn zigzag(highs: &[(usize, f64)], lows: &[(usize, f64)]) -> Vec<Swing> {
    let mut all: Vec<Swing> = Vec::with_capacity(highs.len() + lows.len());
    for &(idx, price) in highs {
        all.push(Swing { idx, price, is_high: true });
    }
    for &(idx, price) in lows {
        all.push(Swing { idx, price, is_high: false });
    }
    all.sort_by_key(|s| s.idx);

    // Enforce alternation: when two consecutive same-type swings occur,
    // keep the more extreme one.
    let mut result: Vec<Swing> = Vec::new();
    for s in all {
        if let Some(last) = result.last_mut() {
            if last.is_high == s.is_high {
                // Same type — keep the more extreme
                if s.is_high && s.price > last.price {
                    *last = s;
                } else if !s.is_high && s.price < last.price {
                    *last = s;
                }
                continue;
            }
        }
        result.push(s);
    }
    result
}

// ── Harmonic templates ──────────────────────────────────────────────────────

/// Harmonic pattern template.
/// Ratios sourced from NAGA Academy + cross-verified with StockCharts ChartSchool.
/// https://naga.com/en/academy/harmonic-patterns-gartley-butterfly-bat-crab
///
/// AB/XA: how far B retraces XA
/// BC/AB: how far C retraces AB
/// CD/AB: how far CD extends relative to AB (NOT BC)
/// D/XA:  where D completes relative to XA (retrace < 1.0, extension > 1.0)
struct HarmonicTemplate {
    name: &'static str,
    ab_xa: (f64, f64),
    bc_ab: (f64, f64),
    cd_ab: (f64, f64),  // CD as extension of AB
    d_xa:  (f64, f64),  // D point: retrace or extension of XA
}

/// Sources:
/// - NAGA Academy: https://naga.com/en/academy/harmonic-patterns-gartley-butterfly-bat-crab
/// - IG International (downloaded HTML)
/// - Pro Trading School (downloaded HTML)
/// - AvaTrade (downloaded HTML)
/// Cross-verified across sources. Disagreements noted in comments.
const TEMPLATES: &[HarmonicTemplate] = &[
    // Gartley (H.M. Gartley, 1935): D retraces XA, stays inside X-A range
    HarmonicTemplate {
        name: "gartley",
        ab_xa: (0.580, 0.658),  // ~0.618 (all sources agree)
        bc_ab: (0.382, 0.886),  // all sources agree
        cd_ab: (1.130, 1.618),  // NAGA: 1.13-1.618 of AB
        d_xa:  (0.746, 0.826),  // ~0.786 retrace (all sources agree)
    },
    // Bat (Scott Carney, 2001): D retraces XA deeper
    HarmonicTemplate {
        name: "bat",
        ab_xa: (0.382, 0.500),  // NAGA/AvaTrade: 0.382-0.50; IG: up to 0.50
        bc_ab: (0.382, 0.886),  // all sources agree
        cd_ab: (1.618, 2.618),  // IG: 1.618-2.618 of BC; NAGA: same range of AB
        d_xa:  (0.846, 0.926),  // ~0.886 retrace (all sources agree)
    },
    // Butterfly (Bryce Gilmore): D extends beyond X
    HarmonicTemplate {
        name: "butterfly",
        ab_xa: (0.746, 0.826),  // ~0.786 (all sources agree)
        bc_ab: (0.382, 0.886),  // all sources agree
        cd_ab: (1.618, 2.240),  // AvaTrade: 1.618-2.24 of AB; ProTrading: 1.618-2.618 of BC
        d_xa:  (1.230, 1.658),  // ProTrading: 1.27-1.618 extension; IG: ~1.27
    },
    // Crab (Scott Carney, 2000): D extends far beyond X, extreme extension
    HarmonicTemplate {
        name: "crab",
        ab_xa: (0.382, 0.618),  // all sources agree
        bc_ab: (0.382, 0.886),  // all sources agree
        cd_ab: (2.618, 3.618),  // AvaTrade/ProTrading: 2.618-3.618 of BC
        d_xa:  (1.578, 1.658),  // ~1.618 extension (all sources agree)
    },
    // Deep Crab (IG International only): variation with deeper B retracement
    HarmonicTemplate {
        name: "deep-crab",
        ab_xa: (0.846, 0.926),  // ~0.886 (deeper than standard crab)
        bc_ab: (0.382, 0.886),
        cd_ab: (2.240, 3.618),  // IG: 2.24-3.618
        d_xa:  (1.578, 1.658),  // ~1.618 extension (same as crab)
    },
    // Cypher (AvaTrade): unique — C extends beyond A
    // AB/XA and D/XA are standard, but C extends 1.272-1.414 of XA
    // We approximate: CD/AB captures the extension, D retraces to 0.786 of XC
    HarmonicTemplate {
        name: "cypher",
        ab_xa: (0.382, 0.618),  // AvaTrade: 0.382-0.618
        bc_ab: (1.130, 1.414),  // C extends beyond A: BC/AB > 1.0
        cd_ab: (1.272, 2.000),  // CD returns toward X
        d_xa:  (0.746, 0.826),  // D does not extend beyond 0.786 of XA
    },
];

fn in_range(value: f64, range: (f64, f64)) -> bool {
    value >= range.0 && value <= range.1
}

/// How well does a ratio match a range? 1.0 = center, 0.0 = edge.
fn match_quality(value: f64, range: (f64, f64)) -> f64 {
    let center = (range.0 + range.1) / 2.0;
    let half_width = (range.1 - range.0) / 2.0;
    if half_width < 1e-10 { return 0.0; }
    1.0 - ((value - center).abs() / half_width).min(1.0)
}

// ── Pattern detection ───────────────────────────────────────────────────────

/// Try to match an XABCD pattern from 4 swing points + current close as D.
/// Returns (template_name, direction, quality) if a match is found.
// rune:forge(bare-type) — x, a, b, c, d are XABCD domain convention (Scott Carney).
fn match_pattern(
    x: f64, a: f64, b: f64, c: f64, d: f64,
    x_is_low: bool,
) -> Vec<(&'static str, bool, f64)> {
    let xa = (a - x).abs();
    if xa < 1e-10 { return vec![]; }
    let ab = (b - a).abs();
    let bc = (c - b).abs();
    let cd = (d - c).abs();

    if ab < 1e-10 || bc < 1e-10 { return vec![]; }

    let ab_xa = ab / xa;
    let bc_ab = bc / ab;
    let cd_ab = cd / ab;  // CD as extension of AB (not BC)

    // D/XA: where D sits relative to XA.
    // For retracement patterns (Gartley, Bat): D is between X and A, ratio < 1.0
    // For extension patterns (Butterfly, Crab): D is beyond X, ratio > 1.0
    // Measured as distance from A to D relative to XA.
    let d_xa = (a - d).abs() / xa;

    let mut matches = Vec::new();
    for t in TEMPLATES {
        if in_range(ab_xa, t.ab_xa)
            && in_range(bc_ab, t.bc_ab)
            && in_range(cd_ab, t.cd_ab)
            && in_range(d_xa, t.d_xa)
        {
            let q = (match_quality(ab_xa, t.ab_xa)
                + match_quality(bc_ab, t.bc_ab)
                + match_quality(cd_ab, t.cd_ab)
                + match_quality(d_xa, t.d_xa)) / 4.0;

            // Bullish if X is a low (D completes near a low = buy zone)
            // Bearish if X is a high (D completes near a high = sell zone)
            matches.push((t.name, x_is_low, q));
        }
    }
    matches
}

// ── Public API ──────────────────────────────────────────────────────────────

pub fn eval_harmonics(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    if candles.len() < 30 { return facts; }

    let highs: Vec<f64> = candles.iter().map(|c| c.high).collect();
    let lows: Vec<f64> = candles.iter().map(|c| c.low).collect();

    // Use radius 5 — each swing must dominate 10 bars (50 min at 5m candles)
    let sh = swing_highs(&highs, 5);
    let sl = swing_lows(&lows, 5);

    let zz = zigzag(&sh, &sl);
    if zz.len() < 4 { return facts; }

    let close = candles.last().unwrap().close;

    // Try the last 4 swing points as X, A, B, C with close as D.
    // Check the most recent pattern windows (up to RECENT_WINDOWS).
    const RECENT_WINDOWS: usize = 3;
    let n = zz.len();
    for start in (0..n.saturating_sub(3)).rev().take(RECENT_WINDOWS) {
        if start + 3 >= n { continue; }
        let x = &zz[start];
        let a = &zz[start + 1];
        let b = &zz[start + 2];
        let c = &zz[start + 3];

        // Validate alternation: X-A-B-C should alternate high/low
        if x.is_high == a.is_high || a.is_high == b.is_high || b.is_high == c.is_high {
            continue;
        }

        let matches = match_pattern(x.price, a.price, b.price, c.price, close, !x.is_high);

        for (name, bullish, quality) in matches {
            let zone: &'static str = match (name, bullish) {
                ("gartley", true) => "gartley-bullish",
                ("gartley", false) => "gartley-bearish",
                ("bat", true) => "bat-bullish",
                ("bat", false) => "bat-bearish",
                ("butterfly", true) => "butterfly-bullish",
                ("butterfly", false) => "butterfly-bearish",
                ("crab", true) => "crab-bullish",
                ("crab", false) => "crab-bearish",
                ("deep-crab", true) => "deep-crab-bullish",
                ("deep-crab", false) => "deep-crab-bearish",
                ("cypher", true) => "cypher-bullish",
                ("cypher", false) => "cypher-bearish",
                _ => continue,
            };

            facts.push(Fact::Zone { indicator: "harmonic", zone });
            facts.push(Fact::Scalar {
                indicator: "harmonic-quality",
                value: quality.clamp(0.0, 1.0),
                scale: 1.0,
            });

            // Only report the best match per window
            break;
        }
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swing_highs_finds_peaks() {
        let prices = vec![1.0, 2.0, 5.0, 2.0, 1.0, 3.0, 6.0, 3.0, 1.0];
        let highs = swing_highs(&prices, 2);
        assert_eq!(highs.len(), 2);
        assert_eq!(highs[0], (2, 5.0));
        assert_eq!(highs[1], (6, 6.0));
    }

    #[test]
    fn swing_lows_finds_troughs() {
        let prices = vec![5.0, 3.0, 1.0, 3.0, 5.0, 3.0, 0.5, 3.0, 5.0];
        let lows = swing_lows(&prices, 2);
        assert_eq!(lows.len(), 2);
        assert_eq!(lows[0], (2, 1.0));
        assert_eq!(lows[1], (6, 0.5));
    }

    #[test]
    fn zigzag_alternates() {
        let highs = vec![(2, 10.0), (6, 12.0)];
        let lows = vec![(0, 5.0), (4, 3.0), (8, 4.0)];
        let zz = zigzag(&highs, &lows);
        // Should alternate: low, high, low, high, low
        for w in zz.windows(2) {
            assert_ne!(w[0].is_high, w[1].is_high, "zigzag must alternate");
        }
    }

    #[test]
    fn zigzag_resolves_consecutive_same_type() {
        // Two consecutive highs — should keep the higher one
        let highs = vec![(2, 10.0), (4, 12.0)];
        let lows = vec![(0, 5.0), (6, 3.0)];
        let zz = zigzag(&highs, &lows);
        let high_swings: Vec<_> = zz.iter().filter(|s| s.is_high).collect();
        assert_eq!(high_swings.len(), 1);
        assert_eq!(high_swings[0].price, 12.0);
    }

    #[test]
    fn match_pattern_gartley_bullish() {
        // Ideal Gartley (from NAGA reference):
        //   AB/XA = 0.618, BC/AB = 0.618, CD/AB = 1.272, D/XA = 0.786
        let x = 100.0;  // low
        let a = 200.0;  // high — XA = 100
        let b = 138.2;  // low  — AB = 61.8, AB/XA = 0.618 ✓
        let c = 176.4;  // high — BC = 38.2, BC/AB = 0.618 ✓
        // D: CD/AB = 1.272 → CD = 1.272 * 61.8 = 78.6 → D = 176.4 - 78.6 = 97.8
        // But D/XA = (200 - 97.8) / 100 = 1.022 — that's extension, not retrace.
        // For retrace: D/XA = 0.786 → D = 200 - 0.786*100 = 121.4
        // Then CD = 176.4 - 121.4 = 55.0, CD/AB = 55.0/61.8 = 0.890 — too low.
        //
        // The ratios constrain each other. Pick values that satisfy all four:
        // AB/XA=0.618, BC/AB=0.5, CD/AB=1.27, D/XA=0.786
        // AB=61.8, BC=30.9, C=138.2+30.9=169.1, CD=1.27*61.8=78.5
        // D=169.1-78.5=90.6, D/XA=(200-90.6)/100=1.094 — still extension.
        //
        // Actually D/XA in retrace convention: distance from X to D / XA.
        // If D=121.4: (121.4-100)/100 = 0.214... that's XD/XA.
        // (A-D)/XA = (200-121.4)/100 = 0.786. This is what we compute.
        // CD = 176.4-121.4 = 55. CD/AB = 55/61.8 = 0.89 — out of range [1.13,1.618].
        //
        // The tension: D/XA=0.786 and CD/AB=1.13-1.618 constrain C's position.
        // Need: D = 200 - 0.786*100 = 121.4, so CD = C - 121.4.
        // CD/AB ∈ [1.13, 1.618] → CD ∈ [69.8, 100.0] → C ∈ [191.2, 221.4]
        // But C = B + BC, B = 138.2, BC/AB ∈ [0.382, 0.886] → BC ∈ [23.6, 54.8]
        // So C ∈ [161.8, 193.0]. Overlap: [191.2, 193.0]. Tight but possible.
        // Pick C = 192.0: BC = 53.8, BC/AB = 0.870 (in range).
        // CD = 192.0 - 121.4 = 70.6, CD/AB = 70.6/61.8 = 1.142 (in range).
        let x = 100.0;
        let a = 200.0;  // XA = 100
        let b = 138.2;  // AB = 61.8, AB/XA = 0.618
        let c = 192.0;  // BC = 53.8, BC/AB = 0.870
        let d = 121.4;  // CD = 70.6, CD/AB = 1.142, D/XA = (200-121.4)/100 = 0.786
        let matches = match_pattern(x, a, b, c, d, true);
        assert!(!matches.is_empty(), "should detect gartley-bullish, ratios: AB/XA={:.3} BC/AB={:.3} CD/AB={:.3} D/XA={:.3}",
            61.8/100.0, 53.8/61.8, 70.6/61.8, (200.0-121.4)/100.0);
        assert_eq!(matches[0].0, "gartley");
        assert!(matches[0].1, "should be bullish");
    }

    #[test]
    fn no_match_on_random_ratios() {
        let matches = match_pattern(100.0, 150.0, 140.0, 145.0, 130.0, true);
        assert!(matches.is_empty(), "random ratios should not match any template");
    }

    #[test]
    fn eval_harmonics_returns_empty_on_short_window() {
        let facts = eval_harmonics(&[]);
        assert!(facts.is_empty());
    }

    /// Build candles with a specific price path. Each price becomes close/high/low
    /// with small wicks so swing detection works cleanly.
    fn make_price_candles(prices: &[f64]) -> Vec<Candle> {
        prices.iter().map(|&p| {
            Candle {
                ts: String::new(), open: p, high: p + 0.5, low: p - 0.5,
                close: p, volume: 100.0,
                sma20: 0.0, sma50: 0.0, sma200: 0.0,
                bb_upper: 0.0, bb_lower: 0.0, bb_width: 0.0, bb_pos: 0.0,
                rsi: 50.0, macd_line: 0.0, macd_signal: 0.0, macd_hist: 0.0,
                dmi_plus: 0.0, dmi_minus: 0.0, adx: 0.0,
                atr: 1.0, atr_r: 0.01,
                stoch_k: 50.0, stoch_d: 50.0, williams_r: -50.0,
                cci: 0.0, mfi: 50.0,
                roc_1: 0.0, roc_3: 0.0, roc_6: 0.0, roc_12: 0.0,
                obv_slope_12: 0.0, volume_sma_20: 0.0,
                tf_1h_close: 0.0, tf_1h_high: 0.0, tf_1h_low: 0.0,
                tf_1h_ret: 0.0, tf_1h_body: 0.0,
                tf_4h_close: 0.0, tf_4h_high: 0.0, tf_4h_low: 0.0,
                tf_4h_ret: 0.0, tf_4h_body: 0.0,
                tenkan_sen: 0.0, kijun_sen: 0.0, senkou_span_a: 0.0,
                senkou_span_b: 0.0, cloud_top: 0.0, cloud_bottom: 0.0,
                kelt_upper: 0.0, kelt_lower: 0.0, kelt_pos: 0.0,
                squeeze: false,
                range_pos_12: 0.0, range_pos_24: 0.0, range_pos_48: 0.0,
                trend_consistency_6: 0.0, trend_consistency_12: 0.0,
                trend_consistency_24: 0.0,
                atr_roc_6: 0.0, atr_roc_12: 0.0, vol_accel: 0.0,
                hour: 0.0, day_of_week: 0.0,
            }
        }).collect()
    }

    #[test]
    fn eval_harmonics_detects_gartley_from_candles() {
        // Build a bullish Gartley: X=low, A=high, B=low, C=high, D(close)=low
        // Verified ratios: AB/XA=0.618, BC/AB=0.870, CD/AB=1.142, D/XA=0.786
        //
        // X=100 at candle ~6, A=200 at candle ~18, B=138.2 at candle ~30,
        // C=192 at candle ~42, close=121.4 (prospective D)
        //
        // Between swing points: smooth ramp so radius=5 swing detection finds them.
        let mut prices = Vec::new();

        // Ramp up to X=100 (low point) — 6 candles descending to trough
        for i in 0..6 { prices.push(120.0 - (i as f64) * 4.0); } // 120→100

        // X=100 → A=200 — 12 candles rising
        for i in 0..12 { prices.push(100.0 + (i as f64 + 1.0) * (100.0 / 12.0)); }

        // A=200 → B=138.2 — 12 candles falling
        for i in 0..12 { prices.push(200.0 - (i as f64 + 1.0) * (61.8 / 12.0)); }

        // B=138.2 → C=192 — 12 candles rising
        for i in 0..12 { prices.push(138.2 + (i as f64 + 1.0) * (53.8 / 12.0)); }

        // C=192 → D=121.4 — 8 candles falling, close at 121.4
        for i in 0..8 { prices.push(192.0 - (i as f64 + 1.0) * (70.6 / 8.0)); }

        let candles = make_price_candles(&prices);
        assert!(candles.len() >= 30, "need at least 30 candles, got {}", candles.len());

        let facts = eval_harmonics(&candles);

        let has_gartley = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "harmonic", zone: "gartley-bullish" }
        ));
        let has_quality = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "harmonic-quality", .. }
        ));

        // Debug: print what we got
        if !has_gartley {
            // Print swing points for diagnosis
            let highs: Vec<f64> = candles.iter().map(|c| c.high).collect();
            let lows: Vec<f64> = candles.iter().map(|c| c.low).collect();
            let sh = swing_highs(&highs, 5);
            let sl = swing_lows(&lows, 5);
            let zz = zigzag(&sh, &sl);
            eprintln!("swing highs: {:?}", sh);
            eprintln!("swing lows: {:?}", sl);
            eprintln!("zigzag ({} points): {:?}", zz.len(), zz);
            eprintln!("facts: {:?}", facts);
        }

        assert!(has_gartley, "should detect gartley-bullish from XABCD candle pattern");
        assert!(has_quality, "should emit harmonic-quality scalar");
    }
}
