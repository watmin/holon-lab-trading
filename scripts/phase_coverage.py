"""
How much of the candle stream is covered by 3+ higher low / lower high streaks?
How long do the entry conditions last?
"""

import sqlite3
import sys

DB = "data/analysis.db"
MAX_CANDLES = int(sys.argv[1]) if len(sys.argv) > 1 else 652000
SMOOTHING_MULT = 2.0

conn = sqlite3.connect(DB)
rows = conn.execute(
    "SELECT ts, close, atr FROM candles ORDER BY ts LIMIT ?",
    (MAX_CANDLES,)
).fetchall()
conn.close()

print(f"Loaded {len(rows)} candles")

# Build phase history
phase = None
extreme = None
phase_start = 0
completed = []

for i, (ts, close, atr) in enumerate(rows):
    if atr is None or atr < 0.01:
        continue
    smoothing = atr * SMOOTHING_MULT

    if phase is None:
        phase = 'rising'
        extreme = close
        phase_start = i
        continue

    if phase == 'rising':
        if close < extreme:
            extreme = close
        if close > extreme + smoothing:
            completed.append({'type': 'rising', 'extreme': extreme, 'start': phase_start, 'end': i})
            phase = 'falling'
            extreme = close
            phase_start = i
    elif phase == 'falling':
        if close > extreme:
            extreme = close
        if close < extreme - smoothing:
            completed.append({'type': 'falling', 'extreme': extreme, 'start': phase_start, 'end': i})
            phase = 'rising'
            extreme = close
            phase_start = i

rising = [p for p in completed if p['type'] == 'rising']
falling = [p for p in completed if p['type'] == 'falling']

# For each rising phase, track the consecutive higher-low count
# When count reaches 3, the BUY condition is active from that phase onward
# until the streak breaks (a lower low)
buy_candles = set()
streak = 0
streak_start_phase = 0
for i in range(len(rising)):
    if i > 0 and rising[i]['extreme'] > rising[i-1]['extreme']:
        streak += 1
    else:
        streak = 0
        streak_start_phase = i

    if streak >= 2:  # 3rd higher low or more — condition is active
        # The buy condition is active during this rising phase
        # AND the falling phase that follows (we're buying during the dip too)
        for c in range(rising[i]['start'], rising[i]['end'] + 1):
            buy_candles.add(c)
        # Also the next falling phase (if exists) — the condition persists
        # until the streak breaks
        idx_in_completed = completed.index(rising[i])
        if idx_in_completed + 1 < len(completed):
            nxt = completed[idx_in_completed + 1]
            for c in range(nxt['start'], nxt['end'] + 1):
                buy_candles.add(c)

# Same for sell
sell_candles = set()
streak = 0
for i in range(len(falling)):
    if i > 0 and falling[i]['extreme'] < falling[i-1]['extreme']:
        streak += 1
    else:
        streak = 0

    if streak >= 2:
        for c in range(falling[i]['start'], falling[i]['end'] + 1):
            sell_candles.add(c)
        idx_in_completed = completed.index(falling[i])
        if idx_in_completed + 1 < len(completed):
            nxt = completed[idx_in_completed + 1]
            for c in range(nxt['start'], nxt['end'] + 1):
                sell_candles.add(c)

total = len(rows)
both = buy_candles & sell_candles
either = buy_candles | sell_candles
neither = total - len(either)

print(f"\n=== COVERAGE ===")
print(f"Total candles:       {total}")
print(f"Buy condition:       {len(buy_candles)} candles ({len(buy_candles)/total*100:.1f}%)")
print(f"Sell condition:      {len(sell_candles)} candles ({len(sell_candles)/total*100:.1f}%)")
print(f"Either:              {len(either)} candles ({len(either)/total*100:.1f}%)")
print(f"Both simultaneously: {len(both)} candles ({len(both)/total*100:.1f}%)")
print(f"Neither (idle):      {neither} candles ({neither/total*100:.1f}%)")

# How long do the conditions last? Measure continuous runs
def measure_runs(candle_set, total_candles):
    sorted_c = sorted(candle_set)
    if not sorted_c:
        return []
    runs = []
    start = sorted_c[0]
    prev = sorted_c[0]
    for c in sorted_c[1:]:
        if c == prev + 1:
            prev = c
        else:
            runs.append(prev - start + 1)
            start = c
            prev = c
    runs.append(prev - start + 1)
    return runs

buy_runs = measure_runs(buy_candles, total)
sell_runs = measure_runs(sell_candles, total)

print(f"\n=== BUY CONDITION DURATIONS ===")
print(f"  Continuous runs: {len(buy_runs)}")
if buy_runs:
    print(f"  Avg duration:    {sum(buy_runs)/len(buy_runs):.0f} candles ({sum(buy_runs)/len(buy_runs)*5/60:.1f} hours)")
    print(f"  Median:          {sorted(buy_runs)[len(buy_runs)//2]} candles")
    print(f"  Max:             {max(buy_runs)} candles ({max(buy_runs)*5/60:.1f} hours)")
    print(f"  Min:             {min(buy_runs)} candles")

print(f"\n=== SELL CONDITION DURATIONS ===")
print(f"  Continuous runs: {len(sell_runs)}")
if sell_runs:
    print(f"  Avg duration:    {sum(sell_runs)/len(sell_runs):.0f} candles ({sum(sell_runs)/len(sell_runs)*5/60:.1f} hours)")
    print(f"  Median:          {sorted(sell_runs)[len(sell_runs)//2]} candles")
    print(f"  Max:             {max(sell_runs)} candles ({max(sell_runs)*5/60:.1f} hours)")
    print(f"  Min:             {min(sell_runs)} candles")
