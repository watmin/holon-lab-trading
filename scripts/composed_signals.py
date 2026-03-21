"""Composed Signals — Multi-vector regime-conditional direction predictor.

Architecture:
  Vector 1: REGIME — A single subspace trained on ALL market data. High residual
            means "something is different." The residual profile tells us WHAT
            changed (which stripes are anomalous).

  Vector 2: CONTEXT — Categorical facts about the current market state.
            MA alignment, RSI zone, MACD state, trend direction/strength.
            Bucketed into discrete regimes for conditional analysis.

  Composition: For each (regime_state, context_bucket), compute the historical
              directional bias. Only trade when the bias is strong enough.

This tests the hypothesis: direction is unpredictable ON AVERAGE, but within
specific regime×context combinations, there may be exploitable directional bias.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/composed_signals.py \\
        --n 10000 --workers 6
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    StripedSubspace,
    cosine_similarity,
)

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import (
    build_categorical_data,
    candle_facts,
    compute_actual,
    ALL_DB_COLS,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
SUPERVISED_YEARS = {2019, 2020}
RESOLUTION_CANDLES = 36
MIN_MOVE_PCT = 1.0


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# =========================================================================
# Context bucketing — discrete market state from raw candle values
# =========================================================================

def context_bucket(c: dict) -> str:
    """Extract a discrete context string from a single candle.

    This is deliberately coarse — we want enough samples per bucket
    to measure directional bias reliably.
    """
    close = sf(c.get("close"))
    sma20 = sf(c.get("sma20"))
    sma50 = sf(c.get("sma50"))
    sma200 = sf(c.get("sma200"))
    rsi = sf(c.get("rsi"))
    macd_line = sf(c.get("macd_line"))
    macd_signal = sf(c.get("macd_signal"))
    dmi_plus = sf(c.get("dmi_plus"))
    dmi_minus = sf(c.get("dmi_minus"))
    adx = sf(c.get("adx"))

    parts = []

    # MA structure (3 bits: close vs sma20, sma20 vs sma50, close vs sma200)
    if close > 0 and sma20 > 0:
        parts.append("C>20" if close > sma20 else "C<20")
    if sma20 > 0 and sma50 > 0:
        parts.append("20>50" if sma20 > sma50 else "20<50")
    if close > 0 and sma200 > 0:
        parts.append("C>200" if close > sma200 else "C<200")

    # RSI zone (3 buckets)
    if rsi > 0:
        if rsi < 35:
            parts.append("RSI_low")
        elif rsi < 65:
            parts.append("RSI_mid")
        else:
            parts.append("RSI_hi")

    # MACD momentum
    if macd_line != 0 or macd_signal != 0:
        parts.append("MACD+" if macd_line > macd_signal else "MACD-")

    # Trend
    if dmi_plus > 0 or dmi_minus > 0:
        parts.append("DMI+" if dmi_plus > dmi_minus else "DMI-")

    # ADX strength (2 buckets)
    if adx > 0:
        parts.append("ADX_hi" if adx > 25 else "ADX_lo")

    return "|".join(parts) if parts else "UNKNOWN"


# =========================================================================
# Parallel encoding for regime subspace
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
    data = build_categorical_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


# =========================================================================
# Main
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=10000,
                        help="Sample N supervised + N adaptive")
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--k", type=int, default=20)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--min-bucket", type=int, default=20,
                        help="Minimum samples per bucket to trust the bias")
    parser.add_argument("--bias-threshold", type=float, default=0.60,
                        help="Minimum directional bias to trade")
    args = parser.parse_args()

    log("=" * 80)
    log("COMPOSED SIGNALS — Regime + Context Conditional Direction")
    log(f"  {args.stripes} stripes × {args.dims}D, window={args.window}")
    log(f"  Min bucket size: {args.min_bucket}, bias threshold: {args.bias_threshold:.0%}")
    log("=" * 80)

    # ------------------------------------------------------------------
    # Load data
    # ------------------------------------------------------------------
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

    # ------------------------------------------------------------------
    # Identify indices
    # ------------------------------------------------------------------
    sup_all, adp_all = [], []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[i].get("year")
        if year in SUPERVISED_YEARS:
            sup_all.append(i)
        else:
            adp_all.append(i)

    np.random.seed(42)
    n = args.n
    sup_sample = sorted(np.random.choice(
        sup_all, size=min(n, len(sup_all)), replace=False
    ).tolist())
    adp_sample = sorted(np.random.choice(
        adp_all, size=min(n, len(adp_all)), replace=False
    ).tolist())
    all_to_encode = sup_sample + adp_sample
    log(f"Sample: {len(sup_sample):,} supervised + "
        f"{len(adp_sample):,} adaptive = {len(all_to_encode):,}")

    # ------------------------------------------------------------------
    # Build labels
    # ------------------------------------------------------------------
    labels: Dict[int, str] = {}
    for idx in all_to_encode:
        year = candles[idx].get("year")
        if year in SUPERVISED_YEARS:
            oracle = candles[idx].get(args.label)
            if oracle in ("BUY", "SELL"):
                labels[idx] = oracle
            else:
                labels[idx] = compute_actual(candles, idx)
        else:
            labels[idx] = compute_actual(candles, idx)

    # ------------------------------------------------------------------
    # Encode
    # ------------------------------------------------------------------
    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_stripes = args.stripes
    n_stripes = args.stripes
    dim = args.dims

    log(f"\nEncoding ({args.workers} workers) ...")
    t_enc = time.time()
    with mp.Pool(args.workers, initializer=_worker_init) as pool:
        results = []
        done = 0
        for result in pool.imap_unordered(
            _worker_encode, all_to_encode, chunksize=50
        ):
            results.append(result)
            done += 1
            if done % 2000 == 0:
                elapsed = time.time() - t_enc
                rate = done / elapsed
                log(f"  {done:,}/{len(all_to_encode):,} ({rate:.0f}/s)")

    vec_cache = dict(results)
    log(f"Encoded {len(vec_cache):,} in {time.time() - t_enc:.1f}s")

    # ==================================================================
    # SIGNAL 1: Regime subspace (trained on ALL supervised data)
    # ==================================================================
    log(f"\n--- SIGNAL 1: REGIME SUBSPACE ---")
    regime_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)

    regime_count = 0
    for idx in sup_sample:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL", "QUIET"):
            continue
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        regime_sub.update(svecs)
        regime_count += 1

    log(f"  Trained on {regime_count:,} supervised candles (BUY+SELL+QUIET)")
    log(f"  Threshold: {regime_sub.threshold:.2f}")

    # Compute residuals for all samples
    residuals: Dict[int, float] = {}
    profiles: Dict[int, np.ndarray] = {}
    for idx in all_to_encode:
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        residuals[idx] = regime_sub.residual(svecs)
        profiles[idx] = regime_sub.residual_profile(svecs)

    res_values = [residuals[i] for i in all_to_encode]
    log(f"  Residual stats: mean={np.mean(res_values):.2f}, "
        f"std={np.std(res_values):.2f}, "
        f"p50={np.percentile(res_values, 50):.2f}, "
        f"p90={np.percentile(res_values, 90):.2f}, "
        f"p99={np.percentile(res_values, 99):.2f}")

    # Categorize regime state by residual magnitude
    res_p50 = np.percentile(res_values, 50)
    res_p75 = np.percentile(res_values, 75)
    res_p90 = np.percentile(res_values, 90)

    def regime_state(idx):
        r = residuals[idx]
        if r > res_p90:
            return "ANOMALY"
        elif r > res_p75:
            return "UNUSUAL"
        elif r > res_p50:
            return "NORMAL_HI"
        else:
            return "NORMAL_LO"

    # ==================================================================
    # SIGNAL 2: Context bucket from current candle
    # ==================================================================
    log(f"\n--- SIGNAL 2: CONTEXT BUCKETS ---")
    contexts: Dict[int, str] = {}
    for idx in all_to_encode:
        contexts[idx] = context_bucket(candles[idx])

    unique_contexts = set(contexts.values())
    log(f"  {len(unique_contexts)} unique context buckets")

    # ==================================================================
    # COMPOSE: Regime × Context → Directional Bias
    # ==================================================================
    log(f"\n--- COMPOSING SIGNALS ---")

    # Build bias table from supervised data
    # Key: (regime_state, context_bucket) → list of labels
    bias_table: Dict[Tuple[str, str], List[str]] = defaultdict(list)
    for idx in sup_sample:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        rs = regime_state(idx)
        ctx = contexts[idx]
        bias_table[(rs, ctx)].append(lbl)

    # Analyze bias table
    actionable_buckets = []
    total_buckets = 0
    for (rs, ctx), lbls in sorted(bias_table.items()):
        if len(lbls) < args.min_bucket:
            continue
        total_buckets += 1
        buy_pct = sum(1 for l in lbls if l == "BUY") / len(lbls)
        sell_pct = 1 - buy_pct
        bias = max(buy_pct, sell_pct)
        direction = "BUY" if buy_pct > sell_pct else "SELL"
        if bias >= args.bias_threshold:
            actionable_buckets.append((rs, ctx, direction, bias, len(lbls)))

    log(f"  Total buckets with >= {args.min_bucket} samples: {total_buckets}")
    log(f"  Actionable (bias >= {args.bias_threshold:.0%}): {len(actionable_buckets)}")

    if actionable_buckets:
        actionable_buckets.sort(key=lambda x: -x[3])
        log(f"\n  Top actionable regime×context combinations:")
        log(f"  {'Regime':<12} {'Context':<50} {'Dir':<5} {'Bias':>6} {'N':>5}")
        log(f"  {'-'*12} {'-'*50} {'-'*5} {'-'*6} {'-'*5}")
        for rs, ctx, direction, bias, count in actionable_buckets[:30]:
            log(f"  {rs:<12} {ctx:<50} {direction:<5} {bias:5.1%} {count:5d}")

    # ==================================================================
    # TEST: Apply composed strategy
    # ==================================================================
    log(f"\n--- TESTING COMPOSED STRATEGY ---")

    # Build actionable lookup
    action_lookup: Dict[Tuple[str, str], str] = {}
    for rs, ctx, direction, bias, count in actionable_buckets:
        action_lookup[(rs, ctx)] = direction

    for split_name, indices, is_supervised in [
        ("IN-SAMPLE (2019-2020)", sup_sample, True),
        ("OOS (2021+)", adp_sample, False),
    ]:
        correct = wrong = skipped = 0
        by_year: Dict[int, List[bool]] = defaultdict(list)

        for idx in indices:
            actual = labels.get(idx)
            if actual not in ("BUY", "SELL"):
                skipped += 1
                continue

            rs = regime_state(idx)
            ctx = contexts[idx]
            key = (rs, ctx)

            if key not in action_lookup:
                skipped += 1
                continue

            pred = action_lookup[key]
            is_correct = pred == actual
            if is_correct:
                correct += 1
            else:
                wrong += 1
            year = candles[idx].get("year")
            by_year[year].append(is_correct)

        total = correct + wrong
        acc = correct / total * 100 if total > 0 else 0
        coverage = total / (total + skipped) * 100 if (total + skipped) > 0 else 0

        log(f"\n  {split_name}:")
        log(f"    Accuracy:  {acc:.1f}% ({correct}/{total})")
        log(f"    Coverage:  {coverage:.1f}% ({total} traded, {skipped} skipped)")
        log(f"    Precision: only trade when we have a biased bucket")

        for year in sorted(by_year.keys()):
            yr = by_year[year]
            yr_acc = sum(yr) / len(yr) * 100 if yr else 0
            marker = " *" if year in SUPERVISED_YEARS else ""
            log(f"    {year}: {yr_acc:5.1f}% ({len(yr):,} trades){marker}")

    # ==================================================================
    # BASELINE: Context-only (no regime signal)
    # ==================================================================
    log(f"\n--- BASELINE: CONTEXT-ONLY (no regime) ---")

    ctx_only_table: Dict[str, List[str]] = defaultdict(list)
    for idx in sup_sample:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        ctx = contexts[idx]
        ctx_only_table[ctx].append(lbl)

    ctx_action: Dict[str, str] = {}
    for ctx, lbls in ctx_only_table.items():
        if len(lbls) < args.min_bucket:
            continue
        buy_pct = sum(1 for l in lbls if l == "BUY") / len(lbls)
        bias = max(buy_pct, 1 - buy_pct)
        if bias >= args.bias_threshold:
            ctx_action[ctx] = "BUY" if buy_pct > 0.5 else "SELL"

    log(f"  Actionable context buckets (no regime): {len(ctx_action)}")

    for split_name, indices in [("IN-SAMPLE", sup_sample),
                                 ("OOS", adp_sample)]:
        correct = wrong = skipped = 0
        for idx in indices:
            actual = labels.get(idx)
            if actual not in ("BUY", "SELL"):
                skipped += 1
                continue
            ctx = contexts[idx]
            if ctx not in ctx_action:
                skipped += 1
                continue
            pred = ctx_action[ctx]
            if pred == actual:
                correct += 1
            else:
                wrong += 1
        total = correct + wrong
        acc = correct / total * 100 if total > 0 else 0
        coverage = total / (total + skipped) * 100 if (total + skipped) > 0 else 0
        log(f"  {split_name}: {acc:.1f}% ({correct}/{total}), "
            f"coverage {coverage:.1f}%")

    # ==================================================================
    # BASELINE: Regime-only (no context)
    # ==================================================================
    log(f"\n--- BASELINE: REGIME-ONLY (no context) ---")

    regime_only_table: Dict[str, List[str]] = defaultdict(list)
    for idx in sup_sample:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        rs = regime_state(idx)
        regime_only_table[rs].append(lbl)

    log(f"  Regime state distribution:")
    for rs in sorted(regime_only_table.keys()):
        lbls = regime_only_table[rs]
        buy_pct = sum(1 for l in lbls if l == "BUY") / len(lbls)
        log(f"    {rs:<12}: {len(lbls):,} samples, "
            f"BUY={buy_pct:.1%}, SELL={1-buy_pct:.1%}")


if __name__ == "__main__":
    main()
