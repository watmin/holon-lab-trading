#!/usr/bin/env python
"""pixel_inspect.py — VSA Introspection: depixelate BUY/SELL prototypes.

Uses Holon's algebraic unbinding to probe what BUY and SELL prototypes
"expect" at each pixel position on the chart. This exploits the declarative
nature of VSA: every binding is reversible, so we can ask "what color does
the BUY prototype see at price.c24.r30?" and compare to SELL.

Architecture:
  1. Build BUY/SELL per-stripe prototypes from warm-up data
  2. For each pixel position, unbind the role vector from both prototypes
  3. Cleanup the result against a color-token codebook
  4. Rank positions by discrimination score (how different BUY vs SELL)
  5. Render a visual diff showing where they diverge

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/pixel_inspect.py \
        --workers 4
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    bind,
    cosine_similarity,
    difference,
    prototype,
    resonance,
    unbind,
)

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import build_pixel_data, ALL_DB_COLS, PX_ROWS

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

PANEL_NAMES = ["price", "vol", "rsi", "macd"]
PRICE_COLORS = ["gs", "rs", "gw", "rw", "dj", "yl", "rl", "gl", "wu", "wl"]
VOL_COLORS = ["vg", "vr"]
RSI_COLORS = ["rb", "ro", "rn"]
MACD_COLORS = ["ml", "ms", "mhg", "mhr"]
ALL_COLORS = PRICE_COLORS + VOL_COLORS + RSI_COLORS + MACD_COLORS
PANEL_COLORS = {
    "price": PRICE_COLORS,
    "vol": VOL_COLORS,
    "rsi": RSI_COLORS,
    "macd": MACD_COLORS,
}


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# =========================================================================
# Multiprocessing encoding
# =========================================================================

_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    data = build_pixel_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


# =========================================================================
# Introspection
# =========================================================================

def build_color_codebook(vm: DeterministicVectorManager) -> Dict[str, np.ndarray]:
    """Build codebook of color token vectors for cleanup."""
    return {c: vm.get_vector(c) for c in ALL_COLORS}


def build_set_filler(encoder: Encoder, colors: set) -> np.ndarray:
    """Encode a set of color tokens the same way the encoder does."""
    return encoder.leaf_binding(colors, "__dummy__")


def unbind_and_identify(
    stripe_vec: np.ndarray,
    role_vec: np.ndarray,
    color_codebook: Dict[str, np.ndarray],
    encoder: Encoder,
    panel_colors: List[str],
) -> Tuple[str, float]:
    """Unbind a role from a stripe and identify the closest color set.

    Returns the best matching color token and its cosine similarity.
    """
    unbound = unbind(stripe_vec, role_vec)

    best_color = "?"
    best_sim = -1.0
    for color_name, color_vec in color_codebook.items():
        if color_name not in panel_colors:
            continue
        sim = float(cosine_similarity(unbound, color_vec))
        if sim > best_sim:
            best_sim = sim
            best_color = color_name

    for c1 in panel_colors:
        for c2 in panel_colors:
            if c1 >= c2:
                continue
            combo_binding = encoder.leaf_binding({c1, c2}, "__dummy__")
            combo_filler = unbind(combo_binding, encoder.vector_manager.get_vector("__dummy__"))
            sim = float(cosine_similarity(unbound, combo_filler))
            if sim > best_sim:
                best_sim = sim
                best_color = f"{c1}+{c2}"

    return best_color, best_sim


def inspect_prototypes(
    buy_stripe_protos: List[np.ndarray],
    sell_stripe_protos: List[np.ndarray],
    encoder: Encoder,
    n_stripes: int,
    window_size: int,
) -> List[Dict]:
    """Unbind every pixel position from BUY/SELL prototypes and compare."""
    vm = encoder.vector_manager
    color_codebook = build_color_codebook(vm)

    results = []

    for panel in PANEL_NAMES:
        panel_cols = PANEL_COLORS[panel]
        for t in range(window_size):
            for row in range(PX_ROWS):
                path = f"{panel}.c{t}.r{row}"
                stripe_idx = Encoder.field_stripe(path, n_stripes)
                role = vm.get_vector(path)

                buy_stripe = buy_stripe_protos[stripe_idx]
                sell_stripe = sell_stripe_protos[stripe_idx]

                buy_unbound = unbind(buy_stripe, role)
                sell_unbound = unbind(sell_stripe, role)

                disc_score = 1.0 - float(cosine_similarity(buy_unbound, sell_unbound))

                buy_best = "?"
                buy_best_sim = -1.0
                sell_best = "?"
                sell_best_sim = -1.0
                for cname in panel_cols:
                    cvec = color_codebook[cname]
                    bs = float(cosine_similarity(buy_unbound, cvec))
                    ss = float(cosine_similarity(sell_unbound, cvec))
                    if bs > buy_best_sim:
                        buy_best_sim = bs
                        buy_best = cname
                    if ss > sell_best_sim:
                        sell_best_sim = ss
                        sell_best = cname

                results.append({
                    "path": path,
                    "panel": panel,
                    "col": t,
                    "row": row,
                    "stripe": stripe_idx,
                    "disc_score": disc_score,
                    "buy_color": buy_best,
                    "buy_sim": buy_best_sim,
                    "sell_color": sell_best,
                    "sell_sim": sell_best_sim,
                })

    results.sort(key=lambda x: x["disc_score"], reverse=True)
    return results


def render_panel_diff(
    results: List[Dict],
    panel: str,
    window_size: int,
    threshold: float = 0.01,
):
    """Render a text grid showing where BUY and SELL prototypes differ."""
    panel_results = {
        (r["col"], r["row"]): r for r in results if r["panel"] == panel
    }

    log(f"\n  Panel: {panel.upper()} (threshold disc_score > {threshold})")
    log(f"  {'':3s} " + "".join(f"{t:>4d}" for t in range(0, window_size, 4)))

    for row in range(PX_ROWS - 1, -1, -1):
        line = f"  r{row:<2d} "
        for t in range(window_size):
            r = panel_results.get((t, row))
            if r is None or r["disc_score"] < threshold:
                line += " "
            elif r["buy_color"] != r["sell_color"]:
                line += "X"
            else:
                line += "."
        log(line)


# =========================================================================
# Discriminative resonance test
# =========================================================================

def test_disc_resonance(
    buy_stripe_protos: List[np.ndarray],
    sell_stripe_protos: List[np.ndarray],
    buy_flat: np.ndarray,
    sell_flat: np.ndarray,
    vec_cache: dict,
    adaptive_labeled: List[Tuple[int, str]],
    n_stripes: int,
    dims: int,
):
    """Test discriminative resonance classification on OOS data."""
    disc_per_stripe = []
    for s in range(n_stripes):
        d = difference(sell_stripe_protos[s], buy_stripe_protos[s])
        disc_per_stripe.append(d)
    disc_flat = np.concatenate(disc_per_stripe)

    log(f"\n{'='*70}")
    log("DISCRIMINATIVE RESONANCE TEST")
    log(f"  {len(adaptive_labeled):,} OOS samples")
    log(f"{'='*70}")

    methods = {
        "raw_cosine": {"correct": 0, "total": 0},
        "disc_resonance": {"correct": 0, "total": 0},
        "disc_resonance_stripe": {"correct": 0, "total": 0},
        "disc_masked_cosine": {"correct": 0, "total": 0},
    }

    for ci, lbl in adaptive_labeled:
        if ci not in vec_cache:
            continue
        arr = vec_cache[ci]
        stripe_vecs = [arr[s].astype(np.float64) for s in range(n_stripes)]
        flat = np.concatenate(stripe_vecs)

        # Method A: Raw cosine (baseline)
        cos_buy = float(cosine_similarity(flat, buy_flat))
        cos_sell = float(cosine_similarity(flat, sell_flat))
        pred_raw = "BUY" if cos_buy > cos_sell else "SELL"
        methods["raw_cosine"]["total"] += 1
        methods["raw_cosine"]["correct"] += int(pred_raw == lbl)

        # Method B: Discriminative resonance (flat)
        filtered = resonance(flat, disc_flat)
        filt_buy = float(cosine_similarity(filtered, buy_flat))
        filt_sell = float(cosine_similarity(filtered, sell_flat))
        pred_dr = "BUY" if filt_buy > filt_sell else "SELL"
        methods["disc_resonance"]["total"] += 1
        methods["disc_resonance"]["correct"] += int(pred_dr == lbl)

        # Method C: Discriminative resonance (per-stripe, then concat)
        filtered_stripes = []
        for s in range(n_stripes):
            fs = resonance(stripe_vecs[s], disc_per_stripe[s])
            filtered_stripes.append(fs)
        filtered_flat = np.concatenate(filtered_stripes)
        fc_buy = float(cosine_similarity(filtered_flat, buy_flat))
        fc_sell = float(cosine_similarity(filtered_flat, sell_flat))
        pred_drs = "BUY" if fc_buy > fc_sell else "SELL"
        methods["disc_resonance_stripe"]["total"] += 1
        methods["disc_resonance_stripe"]["correct"] += int(pred_drs == lbl)

        # Method D: Discriminative resonance against filtered protos
        buy_filt = resonance(buy_flat, disc_flat)
        sell_filt = resonance(sell_flat, disc_flat)
        dm_buy = float(cosine_similarity(filtered, buy_filt))
        dm_sell = float(cosine_similarity(filtered, sell_filt))
        pred_dm = "BUY" if dm_buy > dm_sell else "SELL"
        methods["disc_masked_cosine"]["total"] += 1
        methods["disc_masked_cosine"]["correct"] += int(pred_dm == lbl)

    log("\n  Results:")
    for name, m in methods.items():
        if m["total"] > 0:
            acc = m["correct"] / m["total"] * 100
            log(f"    {name:30s}: {acc:.1f}% ({m['correct']:,}/{m['total']:,})")


# =========================================================================
# Main
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser()
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=4096)
    parser.add_argument("--stripes", type=int, default=32)
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--max-warmup", type=int, default=5000)
    parser.add_argument("--max-adaptive", type=int, default=10000)
    parser.add_argument("--top-n", type=int, default=50,
                        help="Show top N discriminative positions")
    args = parser.parse_args()

    log("=" * 70)
    log("PIXEL INTROSPECTION / DEPIXELATION")
    log(f"  {args.stripes} stripes x {args.dims}D, window={args.window}")
    log(f"  oracle={args.label}")
    log("=" * 70)

    # ---- Load data ----
    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS + [args.label]:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    # ---- Identify volatile + labeled candles ----
    WARMUP_YEARS = {2019, 2020}
    warmup_labeled = []
    adaptive_labeled = []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        lbl = candles[i].get(args.label)
        if lbl not in ("BUY", "SELL"):
            continue
        year = candles[i].get("year")
        if year in WARMUP_YEARS:
            warmup_labeled.append((i, lbl))
        else:
            adaptive_labeled.append((i, lbl))

    log(f"Warm-up labeled: {len(warmup_labeled):,}")
    log(f"Adaptive labeled: {len(adaptive_labeled):,}")

    # ---- Sample ----
    np.random.seed(42)
    if len(warmup_labeled) > args.max_warmup:
        indices = np.random.choice(len(warmup_labeled), args.max_warmup, replace=False)
        indices.sort()
        warmup_labeled = [warmup_labeled[i] for i in indices]
        log(f"Sampled warm-up to {len(warmup_labeled):,}")
    if len(adaptive_labeled) > args.max_adaptive:
        indices = np.random.choice(len(adaptive_labeled), args.max_adaptive, replace=False)
        indices.sort()
        adaptive_labeled = [adaptive_labeled[i] for i in indices]
        log(f"Sampled adaptive to {len(adaptive_labeled):,}")

    # ---- Encode ----
    all_to_encode = [i for i, _ in warmup_labeled] + [i for i, _ in adaptive_labeled]
    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_stripes = args.stripes

    log(f"Encoding {len(all_to_encode):,} vectors ({args.workers} workers)...")
    t_enc = time.time()
    with mp.Pool(args.workers, initializer=_worker_init) as pool:
        results = []
        done = 0
        for result in pool.imap_unordered(_worker_encode, all_to_encode, chunksize=50):
            results.append(result)
            done += 1
            if done % 2000 == 0:
                elapsed = time.time() - t_enc
                rate = done / elapsed
                eta = (len(all_to_encode) - done) / rate
                log(f"  {done:,}/{len(all_to_encode):,} ({rate:.0f}/s) ETA {eta:.0f}s")
    vec_cache = dict(results)
    log(f"Encoded in {time.time() - t_enc:.1f}s")

    # ---- Build per-stripe BUY/SELL prototypes ----
    buy_stripe_accum = [[] for _ in range(args.stripes)]
    sell_stripe_accum = [[] for _ in range(args.stripes)]
    buy_flat_list = []
    sell_flat_list = []

    for idx, lbl in warmup_labeled:
        arr = vec_cache[idx]
        stripe_vecs = [arr[s].astype(np.float64) for s in range(args.stripes)]
        flat = np.concatenate(stripe_vecs)
        if lbl == "BUY":
            for s in range(args.stripes):
                buy_stripe_accum[s].append(stripe_vecs[s])
            buy_flat_list.append(flat)
        else:
            for s in range(args.stripes):
                sell_stripe_accum[s].append(stripe_vecs[s])
            sell_flat_list.append(flat)

    buy_stripe_protos = [prototype(vecs) for vecs in buy_stripe_accum]
    sell_stripe_protos = [prototype(vecs) for vecs in sell_stripe_accum]
    buy_flat_proto = prototype(buy_flat_list)
    sell_flat_proto = prototype(sell_flat_list)

    proto_cos = float(cosine_similarity(buy_flat_proto, sell_flat_proto))
    log(f"\nPrototype cosine(BUY, SELL) = {proto_cos:.6f}")
    log(f"BUY samples: {len(buy_flat_list):,}, SELL samples: {len(sell_flat_list):,}")

    # ---- Per-stripe cosine ----
    log("\nPer-stripe prototype cosine(BUY, SELL):")
    for s in range(args.stripes):
        sc = float(cosine_similarity(buy_stripe_protos[s], sell_stripe_protos[s]))
        log(f"  stripe {s:2d}: {sc:.6f}")

    # ---- Introspection: unbind every pixel position ----
    log(f"\n{'='*70}")
    log("PHASE 1: DEPIXELATION / INTROSPECTION")
    log(f"{'='*70}")

    encoder = Encoder(DeterministicVectorManager(dimensions=args.dims))
    inspection = inspect_prototypes(
        buy_stripe_protos, sell_stripe_protos,
        encoder, args.stripes, args.window,
    )

    total_positions = len(inspection)
    nonzero_disc = sum(1 for r in inspection if r["disc_score"] > 0.001)
    log(f"Total pixel positions inspected: {total_positions:,}")
    log(f"Positions with disc_score > 0.001: {nonzero_disc:,}")

    # Show top discriminative positions
    log(f"\nTop {args.top_n} discriminative positions:")
    log(f"  {'path':25s} {'disc':>7s} {'buy_color':>10s} {'buy_sim':>8s} "
        f"{'sell_color':>10s} {'sell_sim':>8s} {'diff?':>5s}")
    for r in inspection[:args.top_n]:
        diff_marker = " ***" if r["buy_color"] != r["sell_color"] else ""
        log(f"  {r['path']:25s} {r['disc_score']:7.4f} "
            f"{r['buy_color']:>10s} {r['buy_sim']:8.4f} "
            f"{r['sell_color']:>10s} {r['sell_sim']:8.4f}{diff_marker}")

    # Statistics
    disc_scores = [r["disc_score"] for r in inspection]
    log(f"\nDiscrimination score statistics:")
    log(f"  mean:   {np.mean(disc_scores):.6f}")
    log(f"  std:    {np.std(disc_scores):.6f}")
    log(f"  max:    {np.max(disc_scores):.6f}")
    log(f"  median: {np.median(disc_scores):.6f}")
    log(f"  p95:    {np.percentile(disc_scores, 95):.6f}")
    log(f"  p99:    {np.percentile(disc_scores, 99):.6f}")

    # Per-panel discrimination stats
    log(f"\nPer-panel discrimination stats:")
    for panel in PANEL_NAMES:
        panel_scores = [r["disc_score"] for r in inspection if r["panel"] == panel]
        if panel_scores:
            log(f"  {panel:8s}: mean={np.mean(panel_scores):.6f} "
                f"max={np.max(panel_scores):.6f} "
                f"p95={np.percentile(panel_scores, 95):.6f}")

    # Color agreement/disagreement
    agree_count = sum(1 for r in inspection if r["buy_color"] == r["sell_color"])
    disagree_count = total_positions - agree_count
    log(f"\nColor agreement: {agree_count:,}/{total_positions:,} "
        f"({agree_count/total_positions*100:.1f}%)")
    log(f"Color disagreement: {disagree_count:,}/{total_positions:,} "
        f"({disagree_count/total_positions*100:.1f}%)")

    # Render visual diffs
    log(f"\n{'='*70}")
    log("VISUAL DIFF: X = different color, . = same color but disc > threshold")
    log(f"{'='*70}")
    for panel in PANEL_NAMES:
        render_panel_diff(inspection, panel, args.window, threshold=0.005)

    # ---- Discriminant analysis ----
    log(f"\n{'='*70}")
    log("DISCRIMINANT ANALYSIS")
    log(f"{'='*70}")

    disc_flat = difference(sell_flat_proto, buy_flat_proto)

    disc_nonzero = np.sum(disc_flat != 0)
    disc_total = len(disc_flat)
    log(f"Discriminant density: {disc_nonzero}/{disc_total} "
        f"({disc_nonzero/disc_total*100:.1f}%)")

    buy_filt = resonance(buy_flat_proto, disc_flat)
    sell_filt = resonance(sell_flat_proto, disc_flat)
    filt_cos = float(cosine_similarity(buy_filt, sell_filt))
    log(f"Filtered prototype cosine(BUY, SELL): {filt_cos:.6f}")
    log(f"  (vs raw: {proto_cos:.6f})")

    buy_filt_nonzero = np.sum(buy_filt != 0)
    sell_filt_nonzero = np.sum(sell_filt != 0)
    log(f"Filtered density: BUY={buy_filt_nonzero}/{disc_total} "
        f"({buy_filt_nonzero/disc_total*100:.1f}%), "
        f"SELL={sell_filt_nonzero}/{disc_total} "
        f"({sell_filt_nonzero/disc_total*100:.1f}%)")

    # ---- Phase 2: Discriminative resonance classification ----
    test_disc_resonance(
        buy_stripe_protos, sell_stripe_protos,
        buy_flat_proto, sell_flat_proto,
        vec_cache, adaptive_labeled,
        args.stripes, args.dims,
    )

    # Summary
    log(f"\n{'='*70}")
    log("SUMMARY")
    log(f"{'='*70}")
    log(f"  Prototype similarity: {proto_cos:.4f} (raw), {filt_cos:.4f} (filtered)")
    log(f"  Max disc_score: {np.max(disc_scores):.4f}")
    log(f"  Color disagreements: {disagree_count}/{total_positions}")
    log(f"  Discriminant density: {disc_nonzero/disc_total*100:.1f}%")


if __name__ == "__main__":
    main()
