"""
Sweep ATR smoothing multiplier for phase-transition exits.
Find where the average move overcomes the 0.70% round-trip fee.
"""

import sqlite3
import sys

DB = "data/analysis.db"
MAX_CANDLES = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
FEE = 0.007  # 0.70% round trip

conn = sqlite3.connect(DB)
rows = conn.execute(
    "SELECT close, atr FROM candles ORDER BY ts LIMIT ?",
    (MAX_CANDLES,)
).fetchall()
conn.close()

print(f"Candles: {len(rows)}")
print(f"Fee: {FEE*100:.2f}% round trip")
print()
print(f"{'mult':>6s} {'trades':>7s} {'gross_wr':>9s} {'net_wr':>7s} {'avg_dur':>8s} {'avg_gross':>10s} {'avg_net':>10s} {'total_net':>10s}")
print("-" * 80)

for mult_10 in [15, 20, 30, 40, 50, 60, 80, 100, 150, 200, 300]:
    mult = mult_10 / 10.0

    phase = None
    extreme = None
    trades = []
    current = None

    for i, (close, atr) in enumerate(rows):
        if atr is None or atr < 0.01:
            continue
        smoothing = atr * mult

        if phase is None:
            phase = 'rising'
            extreme = close
            continue

        transition = False
        if phase == 'rising':
            if close < extreme:
                extreme = close
            if close > extreme + smoothing:
                phase = 'falling'
                extreme = close
                transition = True
        elif phase == 'falling':
            if close > extreme:
                extreme = close
            if close < extreme - smoothing:
                phase = 'rising'
                extreme = close
                transition = True

        if transition:
            if current is not None:
                ep = current['entry_price']
                d = current['direction']
                residue = (close - ep) / ep if d == 'long' else (ep - close) / ep
                trades.append({
                    'residue': residue,
                    'net': residue - FEE,
                    'duration': i - current['candle'],
                })
            new_dir = 'short' if phase == 'falling' else 'long'
            current = {'direction': new_dir, 'entry_price': close, 'candle': i}

    if not trades:
        continue

    n = len(trades)
    gw = sum(1 for t in trades if t['residue'] > 0) / n * 100
    nw = sum(1 for t in trades if t['net'] > 0) / n * 100
    ad = sum(t['duration'] for t in trades) / n
    ag = sum(t['residue'] for t in trades) / n * 100
    an = sum(t['net'] for t in trades) / n * 100
    tn = sum(t['net'] for t in trades) * 100

    print(f"{mult:6.1f} {n:7d} {gw:8.1f}% {nw:6.1f}% {ad:7.0f}c {ag:+9.3f}% {an:+9.3f}% {tn:+9.1f}%")
