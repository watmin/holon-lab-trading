use rayon::prelude::*;

use crate::db::Candle;
use holon::{Primitives, VectorManager, Vector};

const NUM_PANELS: usize = 4;
const NULL_TOKEN: &str = "null";

/// A viewport is [col][row] = list of color tokens at that pixel.
/// Columns are left-to-right (time), rows are top-to-bottom (all panels stacked).
pub type Viewport = Vec<Vec<Vec<&'static str>>>;

// ─── color token constants ──────────────────────────────────────────────────

const GS: &str = "gs"; // green solid (bull body)
const RS: &str = "rs"; // red solid (bear body)
const GW: &str = "gw"; // green wick
const RW: &str = "rw"; // red wick
const DJ: &str = "dj"; // doji
const YL: &str = "yl"; // SMA20 yellow line
const RL: &str = "rl"; // SMA50 red line
const GL: &str = "gl"; // SMA200 green line
const WU: &str = "wu"; // BB upper
const WL: &str = "wl"; // BB lower
const VG: &str = "vg"; // volume green
const VR: &str = "vr"; // volume red
const RB: &str = "rb"; // RSI line
const RO: &str = "ro"; // RSI overbought
const RN: &str = "rn"; // RSI oversold
const ML: &str = "ml"; // MACD line
const MS: &str = "ms"; // MACD signal
const MHG: &str = "mhg"; // MACD hist green
const MHR: &str = "mhr"; // MACD hist red
const DP: &str = "dp"; // DMI+ green
const DM: &str = "dm"; // DMI- red
const AX: &str = "ax"; // ADX yellow

// ─── pixel helpers ──────────────────────────────────────────────────────────

fn px_row(val_01: f64, n_rows: usize) -> Option<usize> {
    if val_01 < 0.0 || val_01 > 1.0 {
        return None;
    }
    let r = (val_01 * (n_rows as f64 - 1.0) + 0.5) as usize;
    Some(r.min(n_rows - 1))
}

fn px_add(panel: &mut Vec<Vec<Vec<&'static str>>>, col: usize, row: usize, color: &'static str, n_rows: usize) {
    if row >= n_rows {
        return;
    }
    let cell = &mut panel[col][row];
    if !cell.contains(&color) {
        cell.push(color);
    }
}

// ─── render ─────────────────────────────────────────────────────────────────

