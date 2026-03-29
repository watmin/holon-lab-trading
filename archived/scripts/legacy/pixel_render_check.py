#!/usr/bin/env python
"""pixel_render_check.py — Render a single pixel-encoded window as text art.

Verifies that build_pixel_data actually produces a recognizable chart.
Shows each panel as a grid with color tokens at their pixel positions.
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import build_pixel_data, ALL_DB_COLS, PX_ROWS

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

# Short display chars for each color token
COLOR_DISPLAY = {
    "gs": "\033[92m█\033[0m",   # green solid (bullish body)
    "rs": "\033[91m█\033[0m",   # red solid (bearish body)
    "gw": "\033[92m│\033[0m",   # green wick
    "rw": "\033[91m│\033[0m",   # red wick
    "dj": "\033[93m─\033[0m",   # doji
    "yl": "\033[93m●\033[0m",   # SMA20 / BB middle (yellow)
    "rl": "\033[91m●\033[0m",   # SMA50 (red line)
    "gl": "\033[92m●\033[0m",   # SMA200 (green line)
    "wu": "\033[97m^\033[0m",   # BB upper (white)
    "wl": "\033[97mv\033[0m",   # BB lower (white)
    "vg": "\033[92m▓\033[0m",   # volume green
    "vr": "\033[91m▓\033[0m",   # volume red
    "rb": "\033[95m─\033[0m",   # RSI line
    "ro": "\033[91m!\033[0m",   # RSI overbought
    "rn": "\033[92m!\033[0m",   # RSI oversold
    "ml": "\033[96m─\033[0m",   # MACD line
    "ms": "\033[93m─\033[0m",   # signal line
    "mhg": "\033[92m▒\033[0m",  # histogram positive
    "mhr": "\033[91m▒\033[0m",  # histogram negative
}

# Plain-text fallbacks (no ANSI)
COLOR_PLAIN = {
    "gs": "G", "rs": "R", "gw": "|", "rw": "|", "dj": "-",
    "yl": "Y", "rl": "r", "gl": "g", "wu": "^", "wl": "v",
    "vg": "G", "vr": "R",
    "rb": "~", "ro": "!", "rn": "!",
    "ml": "M", "ms": "S", "mhg": "+", "mhr": "-",
}

OVERLAP_DISPLAY = {
    "gs": 10, "rs": 9, "gw": 5, "rw": 5, "dj": 8,
    "yl": 7, "rl": 6, "gl": 6, "wu": 4, "wl": 4,
    "vg": 10, "vr": 10,
    "rb": 10, "ro": 10, "rn": 10,
    "ml": 10, "ms": 9, "mhg": 8, "mhr": 8,
}


def sf(v):
    return 0.0 if v is None else float(v)


def render_panel(panel_data: dict, panel_name: str, window_size: int, use_color: bool = True):
    """Render a panel as a text grid."""
    disp = COLOR_DISPLAY if use_color else COLOR_PLAIN

    print(f"\n  === {panel_name.upper()} ===")
    header = "     " + "".join(f"{t:>2d}" for t in range(window_size))
    print(header)

    for row in range(PX_ROWS - 1, -1, -1):
        line = f"  {row:>2d} "
        for t in range(window_size):
            ck = f"c{t}"
            rk = f"r{row}"
            col_data = panel_data.get(ck, {})
            pixel = col_data.get(rk)

            if pixel is None:
                line += "  "
            elif isinstance(pixel, set):
                if len(pixel) == 1:
                    c = next(iter(pixel))
                    line += f" {disp.get(c, '?')}"
                else:
                    best = max(pixel, key=lambda c: OVERLAP_DISPLAY.get(c, 0))
                    line += f" {disp.get(best, '?')}"
            else:
                line += f" {disp.get(pixel, '?')}"
        print(line)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--idx", type=int, default=5000,
                        help="Candle index to render")
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("--show-raw", action="store_true",
                        help="Show raw price values alongside")
    args = parser.parse_args()

    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]

    idx = min(args.idx, len(candles) - 1)
    idx = max(args.window - 1, idx)

    print(f"Rendering candle idx={idx}, window={args.window}")
    start = max(0, idx - args.window + 1)
    window = candles[start:idx + 1]

    c = candles[idx]
    print(f"  Last candle: ts={c.get('ts')}, "
          f"O={sf(c.get('open')):.2f}, H={sf(c.get('high')):.2f}, "
          f"L={sf(c.get('low')):.2f}, C={sf(c.get('close')):.2f}")
    print(f"  RSI={sf(c.get('rsi')):.1f}, MACD={sf(c.get('macd_line')):.4f}")

    if args.show_raw:
        print(f"\n  Raw prices (last {args.window} candles):")
        for i, w in enumerate(window):
            bull = "▲" if sf(w.get("close")) >= sf(w.get("open")) else "▼"
            print(f"    c{i:2d}: O={sf(w.get('open')):>10.2f} "
                  f"H={sf(w.get('high')):>10.2f} "
                  f"L={sf(w.get('low')):>10.2f} "
                  f"C={sf(w.get('close')):>10.2f} {bull} "
                  f"V={sf(w.get('volume')):>12.0f} "
                  f"RSI={sf(w.get('rsi')):>5.1f}")

    data = build_pixel_data(candles, idx, args.window)

    # Count populated pixels per panel
    for panel_name in ["price", "vol", "rsi", "macd"]:
        panel = data.get(panel_name, {})
        total_pixels = 0
        for ck, col in panel.items():
            total_pixels += len(col)
        print(f"  {panel_name}: {total_pixels} filled pixels")

    for panel_name in ["price", "vol", "rsi", "macd"]:
        render_panel(data.get(panel_name, {}), panel_name, args.window,
                     use_color=not args.no_color)

    # Binding count per stripe analysis
    from holon import DeterministicVectorManager, Encoder
    encoder = Encoder(DeterministicVectorManager(dimensions=4096))
    stripe_counts = [0] * 32
    for panel_name in ["price", "vol", "rsi", "macd"]:
        panel = data.get(panel_name, {})
        for ck, col in panel.items():
            for rk, colors in col.items():
                path = f"{panel_name}.{ck}.{rk}"
                s = Encoder.field_stripe(path, 32)
                stripe_counts[s] += 1

    print(f"\n  Bindings per stripe (32 stripes):")
    print(f"    min={min(stripe_counts)}, max={max(stripe_counts)}, "
          f"mean={sum(stripe_counts)/len(stripe_counts):.1f}, "
          f"total={sum(stripe_counts)}")
    print(f"    Kanerva capacity @ 4096D ≈ {int(4096**0.5)} items")
    print(f"    Stripes over capacity: "
          f"{sum(1 for c in stripe_counts if c > 64)}/32")


if __name__ == "__main__":
    main()
