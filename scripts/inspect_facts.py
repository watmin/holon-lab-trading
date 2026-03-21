"""Inspect categorical encodings side-by-side for BUY vs SELL.

Pull specific BUY and SELL examples, show their full fact sets,
diff them, and measure encoded vector similarity.
"""

from __future__ import annotations

import sqlite3
import sys
import time
from pathlib import Path
from typing import Dict, Set

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    LinearScale,
    cosine_similarity,
    difference,
    reject,
    amplify,
    negate,
    resonance,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

ALL_DB_COLS = [
    "ts", "year", "close", "open", "high", "low", "volume",
    "sma20", "sma50", "sma200",
    "bb_upper", "bb_lower",
    "rsi",
    "macd_line", "macd_signal", "macd_hist",
    "dmi_plus", "dmi_minus", "adx",
    "atr_r", "label_oracle_10",
]


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# Import the categorical encoding from categorical_refine
sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import (
    candle_facts,
    build_categorical_data,
)


def flatten_facts(facts: dict) -> Dict[str, str]:
    """Flatten a facts dict into {key: value_str} for easy comparison."""
    flat = {}
    for k, v in sorted(facts.items()):
        if isinstance(v, set):
            for item in sorted(v):
                flat[f"{k}.{item}"] = "true"
        else:
            flat[k] = str(v)
    return flat


