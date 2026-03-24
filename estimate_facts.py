"""
Estimate segment fact count for the proposed PELT-based thought encoding.
Runs PELT on 15 indicator streams over 48-candle windows, counts segments + zone facts.
No vector ops — just counting.
"""
import sqlite3
import numpy as np
import sys

DB_PATH = "data/analysis.db"
WINDOW = 48
SAMPLE_STEP = 10  # check every Nth candle to speed up


def pelt_changepoints(values, penalty):
    """PELT change-point detection on raw scalar values."""
    n = len(values)
    if n < 3:
        return []

    cum_sum = np.zeros(n + 1)
    cum_sq = np.zeros(n + 1)
    for i in range(n):
        cum_sum[i + 1] = cum_sum[i] + values[i]
        cum_sq[i + 1] = cum_sq[i] + values[i] ** 2

    def seg_cost(s, t):
        length = t - s
        if length < 1:
            return 0.0
        sm = cum_sum[t] - cum_sum[s]
        sq = cum_sq[t] - cum_sq[s]
        return sq - sm * sm / length

    best_cost = np.full(n + 1, np.inf)
    best_cost[0] = 0.0
    last_change = np.zeros(n + 1, dtype=int)
    candidates = [0]

    for t in range(1, n + 1):
        best = np.inf
        best_s = 0
        for s in candidates:
            cost = best_cost[s] + seg_cost(s, t) + penalty
            if cost < best:
                best = cost
                best_s = s
        best_cost[t] = best
        last_change[t] = best_s

        candidates = [s for s in candidates
                      if best_cost[s] + seg_cost(s, t) <= best_cost[t] + penalty]
        candidates.append(t)

    cps = []
    t = n
    while t > 0:
        s = last_change[t]
        if s > 0:
            cps.append(s)
        t = s
    cps.reverse()
    return cps


def bic_penalty(values):
    """BIC-derived penalty: 2 * variance * log(n)"""
    n = len(values)
    if n < 2:
        return 1e10
    mean = np.mean(values)
    var = np.var(values)
    if var < 1e-20:
        return 1e10
    return 2.0 * var * np.log(n)


ZONE_CHECKS = {
    "rsi": [
        ("rsi-overbought", lambda c: c["rsi"] > 70),
        ("rsi-oversold",   lambda c: c["rsi"] < 30),
        ("rsi-above-mid",  lambda c: c["rsi"] > 50),
        ("rsi-below-mid",  lambda c: c["rsi"] <= 50),
    ],
    "adx": [
        ("adx-strong", lambda c: c["adx"] > 25),
        ("adx-weak",   lambda c: c["adx"] < 20),
    ],
    "dmi_plus": [
        ("dmi-plus-strong", lambda c: c["dmi_plus"] > 25),
        ("dmi-plus-weak",   lambda c: c["dmi_plus"] < 20),
    ],
    "dmi_minus": [
        ("dmi-minus-strong", lambda c: c["dmi_minus"] > 25),
        ("dmi-minus-weak",   lambda c: c["dmi_minus"] < 20),
    ],
    "macd_line": [
        ("macd-positive", lambda c: c["macd_line"] > 0),
        ("macd-negative", lambda c: c["macd_line"] <= 0),
    ],
    "macd_hist": [
        ("macd-hist-positive", lambda c: c["macd_hist"] > 0),
        ("macd-hist-negative", lambda c: c["macd_hist"] <= 0),
    ],
}

STREAMS = [
    ("close", lambda c: np.log(max(c["close"], 1))),
    ("sma20", lambda c: np.log(max(c["sma20"], 1)) if c["sma20"] > 0 else None),
    ("sma50", lambda c: np.log(max(c["sma50"], 1)) if c["sma50"] > 0 else None),
    ("sma200", lambda c: np.log(max(c["sma200"], 1)) if c["sma200"] > 0 else None),
    ("bb_upper", lambda c: np.log(max(c["bb_upper"], 1)) if c["bb_upper"] > 0 else None),
    ("bb_lower", lambda c: np.log(max(c["bb_lower"], 1)) if c["bb_lower"] > 0 else None),
    ("volume", lambda c: np.log(max(c["volume"], 1))),
    ("rsi", lambda c: c["rsi"]),
    ("rsi_sma", None),  # computed from rolling RSI
    ("macd_line", lambda c: c["macd_line"]),
    ("macd_signal", lambda c: c["macd_signal"]),
    ("macd_hist", lambda c: c["macd_hist"]),
    ("dmi_plus", lambda c: c["dmi_plus"]),
    ("dmi_minus", lambda c: c["dmi_minus"]),
    ("adx", lambda c: c["adx"]),
    ("body", lambda c: c["close"] - c["open"]),
    ("range", lambda c: c["high"] - c["low"]),
]


def load_candles(db_path, limit=50000):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.execute("""
        SELECT close, open, high, low, volume,
               sma20, sma50, sma200,
               bb_upper, bb_lower,
               rsi, macd_line, macd_signal, macd_hist,
               dmi_plus, dmi_minus, adx
        FROM candles
        WHERE sma200 > 0 AND rsi IS NOT NULL
        LIMIT ?
    """, (limit,))
    rows = [dict(r) for r in cur.fetchall()]
    conn.close()
    return rows