/// Render a 4-panel chart viewport as pixel grids.
///
/// Returns 4 panels (price_vol, rsi, macd, dmi), each as [col][row] = colors.
/// The caller should stack them vertically via `build_viewport`.
pub fn render_viewport(
    candles: &[Candle],
    idx: usize,
    window: usize,
    n_rows: usize,
) -> [Vec<Vec<Vec<&'static str>>>; NUM_PANELS] {
    let start = idx.saturating_sub(window - 1);
    let raw_window = &candles[start..=idx];
    let pad_count = window.saturating_sub(raw_window.len());

    let get = |i: usize| -> &Candle {
        if i < pad_count {
            &raw_window[0]
        } else {
            &raw_window[i - pad_count]
        }
    };

    let n = window;

    // Collect series
    let closes: Vec<f64> = (0..n).map(|i| get(i).close).collect();
    let opens: Vec<f64> = (0..n).map(|i| get(i).open).collect();
    let highs: Vec<f64> = (0..n).map(|i| get(i).high).collect();
    let lows: Vec<f64> = (0..n).map(|i| get(i).low).collect();
    let sma20s: Vec<f64> = (0..n).map(|i| get(i).sma20).collect();
    let sma50s: Vec<f64> = (0..n).map(|i| get(i).sma50).collect();
    let sma200s: Vec<f64> = (0..n).map(|i| get(i).sma200).collect();
    let bb_ups: Vec<f64> = (0..n).map(|i| get(i).bb_upper).collect();
    let bb_los: Vec<f64> = (0..n).map(|i| get(i).bb_lower).collect();
    let volumes: Vec<f64> = (0..n).map(|i| get(i).volume).collect();
    let rsis: Vec<f64> = (0..n).map(|i| get(i).rsi).collect();
    let macd_lines: Vec<f64> = (0..n).map(|i| get(i).macd_line).collect();
    let macd_sigs: Vec<f64> = (0..n).map(|i| get(i).macd_signal).collect();
    let macd_hists: Vec<f64> = (0..n).map(|i| get(i).macd_hist).collect();
    let dmi_ps: Vec<f64> = (0..n).map(|i| get(i).dmi_plus).collect();
    let dmi_ms: Vec<f64> = (0..n).map(|i| get(i).dmi_minus).collect();
    let adx_vals: Vec<f64> = (0..n).map(|i| get(i).adx).collect();

    // Price viewport scaling
    let mut vp_vals = Vec::new();
    for series in [&closes, &opens, &highs, &lows, &sma20s, &sma50s, &sma200s] {
        vp_vals.extend(series.iter().copied().filter(|&v| v > 0.0));
    }
    if vp_vals.is_empty() {
        vp_vals.push(1.0);
    }
    let vp_lo_raw = vp_vals.iter().cloned().fold(f64::INFINITY, f64::min);
    let vp_hi_raw = vp_vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let margin = (vp_hi_raw - vp_lo_raw) * 0.05;
    let vp_lo = vp_lo_raw - margin;
    let vp_hi = vp_hi_raw + margin;
    let vp_range = if (vp_hi - vp_lo) > 1e-10 { vp_hi - vp_lo } else { 1.0 };

    let pn = |v: f64| -> f64 {
        if v <= 0.0 { -1.0 } else { (v - vp_lo) / vp_range }
    };

    // Volume scaling (bottom 30%)
    let vol_max = volumes.iter().cloned().fold(0.0_f64, f64::max).max(1.0);
    let vol_ceiling = (n_rows as f64 * 0.3) as usize;

    // MACD scaling
    let macd_all: Vec<f64> = macd_lines.iter().chain(macd_sigs.iter()).chain(macd_hists.iter()).copied().collect();
    let m_lo = macd_all.iter().cloned().fold(f64::INFINITY, f64::min);
    let m_hi = macd_all.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let m_range = if (m_hi - m_lo) > 1e-10 { m_hi - m_lo } else { 1.0 };

    // Allocate panels: [col][row] = Vec of color tokens
    let mk_panel = || -> Vec<Vec<Vec<&'static str>>> {
        (0..n).map(|_| (0..n_rows).map(|_| Vec::new()).collect()).collect()
    };
    let mut pv = mk_panel();
    let mut rsi_p = mk_panel();
    let mut macd_p = mk_panel();
    let mut dmi_p = mk_panel();

    for t in 0..n {
        let cl = closes[t];
        let op = opens[t];
        let hi = highs[t];
        let lo = lows[t];
        let is_bull = cl >= op;
        let body_color: &str = if is_bull { GS } else { RS };
        let wick_color: &str = if is_bull { GW } else { RW };

        // Volume bars (bottom of price panel)
        let vol_h = (volumes[t] / vol_max * vol_ceiling as f64 + 0.5) as usize;
        let vol_color: &str = if is_bull { VG } else { VR };
        for r in 0..=vol_h.min(vol_ceiling) {
            px_add(&mut pv, t, r, vol_color, n_rows);
        }

        // Candle body
        if let (Some(r_open), Some(r_close)) = (px_row(pn(op), n_rows), px_row(pn(cl), n_rows)) {
            let r_lo_body = r_open.min(r_close);
            let r_hi_body = r_open.max(r_close);
            if r_lo_body == r_hi_body {
                px_add(&mut pv, t, r_lo_body, DJ, n_rows);
            } else {
                for r in r_lo_body..=r_hi_body {
                    px_add(&mut pv, t, r, body_color, n_rows);
                }
            }

            // Wicks
            if let Some(r_high) = px_row(pn(hi), n_rows) {
                for r in (r_hi_body + 1)..=r_high {
                    px_add(&mut pv, t, r, wick_color, n_rows);
                }
            }
            if let Some(r_low) = px_row(pn(lo), n_rows) {
                for r in r_low..r_lo_body {
                    px_add(&mut pv, t, r, wick_color, n_rows);
                }
            }
        }

        // SMA / BB overlays
        if sma20s[t] > 0.0 {
            if let Some(r) = px_row(pn(sma20s[t]), n_rows) { px_add(&mut pv, t, r, YL, n_rows); }
        }
        if sma50s[t] > 0.0 {
            if let Some(r) = px_row(pn(sma50s[t]), n_rows) { px_add(&mut pv, t, r, RL, n_rows); }
        }
        if sma200s[t] > 0.0 {
            if let Some(r) = px_row(pn(sma200s[t]), n_rows) { px_add(&mut pv, t, r, GL, n_rows); }
        }
        if bb_ups[t] > 0.0 {
            if let Some(r) = px_row(pn(bb_ups[t]), n_rows) { px_add(&mut pv, t, r, WU, n_rows); }
        }
        if bb_los[t] > 0.0 {
            if let Some(r) = px_row(pn(bb_los[t]), n_rows) { px_add(&mut pv, t, r, WL, n_rows); }
        }

        // RSI panel
        let rsi_val = rsis[t];
        if rsi_val > 0.0 {
            if let Some(r) = px_row(rsi_val / 100.0, n_rows) {
                px_add(&mut rsi_p, t, r, RB, n_rows);
                if rsi_val > 70.0 {
                    px_add(&mut rsi_p, t, r, RO, n_rows);
                } else if rsi_val < 30.0 {
                    px_add(&mut rsi_p, t, r, RN, n_rows);
                }
            }
        }

        // MACD panel
        let ml_norm = (macd_lines[t] - m_lo) / m_range;
        let ms_norm = (macd_sigs[t] - m_lo) / m_range;
        let mh_norm = (macd_hists[t] - m_lo) / m_range;
        let center = if m_range > 1e-10 {
            px_row((-m_lo) / m_range, n_rows)
        } else {
            Some(n_rows / 2)
        };

        if let Some(r) = px_row(ml_norm, n_rows) { px_add(&mut macd_p, t, r, ML, n_rows); }
        if let Some(r) = px_row(ms_norm, n_rows) { px_add(&mut macd_p, t, r, MS, n_rows); }

        if let (Some(r_hist), Some(c)) = (px_row(mh_norm, n_rows), center) {
            let hist_color: &str = if macd_hists[t] >= 0.0 { MHG } else { MHR };
            let lo_h = c.min(r_hist);
            let hi_h = c.max(r_hist);
            for r in lo_h..=hi_h {
                px_add(&mut macd_p, t, r, hist_color, n_rows);
            }
        }

        // DMI panel (0-100)
        if dmi_ps[t] > 0.0 {
            if let Some(r) = px_row(dmi_ps[t] / 100.0, n_rows) { px_add(&mut dmi_p, t, r, DP, n_rows); }
        }
        if dmi_ms[t] > 0.0 {
            if let Some(r) = px_row(dmi_ms[t] / 100.0, n_rows) { px_add(&mut dmi_p, t, r, DM, n_rows); }
        }
        if adx_vals[t] > 0.0 {
            if let Some(r) = px_row(adx_vals[t] / 100.0, n_rows) { px_add(&mut dmi_p, t, r, AX, n_rows); }
        }
    }

    [pv, rsi_p, macd_p, dmi_p]
}