def main():
    log("=" * 80)
    log("FACT INSPECTION: BUY vs SELL side-by-side")
    log("=" * 80)

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
    log(f"Loaded {len(candles):,} candles")

    window = 48

    # Find first 5 BUY and 5 SELL in supervised years with oracle labels
    buys, sells = [], []
    for i in range(window - 1, len(candles)):
        if len(buys) >= 5 and len(sells) >= 5:
            break
        year = candles[i].get("year")
        if year not in (2019, 2020):
            continue
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= 0.002:
            continue
        label = candles[i].get("label_oracle_10")
        if label == "BUY" and len(buys) < 5:
            buys.append(i)
        elif label == "SELL" and len(sells) < 5:
            sells.append(i)

    dim = 1024
    n_stripes = 16
    encoder = Encoder(DeterministicVectorManager(dimensions=dim))

    # ================================================================
    # Part 1: Show fact sets and diff them
    # ================================================================
    log(f"\n{'='*80}")
    log("PART 1: FACT COMPARISON (last 3 candles of window)")
    log(f"{'='*80}")

    for pair_idx in range(min(5, len(buys), len(sells))):
        bi, si = buys[pair_idx], sells[pair_idx]
        buy_data = build_categorical_data(candles, bi, window)
        sell_data = build_categorical_data(candles, si, window)

        log(f"\n--- Pair {pair_idx + 1}: BUY idx={bi} vs SELL idx={si} ---")
        log(f"  BUY close=${sf(candles[bi].get('close')):.2f}  "
            f"SELL close=${sf(candles[si].get('close')):.2f}")

        for t in [window - 3, window - 2, window - 1]:
            t_key = f"t{t}"
            buy_facts = flatten_facts(buy_data.get(t_key, {}))
            sell_facts = flatten_facts(sell_data.get(t_key, {}))
            all_keys = sorted(set(buy_facts.keys()) | set(sell_facts.keys()))

            log(f"\n  [{t_key}]")
            log(f"  {'Fact':<40} {'BUY':<20} {'SELL':<20} {'Match':>5}")
            log(f"  {'-'*40} {'-'*20} {'-'*20} {'-'*5}")

            matches = 0
            diffs = 0
            for key in all_keys:
                bv = buy_facts.get(key, "---")
                sv = sell_facts.get(key, "---")
                match = "  =  " if bv == sv else " DIFF"
                if bv == sv:
                    matches += 1
                else:
                    diffs += 1
                log(f"  {key:<40} {bv:<20} {sv:<20} {match}")

            log(f"  Matches: {matches}, Differences: {diffs}")

    # ================================================================
    # Part 2: Aggregate fact frequencies for BUY vs SELL
    # ================================================================
    log(f"\n{'='*80}")
    log("PART 2: FACT FREQUENCY ANALYSIS (500 BUY vs 500 SELL)")
    log(f"{'='*80}")

    np.random.seed(42)
    all_buy_idx, all_sell_idx = [], []
    for i in range(window - 1, len(candles)):
        year = candles[i].get("year")
        if year not in (2019, 2020):
            continue
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= 0.002:
            continue
        label = candles[i].get("label_oracle_10")
        if label == "BUY":
            all_buy_idx.append(i)
        elif label == "SELL":
            all_sell_idx.append(i)

    n_sample = 500
    buy_sample = np.random.choice(all_buy_idx, size=min(n_sample, len(all_buy_idx)),
                                   replace=False).tolist()
    sell_sample = np.random.choice(all_sell_idx, size=min(n_sample, len(all_sell_idx)),
                                    replace=False).tolist()

    t_last = f"t{window - 1}"

    buy_fact_counts: Dict[str, int] = {}
    sell_fact_counts: Dict[str, int] = {}

    for idx in buy_sample:
        data = build_categorical_data(candles, idx, window)
        if t_last in data:
            for k, v in flatten_facts(data[t_last]).items():
                key = f"{k}={v}"
                buy_fact_counts[key] = buy_fact_counts.get(key, 0) + 1

    for idx in sell_sample:
        data = build_categorical_data(candles, idx, window)
        if t_last in data:
            for k, v in flatten_facts(data[t_last]).items():
                key = f"{k}={v}"
                sell_fact_counts[key] = sell_fact_counts.get(key, 0) + 1

    all_facts = sorted(set(buy_fact_counts.keys()) | set(sell_fact_counts.keys()))

    log(f"\n  Newest candle ({t_last}) fact frequencies "
        f"({len(buy_sample)} BUY, {len(sell_sample)} SELL):")
    log(f"\n  {'Fact':<55} {'BUY%':>7} {'SELL%':>7} {'Gap':>7} {'|Gap|':>7}")
    log(f"  {'-'*55} {'-'*7} {'-'*7} {'-'*7} {'-'*7}")

    rows = []
    for fact in all_facts:
        bc = buy_fact_counts.get(fact, 0)
        sc = sell_fact_counts.get(fact, 0)
        bp = bc / len(buy_sample) * 100
        sp = sc / len(sell_sample) * 100
        gap = bp - sp
        rows.append((fact, bp, sp, gap, abs(gap)))

    rows.sort(key=lambda x: -x[4])
    for fact, bp, sp, gap, agap in rows:
        log(f"  {fact:<55} {bp:6.1f}% {sp:6.1f}% {gap:+6.1f}% {agap:6.1f}%")

    # ================================================================
    # Part 3: Holon algebra on encoded pairs
    # ================================================================
    log(f"\n{'='*80}")
    log("PART 3: ENCODED VECTOR ANALYSIS (Holon algebra)")
    log(f"{'='*80}")

    buy_vecs, sell_vecs = [], []
    for idx in buy_sample[:200]:
        data = build_categorical_data(candles, idx, window)
        stripes = encoder.encode_walkable_striped(data, n_stripes)
        buy_vecs.append(np.stack(stripes))
    for idx in sell_sample[:200]:
        data = build_categorical_data(candles, idx, window)
        stripes = encoder.encode_walkable_striped(data, n_stripes)
        sell_vecs.append(np.stack(stripes))

    buy_arr = np.stack(buy_vecs).astype(np.float64)  # (200, 16, 1024)
    sell_arr = np.stack(sell_vecs).astype(np.float64)

    buy_mean = buy_arr.mean(axis=0)  # (16, 1024)
    sell_mean = sell_arr.mean(axis=0)

    log(f"\n  Per-stripe cosine(buy_mean, sell_mean):")
    for s in range(n_stripes):
        cos = cosine_similarity(buy_mean[s], sell_mean[s])
        log(f"    Stripe {s:2d}: {cos:.4f}")

    # Now try algebra: reject shared structure per-stripe
    log(f"\n  Algebra: reject(buy_mean, [market]) per stripe")
    for s in range(n_stripes):
        market = (buy_mean[s] + sell_mean[s]) / 2.0
        bu = reject(buy_mean[s], [market])
        su = reject(sell_mean[s], [market])
        cos_unique = cosine_similarity(bu, su)
        log(f"    Stripe {s:2d}: cosine(unique_buy, unique_sell) = {cos_unique:.4f}  "
            f"buy_unique_norm={np.linalg.norm(bu):.2f}  "
            f"sell_unique_norm={np.linalg.norm(su):.2f}")

    # Individual sample similarity to class means
    log(f"\n  Individual sample → class mean cosine (first 10 BUY, 10 SELL):")
    log(f"  {'Sample':<10} {'Label':<6} {'cos(→buy_mean)':>16} {'cos(→sell_mean)':>16} "
        f"{'Correct?':>9}")
    hits = 0
    total = 0
    for i in range(10):
        for label, arr, idx_list in [("BUY", buy_arr, buy_sample),
                                      ("SELL", sell_arr, sell_sample)]:
            vec = arr[i]
            cos_buy = np.mean([cosine_similarity(vec[s], buy_mean[s])
                               for s in range(n_stripes)])
            cos_sell = np.mean([cosine_similarity(vec[s], sell_mean[s])
                                for s in range(n_stripes)])
            pred = "BUY" if cos_buy > cos_sell else "SELL"
            correct = pred == label
            hits += int(correct)
            total += 1
            log(f"  {idx_list[i]:<10} {label:<6} {cos_buy:16.6f} {cos_sell:16.6f} "
                f"{'  YES' if correct else '  NO':>9}")
    log(f"\n  Quick accuracy: {hits}/{total} = {hits/total*100:.1f}%")

    # ================================================================
    # Part 4: What facts differ between BUY and SELL?
    # ================================================================
    log(f"\n{'='*80}")
    log("PART 4: FACT TRANSITION ANALYSIS (across window)")
    log(f"{'='*80}")
    log("  How often does each fact CHANGE within the 48-candle window?")

    buy_change_counts: Dict[str, float] = {}
    sell_change_counts: Dict[str, float] = {}

    for label, sample, counts in [("BUY", buy_sample[:200], buy_change_counts),
                                    ("SELL", sell_sample[:200], sell_change_counts)]:
        for idx in sample:
            data = build_categorical_data(candles, idx, window)
            prev_facts = None
            transitions = 0
            for t in range(window):
                t_key = f"t{t}"
                if t_key not in data:
                    continue
                curr_facts = flatten_facts(data[t_key])
                if prev_facts is not None:
                    all_keys = set(prev_facts.keys()) | set(curr_facts.keys())
                    for k in all_keys:
                        if prev_facts.get(k) != curr_facts.get(k):
                            counts[k] = counts.get(k, 0) + 1
                            transitions += 1
                prev_facts = curr_facts
            counts["__total_transitions__"] = counts.get("__total_transitions__", 0) + transitions

    all_change_keys = sorted(
        (set(buy_change_counts.keys()) | set(sell_change_counts.keys()))
        - {"__total_transitions__"}
    )

    log(f"\n  Avg transitions per window: "
        f"BUY={buy_change_counts.get('__total_transitions__', 0)/200:.1f}  "
        f"SELL={sell_change_counts.get('__total_transitions__', 0)/200:.1f}")

    log(f"\n  {'Fact':<45} {'BUY chg':>9} {'SELL chg':>9} {'Gap':>9}")
    log(f"  {'-'*45} {'-'*9} {'-'*9} {'-'*9}")

    change_rows = []
    for k in all_change_keys:
        bc = buy_change_counts.get(k, 0) / 200
        sc = sell_change_counts.get(k, 0) / 200
        gap = bc - sc
        change_rows.append((k, bc, sc, gap, abs(gap)))

    change_rows.sort(key=lambda x: -x[4])
    for k, bc, sc, gap, agap in change_rows[:30]:
        log(f"  {k:<45} {bc:8.2f} {sc:8.2f} {gap:+8.2f}")


if __name__ == "__main__":
    main()
