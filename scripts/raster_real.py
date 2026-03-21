#!/usr/bin/env python
"""raster_real.py — Raster viewport encoding on real BTC data.

Uses Holon's Encoder.encode_list with nested list[list[frozenset]] structure.
No manual bind/bundle — all VSA math is delegated to Holon's SDK.

Viewport layout (4 panels, top to bottom in each column):
  price_vol: OHLC candles + SMAs + BBs + volume bars (bottom ~30%)
  rsi:       RSI line with overbought/oversold zones
  macd:      MACD line, signal, histogram
  dmi:       DMI+, DMI-, ADX lines

Each column = one time period (left to right).
Each row = pixel position (top to bottom within each panel).
Each cell = frozenset of color tokens (or {"null"} for empty space).
"""

from __future__ import annotations

import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))
from holon import DeterministicVectorManager
from holon.kernel.encoder import Encoder
from holon.kernel.primitives import (
    cosine_similarity, prototype, threshold_bipolar, difference,
    resonance, negate, grover_amplify,
)
from holon.kernel.accumulator import create_accumulator, accumulate, accumulate_weighted
from holon.memory.subspace import OnlineSubspace

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import ALL_DB_COLS, sf

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

PANELS = ("price_vol", "rsi", "macd", "dmi")
NULL_COLOR = frozenset({"null"})


# ---------------------------------------------------------------------------
# Pixel renderer
# ---------------------------------------------------------------------------

def _px_row(val_01: float, n_rows: int) -> int:
    if val_01 < 0.0 or val_01 > 1.0:
        return -1
    return max(0, min(n_rows - 1, int(val_01 * (n_rows - 1) + 0.5)))


def _px_add(panel: dict, col_key: str, row: int, color: str, n_rows: int):
    if row < 0 or row >= n_rows:
        return
    rk = f"r{row}"
    col = panel.setdefault(col_key, {})
    if rk in col:
        if isinstance(col[rk], set):
            col[rk].add(color)
        else:
            col[rk] = {col[rk], color}
    else:
        col[rk] = {color}