// ─── viewport builder ───────────────────────────────────────────────────────

/// Stack the 4 panel grids into a single viewport: [col][row] across all panels.
/// Rows go: price_vol(0..n_rows), rsi(n_rows..2*n_rows), macd, dmi.
/// Empty cells get [NULL_TOKEN].
pub fn build_viewport(
    panels: &[Vec<Vec<Vec<&'static str>>>; NUM_PANELS],
    n_cols: usize,
    n_rows: usize,
) -> Viewport {
    let total_rows = n_rows * NUM_PANELS;
    let mut viewport = Vec::with_capacity(n_cols);

    for c in 0..n_cols {
        let mut column = Vec::with_capacity(total_rows);
        for (pi, panel) in panels.iter().enumerate() {
            let _ = pi;
            for r in 0..n_rows {
                let cell = &panel[c][r];
                if cell.is_empty() {
                    column.push(vec![NULL_TOKEN]);
                } else {
                    column.push(cell.clone());
                }
            }
        }
        viewport.push(column);
    }

    viewport
}

/// Build an all-null viewport of the same shape (for null template removal).
pub fn build_null_template(n_cols: usize, n_rows: usize) -> Viewport {
    let total_rows = n_rows * NUM_PANELS;
    (0..n_cols)
        .map(|_| (0..total_rows).map(|_| vec![NULL_TOKEN]).collect())
        .collect()
}

// ─── encoding ───────────────────────────────────────────────────────────────

/// Encode a viewport to a Holon vector using positional binding.
///
/// Matches Python: encode_list(viewport, mode="positional") with _encode_set
/// for each cell (bundle color atoms + bind with set_indicator).
pub fn raster_encode(vm: &VectorManager, vp: &Viewport, null_vec: &Vector) -> Vector {
    let set_indicator = vm.get_vector("set_indicator");

    let col_vecs: Vec<Vector> = vp
        .par_iter()
        .enumerate()
        .map(|(ci, column)| {
            let row_vecs: Vec<Vector> = column
                .iter()
                .enumerate()
                .map(|(ri, cell)| {
                    let atoms: Vec<Vector> = cell.iter().map(|&c| vm.get_vector(c)).collect();
                    let atom_refs: Vec<&Vector> = atoms.iter().collect();
                    let bundled = Primitives::bundle(&atom_refs);
                    let cell_vec = Primitives::bind(&set_indicator, &bundled);
                    let pos = vm.get_position_vector(ri as i64);
                    Primitives::bind(&pos, &cell_vec)
                })
                .collect();

            let row_refs: Vec<&Vector> = row_vecs.iter().collect();
            let col_vec = Primitives::bundle(&row_refs);
            let pos = vm.get_position_vector(ci as i64);
            Primitives::bind(&pos, &col_vec)
        })
        .collect();

    let col_refs: Vec<&Vector> = col_vecs.iter().collect();
    let raw = Primitives::bundle(&col_refs);
    Primitives::difference(null_vec, &raw)
}