def compute_rsi_sma(candles, idx, lookback=14):
    start = max(0, idx - lookback + 1)
    window = candles[start:idx + 1]
    if not window:
        return None
    return np.mean([c["rsi"] for c in window])


def count_facts_for_window(candles, start_idx):
    window = candles[start_idx:start_idx + WINDOW]
    if len(window) < WINDOW:
        return None

    total_segment_facts = 0
    total_zone_facts = 0
    stream_details = {}

    for stream_name, extractor in STREAMS:
        if stream_name == "rsi_sma":
            values = []
            for i in range(WINDOW):
                v = compute_rsi_sma(candles, start_idx + i)
                values.append(v)
        else:
            values = [extractor(c) for c in window]

        # Filter None values
        clean_values = [v for v in values if v is not None]
        if len(clean_values) < 5:
            continue

        arr = np.array(clean_values, dtype=float)
        if np.any(np.isnan(arr)) or np.any(np.isinf(arr)):
            arr = arr[np.isfinite(arr)]
            if len(arr) < 5:
                continue

        penalty = bic_penalty(arr)
        cps = pelt_changepoints(arr, penalty)

        n_segments = len(cps) + 1
        total_segment_facts += n_segments

        # Zone facts: only check zones relevant to this stream
        checks = ZONE_CHECKS.get(stream_name, [])
        if checks:
            boundaries = [0] + cps + [len(arr)]
            for seg_i in range(n_segments):
                seg_start = boundaries[seg_i]
                seg_end = boundaries[seg_i + 1] - 1
                begin_candle = window[min(seg_start, len(window) - 1)]
                end_candle = window[min(seg_end, len(window) - 1)]
                for _, check in checks:
                    try:
                        if check(begin_candle):
                            total_zone_facts += 1
                        if check(end_candle):
                            total_zone_facts += 1
                    except:
                        pass

        stream_details[stream_name] = n_segments

    return {
        "segment_facts": total_segment_facts,
        "zone_facts": total_zone_facts,
        "total": total_segment_facts + total_zone_facts,
        "streams": stream_details,
    }


def main():
    print(f"Loading candles from {DB_PATH}...")
    candles = load_candles(DB_PATH, limit=60000)
    print(f"Loaded {len(candles)} candles")

    results = []
    n_samples = 0

    for start_idx in range(WINDOW, len(candles) - WINDOW, SAMPLE_STEP):
        result = count_facts_for_window(candles, start_idx)
        if result:
            results.append(result)
            n_samples += 1

    if not results:
        print("No valid windows found!")
        return

    seg_counts = [r["segment_facts"] for r in results]
    zone_counts = [r["zone_facts"] for r in results]
    total_counts = [r["total"] for r in results]

    print(f"\n{'='*60}")
    print(f"PELT Fact Count Estimation ({n_samples} windows, {WINDOW}-candle viewport)")
    print(f"{'='*60}")

    print(f"\nSegment facts (direction + magnitude + duration per segment):")
    print(f"  Mean:   {np.mean(seg_counts):.1f}")
    print(f"  Median: {np.median(seg_counts):.1f}")
    print(f"  Min:    {np.min(seg_counts)}")
    print(f"  Max:    {np.max(seg_counts)}")
    print(f"  P25:    {np.percentile(seg_counts, 25):.1f}")
    print(f"  P75:    {np.percentile(seg_counts, 75):.1f}")
    print(f"  P95:    {np.percentile(seg_counts, 95):.1f}")

    print(f"\nZone-at-boundary facts:")
    print(f"  Mean:   {np.mean(zone_counts):.1f}")
    print(f"  Median: {np.median(zone_counts):.1f}")
    print(f"  P95:    {np.percentile(zone_counts, 95):.1f}")

    print(f"\nTotal new facts (segment + zone):")
    print(f"  Mean:   {np.mean(total_counts):.1f}")
    print(f"  Median: {np.median(total_counts):.1f}")
    print(f"  P95:    {np.percentile(total_counts, 95):.1f}")
    print(f"  Max:    {np.max(total_counts)}")

    # Per-stream breakdown
    print(f"\nPer-stream segment counts (mean):")
    stream_names = list(results[0]["streams"].keys())
    for name in sorted(stream_names):
        vals = [r["streams"].get(name, 0) for r in results]
        print(f"  {name:15s}: {np.mean(vals):.1f} segments (range {np.min(vals)}-{np.max(vals)})")

    # Existing fact count estimate (comparisons + temporal)
    est_existing = 30  # rough: ~30 comparison/temporal facts remain
    print(f"\nEstimated existing facts (comparisons, temporal): ~{est_existing}")
    print(f"Estimated TOTAL facts per thought: ~{np.mean(total_counts) + est_existing:.0f}")
    print(f"Capacity threshold sqrt(10000): 100")

    # Distribution histogram
    print(f"\nTotal fact distribution:")
    for bucket in [25, 50, 75, 100, 125, 150, 175, 200, 250, 300]:
        count = sum(1 for t in total_counts if t <= bucket)
        pct = count / len(total_counts) * 100
        bar = "#" * int(pct / 2)
        print(f"  <={bucket:3d}: {pct:5.1f}% {bar}")


if __name__ == "__main__":
    main()
