"""
Simulate phase-transition exits on BTC 5-minute candles.

Phase labeler: 2.0 ATR smoothing. Two states: Rising, Falling.
- Rising -> Falling = exit long, enter short
- Falling -> Rising = exit short, enter long

Each trade lives from one transition to the next.
No distances. No triggers. Just phase transitions.

Measure: residue per trade, win rate, hold duration.
"""

import sqlite3
import sys

DB = "data/analysis.db"
SMOOTHING_MULT = 2.0
MAX_CANDLES = int(sys.argv[1]) if len(sys.argv) > 1 else 100000

conn = sqlite3.connect(DB)
rows = conn.execute(
    "SELECT ts, close, atr FROM candles ORDER BY ts LIMIT ?",
    (MAX_CANDLES,)
).fetchall()
conn.close()

print(f"Loaded {len(rows)} candles")

# Phase labeler — same logic as the Rust PhaseState
# Two tracking states: Rising (tracking lows) and Falling (tracking highs)
# Transition: price crosses extreme + smoothing in the opposite direction

phase = None  # 'rising' or 'falling'
extreme = None  # tracked extreme (low in rising, high in falling)

# Trade tracking
trades = []
current_trade = None
transitions = 0

for i, (ts, close, atr) in enumerate(rows):
    if atr is None or atr < 0.01:
        continue

    smoothing = atr * SMOOTHING_MULT

    if phase is None:
        # Bootstrap: start rising
        phase = 'rising'
        extreme = close
        continue

    transition = False

    if phase == 'rising':
        # Track the low
        if close < extreme:
            extreme = close
        # Transition to falling: price rose above low + smoothing
        if close > extreme + smoothing:
            phase = 'falling'
            extreme = close  # now tracking the high
            transition = True

    elif phase == 'falling':
        # Track the high
        if close > extreme:
            extreme = close
        # Transition to rising: price dropped below high - smoothing
        if close < extreme - smoothing:
            phase = 'rising'
            extreme = close  # now tracking the low
            transition = True

    if transition:
        transitions += 1

        # Close current trade
        if current_trade is not None:
            entry_price = current_trade['entry_price']
            exit_price = close
            direction = current_trade['direction']

            if direction == 'long':
                residue = (exit_price - entry_price) / entry_price
            else:
                residue = (entry_price - exit_price) / entry_price

            # Subtract fees: 0.35% entry + 0.35% exit
            net_residue = residue - 0.007

            current_trade['exit_price'] = exit_price
            current_trade['exit_ts'] = ts
            current_trade['exit_candle'] = i
            current_trade['residue'] = residue
            current_trade['net_residue'] = net_residue
            current_trade['duration'] = i - current_trade['entry_candle']
            trades.append(current_trade)

        # Open new trade
        # Rising -> Falling: we were long, now go short
        # Falling -> Rising: we were short, now go long
        new_direction = 'short' if phase == 'falling' else 'long'
        current_trade = {
            'direction': new_direction,
            'entry_price': close,
            'entry_ts': ts,
            'entry_candle': i,
        }

print(f"\nTransitions: {transitions}")
print(f"Trades resolved: {len(trades)}")

if not trades:
    print("No trades to analyze")
    sys.exit(0)

# Analyze
gross_wins = sum(1 for t in trades if t['residue'] > 0)
net_wins = sum(1 for t in trades if t['net_residue'] > 0)
avg_duration = sum(t['duration'] for t in trades) / len(trades)
avg_residue = sum(t['residue'] for t in trades) / len(trades)
avg_net = sum(t['net_residue'] for t in trades) / len(trades)
total_net = sum(t['net_residue'] for t in trades)

longs = [t for t in trades if t['direction'] == 'long']
shorts = [t for t in trades if t['direction'] == 'short']

print(f"\n=== RESULTS (first {MAX_CANDLES} candles, {SMOOTHING_MULT}x ATR smoothing) ===")
print(f"Total trades:     {len(trades)}")
print(f"  Long:           {len(longs)}")
print(f"  Short:          {len(shorts)}")
print(f"Gross win rate:   {gross_wins/len(trades)*100:.1f}%")
print(f"Net win rate:     {net_wins/len(trades)*100:.1f}% (after 0.70% round trip)")
print(f"Avg duration:     {avg_duration:.0f} candles ({avg_duration*5/60:.1f} hours)")
print(f"Avg gross residue: {avg_residue*100:.3f}%")
print(f"Avg net residue:   {avg_net*100:.3f}%")
print(f"Total net residue: {total_net*100:.2f}%")

# By direction
for label, subset in [("LONG", longs), ("SHORT", shorts)]:
    if not subset:
        continue
    w = sum(1 for t in subset if t['net_residue'] > 0)
    avg_r = sum(t['net_residue'] for t in subset) / len(subset)
    avg_d = sum(t['duration'] for t in subset) / len(subset)
    print(f"\n  {label}: {len(subset)} trades, net win rate {w/len(subset)*100:.1f}%, avg net {avg_r*100:.3f}%, avg duration {avg_d:.0f} candles")

# Distribution by residue bucket
print(f"\n=== RESIDUE DISTRIBUTION (net, after fees) ===")
buckets = [(-999, -0.03), (-0.03, -0.01), (-0.01, 0.0), (0.0, 0.01), (0.01, 0.03), (0.03, 999)]
labels = ["< -3%", "-3% to -1%", "-1% to 0%", "0% to 1%", "1% to 3%", "> 3%"]
for (lo, hi), label in zip(buckets, labels):
    count = sum(1 for t in trades if lo <= t['net_residue'] < hi)
    print(f"  {label:>12s}: {count:>5d} ({count/len(trades)*100:5.1f}%)")

# Show first 10 trades
print(f"\n=== FIRST 10 TRADES ===")
for t in trades[:10]:
    print(f"  {t['direction']:>5s} entry={t['entry_price']:.1f} exit={t['exit_price']:.1f} "
          f"gross={t['residue']*100:+.2f}% net={t['net_residue']*100:+.2f}% "
          f"duration={t['duration']} candles")