def render_viewport(candles: list, idx: int, window_size: int,
                    n_rows: int) -> dict[str, dict]:
    """Render a 4-panel chart as colored pixels.

    Panels: price_vol, rsi, macd, dmi.
    Volume bars occupy the bottom ~30% of the price_vol panel.
    """
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)
    n = len(window)

    closes = [sf(c.get("close")) for c in window]
    opens = [sf(c.get("open")) for c in window]
    highs = [sf(c.get("high")) for c in window]
    lows = [sf(c.get("low")) for c in window]
    sma20s = [sf(c.get("sma20")) for c in window]
    sma50s = [sf(c.get("sma50")) for c in window]
    sma200s = [sf(c.get("sma200")) for c in window]
    bb_ups = [sf(c.get("bb_upper")) for c in window]
    bb_los = [sf(c.get("bb_lower")) for c in window]
    volumes = [sf(c.get("volume")) for c in window]
    rsis = [sf(c.get("rsi")) for c in window]
    macd_lines = [sf(c.get("macd_line")) for c in window]
    macd_sigs = [sf(c.get("macd_signal")) for c in window]
    macd_hists = [sf(c.get("macd_hist")) for c in window]
    dmi_plus = [sf(c.get("dmi_plus")) for c in window]
    dmi_minus = [sf(c.get("dmi_minus")) for c in window]
    adx_vals = [sf(c.get("adx")) for c in window]

    # --- Price viewport: OHLC + SMAs (BB can go off-screen) ---
    vp_vals = []
    for vs in (closes, opens, highs, lows, sma20s, sma50s, sma200s):
        vp_vals.extend(v for v in vs if v > 0)
    if not vp_vals:
        vp_vals = [1.0]
    vp_lo, vp_hi = min(vp_vals), max(vp_vals)
    vp_range = vp_hi - vp_lo
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo if (vp_hi - vp_lo) > 1e-10 else 1.0

    def pn(v):
        if v <= 0:
            return -1
        return (v - vp_lo) / vp_range

    # --- Volume scaling (bottom 30% of price panel) ---
    vol_max = max(volumes) if volumes else 1.0
    vol_max = vol_max if vol_max > 0 else 1.0
    vol_ceiling = max(0, int(n_rows * 0.3))

    # --- MACD viewport ---
    macd_all = macd_lines + macd_sigs + macd_hists
    m_lo = min(macd_all) if macd_all else 0.0
    m_hi = max(macd_all) if macd_all else 1.0
    m_range = m_hi - m_lo if (m_hi - m_lo) > 1e-10 else 1.0

    # --- Render ---
    price_vol_px: dict = {}
    rsi_px: dict = {}
    macd_px: dict = {}
    dmi_px: dict = {}

    for t in range(n):
        ck = f"c{t}"
        cl, op, hi, lo = closes[t], opens[t], highs[t], lows[t]
        is_bull = cl >= op
        body_color = "gs" if is_bull else "rs"
        wick_color = "gw" if is_bull else "rw"

        # --- Volume bars (bottom of price panel, rendered first) ---
        vol_h = int(volumes[t] / vol_max * vol_ceiling + 0.5) if vol_max > 0 else 0
        vol_color = "vg" if is_bull else "vr"
        for r in range(0, min(vol_h + 1, vol_ceiling + 1)):
            _px_add(price_vol_px, ck, r, vol_color, n_rows)

        # --- Candle body ---
        r_open = _px_row(pn(op), n_rows)
        r_close = _px_row(pn(cl), n_rows)
        if r_open >= 0 and r_close >= 0:
            r_lo_body = min(r_open, r_close)
            r_hi_body = max(r_open, r_close)
            if r_lo_body == r_hi_body:
                _px_add(price_vol_px, ck, r_lo_body, "dj", n_rows)
            else:
                for r in range(r_lo_body, r_hi_body + 1):
                    _px_add(price_vol_px, ck, r, body_color, n_rows)

            r_high = _px_row(pn(hi), n_rows)
            r_low = _px_row(pn(lo), n_rows)
            if r_high >= 0:
                for r in range(r_hi_body + 1, r_high + 1):
                    _px_add(price_vol_px, ck, r, wick_color, n_rows)
            if r_low >= 0:
                for r in range(r_low, r_lo_body):
                    _px_add(price_vol_px, ck, r, wick_color, n_rows)

        if sma20s[t] > 0:
            _px_add(price_vol_px, ck, _px_row(pn(sma20s[t]), n_rows), "yl", n_rows)
        if sma50s[t] > 0:
            _px_add(price_vol_px, ck, _px_row(pn(sma50s[t]), n_rows), "rl", n_rows)
        if sma200s[t] > 0:
            _px_add(price_vol_px, ck, _px_row(pn(sma200s[t]), n_rows), "gl", n_rows)
        if bb_ups[t] > 0:
            _px_add(price_vol_px, ck, _px_row(pn(bb_ups[t]), n_rows), "wu", n_rows)
        if bb_los[t] > 0:
            _px_add(price_vol_px, ck, _px_row(pn(bb_los[t]), n_rows), "wl", n_rows)

        # --- RSI panel ---
        rsi_val = rsis[t]
        if rsi_val > 0:
            r_rsi = _px_row(rsi_val / 100.0, n_rows)
            _px_add(rsi_px, ck, r_rsi, "rb", n_rows)
            if rsi_val > 70:
                _px_add(rsi_px, ck, r_rsi, "ro", n_rows)
            elif rsi_val < 30:
                _px_add(rsi_px, ck, r_rsi, "rn", n_rows)

        # --- MACD panel ---
        ml_norm = (macd_lines[t] - m_lo) / m_range
        ms_norm = (macd_sigs[t] - m_lo) / m_range
        mh_norm = (macd_hists[t] - m_lo) / m_range
        center = _px_row((-m_lo) / m_range, n_rows) if m_range > 1e-10 else n_rows // 2

        _px_add(macd_px, ck, _px_row(ml_norm, n_rows), "ml", n_rows)
        _px_add(macd_px, ck, _px_row(ms_norm, n_rows), "ms", n_rows)

        r_hist = _px_row(mh_norm, n_rows)
        if r_hist >= 0 and center >= 0:
            hist_color = "mhg" if macd_hists[t] >= 0 else "mhr"
            lo_h, hi_h = min(center, r_hist), max(center, r_hist)
            for r in range(lo_h, hi_h + 1):
                _px_add(macd_px, ck, r, hist_color, n_rows)

        # --- DMI panel (DMI+, DMI-, ADX all 0-100) ---
        dp, dm, ax = dmi_plus[t], dmi_minus[t], adx_vals[t]
        if dp > 0:
            _px_add(dmi_px, ck, _px_row(dp / 100.0, n_rows), "dp", n_rows)
        if dm > 0:
            _px_add(dmi_px, ck, _px_row(dm / 100.0, n_rows), "dm", n_rows)
        if ax > 0:
            _px_add(dmi_px, ck, _px_row(ax / 100.0, n_rows), "ax", n_rows)

    return {
        "price_vol": price_vol_px,
        "rsi": rsi_px,
        "macd": macd_px,
        "dmi": dmi_px,
    }


