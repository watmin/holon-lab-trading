"""
Count how often we see three consecutive higher lows or lower highs
in the phase labeler output.

Phase labeler: 2.0 ATR smoothing. Rising tracks lows. Falling tracks highs.
Each phase has an extreme (the low during Rising, the high during Falling).
When a phase completes (transition), we record its extreme.

Three consecutive Rising phases with each low higher than the last =
three higher lows in a row. That's the buy signal.

Three consecutive Falling phases with each high lower than the last =
three lower highs in a row. That's the sell signal.
"""

import sqlite3
import sys

DB = "data/analysis.db"
MAX_CANDLES = int(sys.argv[1]) if len(sys.argv) > 1 else 652000

conn = sqlite3.connect(DB)
rows = conn.execute(
    "SELECT ts, close, high, low, atr FROM candles ORDER BY ts LIMIT ?",
    (MAX_CANDLES,)
).fetchall()
conn.close()

print(f"Loaded {len(rows)} candles")

SMOOTHING_MULT = 2.0

phase = None
extreme = None
phase_start = 0

# Record completed phases with their extremes
completed_phases = []

for i, (ts, close, high, low, atr) in enumerate(rows):
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
            # Transition: rising complete. Record the low.
            completed_phases.append({
                'type': 'rising',
                'extreme': extreme,  # the low
                'start': phase_start,
                'end': i,
                'duration': i - phase_start,
                'ts': ts,
            })
            phase = 'falling'
            extreme = close
            phase_start = i

    elif phase == 'falling':
        if close > extreme:
            extreme = close
        if close < extreme - smoothing:
            # Transition: falling complete. Record the high.
            completed_phases.append({
                'type': 'falling',
                'extreme': extreme,  # the high
                'start': phase_start,
                'end': i,
                'duration': i - phase_start,
                'ts': ts,
            })
            phase = 'rising'
            extreme = close
            phase_start = i

print(f"Completed phases: {len(completed_phases)}")
rising = [p for p in completed_phases if p['type'] == 'rising']
falling = [p for p in completed_phases if p['type'] == 'falling']
print(f"  Rising (lows recorded): {len(rising)}")
print(f"  Falling (highs recorded): {len(falling)}")

# Check for consecutive higher lows (rising phases)
higher_low_streaks = []
streak = 0
for i in range(1, len(rising)):
    if rising[i]['extreme'] > rising[i-1]['extreme']:
        streak += 1
    else:
        if streak >= 2:  # 3 higher lows = streak of 2 (comparisons)
            higher_low_streaks.append({
                'length': streak + 1,
                'end_idx': i - 1,
                'end_ts': rising[i-1]['ts'],
                'lows': [rising[j]['extreme'] for j in range(i - streak - 1, i)],
            })
        streak = 0

# Catch trailing streak
if streak >= 2:
    higher_low_streaks.append({
        'length': streak + 1,
        'end_idx': len(rising) - 1,
        'end_ts': rising[-1]['ts'],
        'lows': [rising[j]['extreme'] for j in range(len(rising) - streak - 1, len(rising))],
    })

# Check for consecutive lower highs (falling phases)
lower_high_streaks = []
streak = 0
for i in range(1, len(falling)):
    if falling[i]['extreme'] < falling[i-1]['extreme']:
        streak += 1
    else:
        if streak >= 2:
            lower_high_streaks.append({
                'length': streak + 1,
                'end_idx': i - 1,
                'end_ts': falling[i-1]['ts'],
                'highs': [falling[j]['extreme'] for j in range(i - streak - 1, i)],
            })
        streak = 0

if streak >= 2:
    lower_high_streaks.append({
        'length': streak + 1,
        'end_idx': len(falling) - 1,
        'end_ts': falling[-1]['ts'],
        'highs': [falling[j]['extreme'] for j in range(len(falling) - streak - 1, len(falling))],
    })

print(f"\n=== HIGHER LOW STREAKS (3+ consecutive) — BUY SIGNALS ===")
print(f"Total streaks: {len(higher_low_streaks)}")
if higher_low_streaks:
    lengths = [s['length'] for s in higher_low_streaks]
    print(f"  Length distribution:")
    for l in sorted(set(lengths)):
        c = lengths.count(l)
        print(f"    {l} higher lows in a row: {c} times")
    print(f"\n  First 5 examples:")
    for s in higher_low_streaks[:5]:
        lows_str = " → ".join(f"${l:.1f}" for l in s['lows'])
        print(f"    {s['length']} lows: {lows_str} (ended {s['end_ts']})")

print(f"\n=== LOWER HIGH STREAKS (3+ consecutive) — SELL SIGNALS ===")
print(f"Total streaks: {len(lower_high_streaks)}")
if lower_high_streaks:
    lengths = [s['length'] for s in lower_high_streaks]
    print(f"  Length distribution:")
    for l in sorted(set(lengths)):
        c = lengths.count(l)
        print(f"    {l} lower highs in a row: {c} times")
    print(f"\n  First 5 examples:")
    for s in lower_high_streaks[:5]:
        highs_str = " → ".join(f"${h:.1f}" for h in s['highs'])
        print(f"    {s['length']} highs: {highs_str} (ended {s['end_ts']})")

# Also count 2s for context
hl2 = 0
lh2 = 0
for i in range(1, len(rising)):
    if rising[i]['extreme'] > rising[i-1]['extreme']:
        hl2 += 1
for i in range(1, len(falling)):
    if falling[i]['extreme'] < falling[i-1]['extreme']:
        lh2 += 1

print(f"\n=== CONTEXT ===")
print(f"Any higher low (2 consecutive rising): {hl2} / {len(rising)-1} ({hl2/(len(rising)-1)*100:.1f}%)")
print(f"Any lower high (2 consecutive falling): {lh2} / {len(falling)-1} ({lh2/(len(falling)-1)*100:.1f}%)")
print(f"Avg rising phase duration: {sum(p['duration'] for p in rising)/len(rising):.0f} candles")
print(f"Avg falling phase duration: {sum(p['duration'] for p in falling)/len(falling):.0f} candles")