# ---------------------------------------------------------------------------
# Viewport builder
# ---------------------------------------------------------------------------

def build_viewport(pixel_data: dict, n_cols: int, n_rows: int) -> list[list[frozenset]]:
    """Convert rendered pixel data to list[list[frozenset]].

    Returns a list of columns (left to right). Each column is a list of rows
    (top to bottom) across all 4 panels stacked vertically.
    """
    viewport = []
    for c in range(n_cols):
        col_key = f"c{c}"
        column = []
        for panel_name in PANELS:
            panel_data = pixel_data.get(panel_name, {})
            col_data = panel_data.get(col_key, {})
            for r in range(n_rows):
                cell = col_data.get(f"r{r}")
                if cell:
                    column.append(frozenset(cell) if isinstance(cell, set)
                                  else frozenset({cell}))
                else:
                    column.append(NULL_COLOR)
        viewport.append(column)
    return viewport


def build_null_template(n_cols: int, n_rows: int) -> list[list[frozenset]]:
    """All-null viewport of the same shape, for removing null bias."""
    total_rows = n_rows * len(PANELS)
    return [[NULL_COLOR] * total_rows for _ in range(n_cols)]


# ---------------------------------------------------------------------------
# Grid visualization
# ---------------------------------------------------------------------------

COLOR_CHARS = {
    "gs": "\033[92m\u2588",   # green solid (bull body)
    "rs": "\033[91m\u2588",   # red solid (bear body)
    "gw": "\033[92m\u2502",   # green wick
    "rw": "\033[91m\u2502",   # red wick
    "dj": "\033[93m\u2500",   # doji
    "yl": "\033[93m\u2500",   # SMA20 yellow line
    "rl": "\033[91m\u2500",   # SMA50 red line
    "gl": "\033[92m\u2500",   # SMA200 green line
    "wu": "\033[37m\u00b7",   # BB upper
    "wl": "\033[37m\u00b7",   # BB lower
    "vg": "\033[32m\u2591",   # volume green
    "vr": "\033[31m\u2591",   # volume red
    "rb": "\033[96m\u2500",   # RSI line
    "ro": "\033[91m\u2501",   # RSI overbought
    "rn": "\033[92m\u2501",   # RSI oversold
    "ml": "\033[94m\u2500",   # MACD line
    "ms": "\033[95m\u2500",   # MACD signal
    "mhg": "\033[92m\u2591",  # MACD hist green
    "mhr": "\033[91m\u2591",  # MACD hist red
    "dp": "\033[92m\u25cf",   # DMI+ green dot
    "dm": "\033[91m\u25cf",   # DMI- red dot
    "ax": "\033[93m\u25cf",   # ADX yellow dot
}
RESET = "\033[0m"


def print_viewport(pixel_data: dict, n_cols: int, n_rows: int,
                   label: str = "", candle_info: str = ""):
    """Print an ASCII visualization of the viewport grid."""
    if label or candle_info:
        print(f"\n{'='*n_cols*2}  {label} {candle_info}")

    for panel_name in PANELS:
        print(f"  --- {panel_name} ---")
        panel_data = pixel_data.get(panel_name, {})
        for r in range(n_rows - 1, -1, -1):
            row_str = []
            for c in range(n_cols):
                cell = panel_data.get(f"c{c}", {}).get(f"r{r}")
                if not cell:
                    row_str.append(" ")
                elif isinstance(cell, set) and len(cell) > 1:
                    first = sorted(cell)[0]
                    row_str.append(COLOR_CHARS.get(first, "?") + RESET)
                elif isinstance(cell, set):
                    color = next(iter(cell))
                    row_str.append(COLOR_CHARS.get(color, "?") + RESET)
                else:
                    row_str.append(COLOR_CHARS.get(cell, "?") + RESET)
            print(f"  {''.join(row_str)}")
    print(RESET)


# ---------------------------------------------------------------------------
# Discriminative Refiner (Approach A)
# ---------------------------------------------------------------------------

class DiscriminativeRefiner:
    """Iterative discriminative feature isolation using Holon algebra.

    Instead of averaging all examples equally (prototype), this:
    1. Extracts shared structure via resonance
    2. Removes it via negate to isolate class-specific features
    3. Amplifies the discriminative signal via grover_amplify
    4. Re-accumulates with examples weighted by their discriminative margin
    5. Repeats for N epochs
    """

    def __init__(self, dims: int, epochs: int = 3, grover_iters: int = 2):
        self.dims = dims
        self.epochs = epochs
        self.grover_iters = grover_iters
        self.buy_disc = None
        self.sell_disc = None

    def fit(self, buy_vecs: list[np.ndarray], sell_vecs: list[np.ndarray]):
        buy_model = prototype(buy_vecs)
        sell_model = prototype(sell_vecs)

        for epoch in range(self.epochs):
            shared = resonance(buy_model, sell_model)
            buy_disc = negate(buy_model, shared)
            sell_disc = negate(sell_model, shared)

            if self.grover_iters > 0:
                buy_disc = grover_amplify(buy_disc, shared, self.grover_iters)
                sell_disc = grover_amplify(sell_disc, shared, self.grover_iters)

            buy_accum = create_accumulator(self.dims)
            sell_accum = create_accumulator(self.dims)

            for vec in buy_vecs:
                margin = (float(cosine_similarity(vec, buy_disc))
                          - float(cosine_similarity(vec, sell_disc)))
                buy_accum = accumulate_weighted(buy_accum, vec, max(margin, 0.01))

            for vec in sell_vecs:
                margin = (float(cosine_similarity(vec, sell_disc))
                          - float(cosine_similarity(vec, buy_disc)))
                sell_accum = accumulate_weighted(sell_accum, vec, max(margin, 0.01))

            buy_model = threshold_bipolar(buy_accum)
            sell_model = threshold_bipolar(sell_accum)

        shared = resonance(buy_model, sell_model)
        self.buy_disc = negate(buy_model, shared)
        self.sell_disc = negate(sell_model, shared)
        if self.grover_iters > 0:
            self.buy_disc = grover_amplify(self.buy_disc, shared, self.grover_iters)
            self.sell_disc = grover_amplify(self.sell_disc, shared, self.grover_iters)

        sep = float(cosine_similarity(self.buy_disc, self.sell_disc))
        return sep

    def predict(self, vec: np.ndarray) -> tuple[str, float]:
        sb = float(cosine_similarity(vec, self.buy_disc))
        ss = float(cosine_similarity(vec, self.sell_disc))
        return ("BUY" if sb > ss else "SELL"), sb - ss


# ---------------------------------------------------------------------------
# Subspace Classifier (Approach B — spectral firewall pattern)
# ---------------------------------------------------------------------------

class SubspaceClassifier:
    """Per-class OnlineSubspace with gated updates.

    Learns a manifold (CCIPCA subspace) for each class. Classifies by
    residual distance — which subspace better explains the test vector.
    Gated updates reject examples with high residual to prevent noise
    absorption.
    """

    def __init__(self, dims: int, k: int = 32, gate_sigma: float = 1.5):
        self.dims = dims
        self.k = k
        self.gate_sigma = gate_sigma
        self.buy_sub = None
        self.sell_sub = None

    def fit(self, buy_vecs: list[np.ndarray], sell_vecs: list[np.ndarray]):
        self.buy_sub = OnlineSubspace(dim=self.dims, k=self.k)
        self.sell_sub = OnlineSubspace(dim=self.dims, k=self.k)

        buy_residuals = self._gated_train(self.buy_sub, buy_vecs)
        sell_residuals = self._gated_train(self.sell_sub, sell_vecs)

        return {
            "buy_updates": len(buy_residuals),
            "sell_updates": len(sell_residuals),
            "buy_res_mean": np.mean(buy_residuals) if buy_residuals else 0,
            "sell_res_mean": np.mean(sell_residuals) if sell_residuals else 0,
        }

    def _gated_train(self, sub: OnlineSubspace, vecs: list[np.ndarray]) -> list[float]:
        accepted_residuals = []
        warmup = min(50, len(vecs) // 2)

        for i, vec in enumerate(vecs):
            v = vec.astype(np.float64)
            if i < warmup:
                res = sub.update(v)
                accepted_residuals.append(res)
            else:
                res = sub.residual(v)
                mean_r = np.mean(accepted_residuals[-50:])
                std_r = np.std(accepted_residuals[-50:]) + 1e-10
                if res < mean_r + self.gate_sigma * std_r:
                    sub.update(v)
                    accepted_residuals.append(res)

        return accepted_residuals

    def predict(self, vec: np.ndarray) -> tuple[str, float]:
        v = vec.astype(np.float64)
        buy_res = self.buy_sub.residual(v)
        sell_res = self.sell_sub.residual(v)
        margin = sell_res - buy_res
        return ("BUY" if buy_res < sell_res else "SELL"), margin


# ---------------------------------------------------------------------------
# Engram library
# ---------------------------------------------------------------------------

class EngramLibrary:
    """Case-based memory using Holon accumulators.

    Groups similar vectors into engrams (clusters) per label.
    Uses create_accumulator/accumulate for frequency-preserving updates,
    threshold_bipolar only at query time.
    """

    def __init__(self, merge_threshold: float = 0.3, dims: int = 10000):
        self.engrams: list[tuple[str, np.ndarray, int]] = []
        self.merge_threshold = merge_threshold
        self.dims = dims

    def _query_vec(self, accum: np.ndarray) -> np.ndarray:
        return threshold_bipolar(accum)

    def add(self, label: str, vec: np.ndarray):
        best_sim = -1.0
        best_idx = -1
        for i, (lbl, accum, cnt) in enumerate(self.engrams):
            if lbl != label:
                continue
            sim = float(cosine_similarity(vec, self._query_vec(accum)))
            if sim > best_sim:
                best_sim = sim
                best_idx = i

        if best_sim >= self.merge_threshold and best_idx >= 0:
            lbl, accum, cnt = self.engrams[best_idx]
            self.engrams[best_idx] = (lbl, accumulate(accum, vec), cnt + 1)
        else:
            new_accum = create_accumulator(self.dims)
            self.engrams.append((label, accumulate(new_accum, vec), 1))

    def classify(self, vec: np.ndarray) -> tuple[str | None, float]:
        best_sim = -2.0
        best_label = None
        for lbl, accum, cnt in self.engrams:
            sim = float(cosine_similarity(vec, self._query_vec(accum)))
            if sim > best_sim:
                best_sim = sim
                best_label = lbl
        return best_label, best_sim

    def stats(self) -> dict:
        from collections import Counter
        lc = Counter(lbl for lbl, _, _ in self.engrams)
        sizes = [cnt for _, _, cnt in self.engrams]
        return {"n": len(self.engrams), "labels": dict(lc),
                "sizes": f"{min(sizes)}-{max(sizes)}" if sizes else "0"}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--dims", type=int, default=10000)
    p.add_argument("--window", type=int, default=48)
    p.add_argument("--px-rows", type=int, default=25)
    p.add_argument("--max-train", type=int, default=5000)
    p.add_argument("--max-test", type=int, default=5000)
    p.add_argument("--merge-threshold", type=float, default=0.3)
    p.add_argument("--vol-threshold", type=float, default=0.002)
    p.add_argument("--label", default="label_oracle_10")
    p.add_argument("--knn", type=int, nargs="+", default=[1, 3, 5, 10, 20])
    p.add_argument("--label-delay", type=int, default=0,
                   help="Shift label lookup forward by N candles (momentum confirmation)")
    p.add_argument("--show-confused", type=int, default=0,
                   help="Print N misclassified viewport grids for visual inspection")
    args = p.parse_args()

    total_pixels = args.window * args.px_rows * len(PANELS)
    cap_sqrt = int(args.dims ** 0.5)
    cap_dlogd = int(args.dims / np.log2(args.dims))

    print(f"Raster Real (Encoder-based)", flush=True)
    print(f"  {args.dims}D, window={args.window}, px_rows={args.px_rows}", flush=True)
    print(f"  Panels: {', '.join(PANELS)}", flush=True)
    print(f"  Grid: {args.window} cols x {args.px_rows * len(PANELS)} rows "
          f"({total_pixels} pixels/viewport)", flush=True)
    print(f"  Capacity: sqrt(D)={cap_sqrt}, D/log2(D)={cap_dlogd}", flush=True)
    if args.label_delay > 0:
        print(f"  Label delay: {args.label_delay} candles "
              f"({args.label_delay * 5}min confirmation window)", flush=True)

    # --- Load data ---
    train_years = {2019, 2020}
    test_years = {2021, 2022}
    min_year = min(train_years | test_years)

    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS + [args.label]:
        if c not in seen:
            cols.append(c)
            seen.add(c)

    rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles WHERE year >= ? ORDER BY ts",
        (min_year,)
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in rows]
    print(f"  Loaded {len(candles):,} candles (years >= {min_year})", flush=True)

    # --- Split train/test ---
    train_idx: list[tuple[int, str]] = []
    test_idx: list[tuple[int, str]] = []
    delay = args.label_delay
    for i in range(args.window - 1, len(candles) - delay):
        c = candles[i]
        atr_r = c.get("atr_r") or 0
        year = c.get("year")
        lbl = candles[i + delay].get(args.label)
        if atr_r <= args.vol_threshold or lbl not in ("BUY", "SELL"):
            continue
        if year in train_years:
            train_idx.append((i, lbl))
        elif year in test_years:
            test_idx.append((i, lbl))

    np.random.seed(42)
    if len(train_idx) > args.max_train:
        sel = np.random.choice(len(train_idx), args.max_train, replace=False)
        sel.sort()
        train_idx = [train_idx[i] for i in sel]
    if len(test_idx) > args.max_test:
        sel = np.random.choice(len(test_idx), args.max_test, replace=False)
        sel.sort()
        test_idx = [test_idx[i] for i in sel]

    print(f"  Train: {len(train_idx)} (2019-2020), Test: {len(test_idx)} (2021-2022)",
          flush=True)

    # --- Encode ---
    all_indices = [i for i, _ in train_idx] + [i for i, _ in test_idx]
    vm = DeterministicVectorManager(dimensions=args.dims)
    enc = Encoder(vm)

    null_template = build_null_template(args.window, args.px_rows)
    null_vec = enc.encode_list(null_template, mode="positional")

    print(f"\n  Encoding {len(all_indices)} viewports at {args.dims}D "
          f"(null removal enabled)...", flush=True)
    t0 = time.time()
    vec_cache: dict[int, np.ndarray] = {}

    for count, idx in enumerate(all_indices):
        pixel_data = render_viewport(candles, idx, args.window, args.px_rows)
        viewport = build_viewport(pixel_data, args.window, args.px_rows)
        raw = enc.encode_list(viewport, mode="positional")
        vec_cache[idx] = difference(null_vec, raw)

        if (count + 1) % 100 == 0:
            rate = (count + 1) / (time.time() - t0)
            eta = (len(all_indices) - count - 1) / rate
            print(f"    {count+1}/{len(all_indices)} ({rate:.1f}/s, ETA {eta:.0f}s)",
                  flush=True)

    enc_time = time.time() - t0
    print(f"  Encoded in {enc_time:.1f}s ({len(all_indices)/enc_time:.0f} vec/s)", flush=True)

    # --- Prototype baseline ---
    train_buy = [vec_cache[i] for i, lbl in train_idx if lbl == "BUY"]
    train_sell = [vec_cache[i] for i, lbl in train_idx if lbl == "SELL"]
    buy_proto = prototype(train_buy)
    sell_proto = prototype(train_sell)
    proto_sim = float(cosine_similarity(buy_proto, sell_proto))
    print(f"\n  Prototype cos(BUY, SELL) = {proto_sim:.4f}", flush=True)

    correct_proto = 0
    confused = []
    for i, lbl in test_idx:
        sb = float(cosine_similarity(vec_cache[i], buy_proto))
        ss = float(cosine_similarity(vec_cache[i], sell_proto))
        pred = "BUY" if sb > ss else "SELL"
        if pred == lbl:
            correct_proto += 1
        else:
            confused.append((i, lbl, pred, sb, ss))
    proto_acc = correct_proto / len(test_idx) * 100
    print(f"  Prototype accuracy: {proto_acc:.1f}%", flush=True)

    # --- Discriminant (subtract SELL from BUY) ---
    discriminant = difference(sell_proto, buy_proto)
    correct_disc = 0
    for i, lbl in test_idx:
        score = float(cosine_similarity(vec_cache[i], discriminant))
        pred = "BUY" if score > 0 else "SELL"
        if pred == lbl:
            correct_disc += 1
    disc_acc = correct_disc / len(test_idx) * 100
    print(f"  Discriminant accuracy: {disc_acc:.1f}%", flush=True)

    # --- Contrastive prototypes (subtract opposing class from each sample) ---
    mod_buys = [difference(sell_proto, v) for v in train_buy]
    mod_sells = [difference(buy_proto, v) for v in train_sell]
    buy_proto_mod = prototype(mod_buys)
    sell_proto_mod = prototype(mod_sells)
    mod_sim = float(cosine_similarity(buy_proto_mod, sell_proto_mod))
    print(f"\n  Contrastive cos(BUY, SELL) = {mod_sim:.4f}", flush=True)

    correct_mod = 0
    for i, lbl in test_idx:
        v = vec_cache[i]
        sb = float(cosine_similarity(v, buy_proto_mod))
        ss = float(cosine_similarity(v, sell_proto_mod))
        if ("BUY" if sb > ss else "SELL") == lbl:
            correct_mod += 1
    mod_acc = correct_mod / len(test_idx) * 100
    print(f"  Contrastive accuracy: {mod_acc:.1f}%", flush=True)

    # --- Discriminative Refiner ---
    print(f"\n  Training discriminative refiner (epochs=3, grover=2)...", flush=True)
    refiner = DiscriminativeRefiner(dims=args.dims, epochs=3, grover_iters=2)
    ref_sep = refiner.fit(train_buy, train_sell)
    print(f"  Refiner cos(BUY_disc, SELL_disc) = {ref_sep:.4f}", flush=True)

    correct_ref = 0
    for i, lbl in test_idx:
        pred, _ = refiner.predict(vec_cache[i])
        if pred == lbl:
            correct_ref += 1
    ref_acc = correct_ref / len(test_idx) * 100
    print(f"  Refiner accuracy: {ref_acc:.1f}%", flush=True)

    # --- Subspace Classifier ---
    print(f"\n  Training subspace classifier (k=32, gated)...", flush=True)
    sub_clf = SubspaceClassifier(dims=args.dims, k=32, gate_sigma=1.5)
    sub_stats = sub_clf.fit(train_buy, train_sell)
    print(f"  Subspace stats: {sub_stats}", flush=True)

    correct_sub = 0
    for i, lbl in test_idx:
        pred, _ = sub_clf.predict(vec_cache[i])
        if pred == lbl:
            correct_sub += 1
    sub_acc = correct_sub / len(test_idx) * 100
    print(f"  Subspace accuracy: {sub_acc:.1f}%", flush=True)

    if args.show_confused > 0 and confused:
        n_show = min(args.show_confused, len(confused))
        print(f"\n  === {n_show} Misclassified Viewports ===", flush=True)
        for i, lbl, pred, sb, ss in confused[:n_show]:
            c = candles[i]
            info = (f"idx={i} ts={c.get('ts')} close={c.get('close'):.2f} "
                    f"true={lbl} pred={pred} "
                    f"sim(BUY)={sb:.4f} sim(SELL)={ss:.4f}")
            pixel_data = render_viewport(candles, i, args.window, args.px_rows)
            print_viewport(pixel_data, args.window, args.px_rows,
                           label=f"[WRONG]", candle_info=info)

    # --- k-NN ---
    print(f"\n  Running k-NN...", flush=True)
    train_vecs = np.stack([vec_cache[i].astype(np.float32) for i, _ in train_idx])
    train_labels = [lbl for _, lbl in train_idx]
    norms = np.linalg.norm(train_vecs, axis=1, keepdims=True)
    norms[norms == 0] = 1
    train_vecs_n = train_vecs / norms

    for k in args.knn:
        correct = 0
        for i, lbl in test_idx:
            qvec = vec_cache[i].astype(np.float32)
            qnorm = np.linalg.norm(qvec)
            if qnorm > 0:
                qvec = qvec / qnorm
            sims = train_vecs_n @ qvec
            top_k = np.argsort(sims)[-k:]
            buy_votes = sum(1 for j in top_k if train_labels[j] == "BUY")
            if ("BUY" if buy_votes > k // 2 else "SELL") == lbl:
                correct += 1
        acc = correct / len(test_idx) * 100
        print(f"    k={k:>3d}: {acc:.1f}%", flush=True)

    # --- Engram library ---
    print(f"\n  Building engram library (threshold={args.merge_threshold})...", flush=True)
    lib = EngramLibrary(merge_threshold=args.merge_threshold, dims=args.dims)
    for i, lbl in train_idx:
        lib.add(lbl, vec_cache[i])
    print(f"  Library: {lib.stats()}", flush=True)

    correct_eng = 0
    for i, lbl in test_idx:
        pred, _ = lib.classify(vec_cache[i])
        if pred == lbl:
            correct_eng += 1
    eng_acc = correct_eng / len(test_idx) * 100
    print(f"  Engram accuracy: {eng_acc:.1f}%", flush=True)

    # --- Per-year breakdown ---
    print(f"\n  Per-year (prototype):", flush=True)
    year_stats: dict[int, list[int]] = defaultdict(lambda: [0, 0])
    for i, lbl in test_idx:
        year = candles[i].get("year")
        sb = float(cosine_similarity(vec_cache[i], buy_proto))
        ss = float(cosine_similarity(vec_cache[i], sell_proto))
        year_stats[year][1] += 1
        if ("BUY" if sb > ss else "SELL") == lbl:
            year_stats[year][0] += 1
    for y in sorted(year_stats):
        c, n = year_stats[y]
        print(f"    {y}: {c / n * 100:.1f}% ({n} trades)", flush=True)

    print(f"\nDone.", flush=True)


if __name__ == "__main__":
    main()
