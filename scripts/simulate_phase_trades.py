"""
Simulate phase-based trading with accumulation model.

Entry: 3+ higher lows → buy (USDC→WBTC). 3+ lower highs → sell (WBTC→USDC).
  One position per candle during active phase.
  Entry costs 0.35% fee.

Exit (Grace): structure breaks AND trade has profit > fees.
  Recover principal (the $50 USDC). Keep the residue in the asset (WBTC).
  Exit costs 0.35% fee on the principal recovery.

Exit (Stop): price hits stop loss. Lose the stop amount + fees. Capital protection.

Hold: structure breaks but profit < fees. Keep holding. Stop loss protects.

The accumulation: deploy $50. Price rises. Recover $50. Keep the WBTC residue.
Both sides do this symmetrically.
"""

import sqlite3
import sys

DB = "data/analysis.db"
MAX_CANDLES = int(sys.argv[1]) if len(sys.argv) > 1 else 652000
SMOOTHING_MULT = 2.0
ENTRY_FEE = 0.0035   # 0.35% per swap
POSITION_SIZE = 50.0  # $50 per entry

conn = sqlite3.connect(DB)
rows = conn.execute(
    "SELECT ts, close, high, low, atr FROM candles ORDER BY ts LIMIT ?",
    (MAX_CANDLES,)
).fetchall()
conn.close()

print(f"Candles: {len(rows)}")

# Build phases
phase = None
extreme = None
rising_phases = []
falling_phases = []

for i, (ts, close, high, low, atr) in enumerate(rows):
    if atr is None or atr < 0.01:
        continue
    smoothing = atr * SMOOTHING_MULT
    if phase is None:
        phase = 'rising'
        extreme = close
        continue
    if phase == 'rising':
        if close < extreme:
            extreme = close
        if close > extreme + smoothing:
            rising_phases.append((extreme, i))
            phase = 'falling'
            extreme = close
    elif phase == 'falling':
        if close > extreme:
            extreme = close
        if close < extreme - smoothing:
            falling_phases.append((extreme, i))
            phase = 'rising'
            extreme = close

# Build buy/sell active arrays and exit signals
buy_active = [False] * len(rows)
sell_active = [False] * len(rows)
buy_exit_signal = [False] * len(rows)
sell_exit_signal = [False] * len(rows)

hl_streak = 0
for idx in range(len(rising_phases)):
    low_val, candle_idx = rising_phases[idx]
    if idx > 0 and low_val > rising_phases[idx-1][0]:
        hl_streak += 1
    else:
        hl_streak = 0
    if hl_streak >= 2:
        start = candle_idx
        end = rising_phases[idx + 1][1] if idx + 1 < len(rising_phases) else len(rows) - 1
        for c in range(start, min(end + 1, len(rows))):
            buy_active[c] = True

for idx in range(1, len(rising_phases)):
    if rising_phases[idx][0] <= rising_phases[idx-1][0]:
        buy_exit_signal[rising_phases[idx][1]] = True

lh_streak = 0
for idx in range(len(falling_phases)):
    high_val, candle_idx = falling_phases[idx]
    if idx > 0 and high_val < falling_phases[idx-1][0]:
        lh_streak += 1
    else:
        lh_streak = 0
    if lh_streak >= 2:
        start = candle_idx
        end = falling_phases[idx + 1][1] if idx + 1 < len(falling_phases) else len(rows) - 1
        for c in range(start, min(end + 1, len(rows))):
            sell_active[c] = True

for idx in range(1, len(falling_phases)):
    if falling_phases[idx][0] >= falling_phases[idx-1][0]:
        sell_exit_signal[falling_phases[idx][1]] = True


def run_simulation(stop_pct):
    active_longs = []   # each: {entry_price, entry_cost_usd, candle}
    active_shorts = []  # each: {entry_price, entry_cost_usd, candle}

    # Accumulation tracking
    total_deployed = 0.0      # total USDC spent on entries (including fees)
    total_recovered = 0.0     # total USDC recovered (principal back)
    total_residue_usd = 0.0   # total residue value in USD (kept in asset)
    total_stopped_loss = 0.0  # total USD lost to stops
    total_fees = 0.0          # total fees paid
    grace_count = 0
    stop_count = 0
    hold_through_count = 0

    for i, (ts, close, high, low, atr) in enumerate(rows):
        if close is None:
            continue

        # Stop losses — every candle, all positions
        remaining_longs = []
        for t in active_longs:
            stop_price = t['entry_price'] * (1.0 - stop_pct)
            if low is not None and low <= stop_price:
                # Stopped out. We bought WBTC at entry_price. Now it's worth stop_price.
                # We sell at stop_price. We get back less than we put in.
                exit_value = POSITION_SIZE * (stop_price / t['entry_price'])
                exit_fee = exit_value * ENTRY_FEE
                recovered = exit_value - exit_fee
                loss = (POSITION_SIZE + t['entry_fee']) - recovered
                total_stopped_loss += loss
                total_fees += exit_fee
                total_recovered += recovered
                stop_count += 1
            else:
                remaining_longs.append(t)
        active_longs = remaining_longs

        remaining_shorts = []
        for t in active_shorts:
            stop_price = t['entry_price'] * (1.0 + stop_pct)
            if high is not None and high >= stop_price:
                exit_value = POSITION_SIZE * (t['entry_price'] / stop_price)
                exit_fee = exit_value * ENTRY_FEE
                recovered = exit_value - exit_fee
                loss = (POSITION_SIZE + t['entry_fee']) - recovered
                total_stopped_loss += loss
                total_fees += exit_fee
                total_recovered += recovered
                stop_count += 1
            else:
                remaining_shorts.append(t)
        active_shorts = remaining_shorts

        # Structure break — evaluate exits
        if buy_exit_signal[i]:
            remaining = []
            for t in active_longs:
                # Current value of our WBTC position in USD
                current_value = POSITION_SIZE * (close / t['entry_price'])
                # To recover principal: sell enough WBTC to get $50 USDC back
                # We need to sell (POSITION_SIZE / (1 - ENTRY_FEE)) worth
                # because the exit swap costs 0.35%
                principal_to_recover = POSITION_SIZE
                exit_fee_on_principal = principal_to_recover * ENTRY_FEE
                total_sell = principal_to_recover + exit_fee_on_principal

                # Residue: what's left in WBTC after recovering principal
                residue_value = current_value - total_sell

                if residue_value > 0:
                    # Worth exiting. Recover principal. Keep residue in WBTC.
                    total_recovered += principal_to_recover
                    total_residue_usd += residue_value
                    total_fees += exit_fee_on_principal
                    grace_count += 1
                else:
                    # Not worth exiting. Hold through. Stop loss protects.
                    remaining.append(t)
                    hold_through_count += 1
            active_longs = remaining

        if sell_exit_signal[i]:
            remaining = []
            for t in active_shorts:
                # Short: we sold WBTC at entry_price, got USDC. Now price is close.
                # To close: buy back WBTC at close, return it.
                # Our profit is entry_price - close (in asset terms)
                current_value = POSITION_SIZE * (t['entry_price'] / close)
                principal_to_recover = POSITION_SIZE
                exit_fee_on_principal = principal_to_recover * ENTRY_FEE
                total_sell = principal_to_recover + exit_fee_on_principal
                residue_value = current_value - total_sell

                if residue_value > 0:
                    total_recovered += principal_to_recover
                    total_residue_usd += residue_value
                    total_fees += exit_fee_on_principal
                    grace_count += 1
                else:
                    remaining.append(t)
                    hold_through_count += 1
            active_shorts = remaining

        # Entries — one per candle during active phase
        if buy_active[i]:
            entry_fee = POSITION_SIZE * ENTRY_FEE
            total_deployed += POSITION_SIZE + entry_fee
            total_fees += entry_fee
            active_longs.append({
                'entry_price': close,
                'entry_fee': entry_fee,
                'candle': i,
            })
        if sell_active[i]:
            entry_fee = POSITION_SIZE * ENTRY_FEE
            total_deployed += POSITION_SIZE + entry_fee
            total_fees += entry_fee
            active_shorts.append({
                'entry_price': close,
                'entry_fee': entry_fee,
                'candle': i,
            })

    # Value remaining open positions at current price
    last_close = rows[-1][1]
    open_long_value = sum(POSITION_SIZE * (last_close / t['entry_price']) for t in active_longs)
    open_short_value = sum(POSITION_SIZE * (t['entry_price'] / last_close) for t in active_shorts)

    return {
        'grace': grace_count,
        'stop': stop_count,
        'hold_through': hold_through_count,
        'open_longs': len(active_longs),
        'open_shorts': len(active_shorts),
        'deployed': total_deployed,
        'recovered': total_recovered,
        'residue': total_residue_usd,
        'stopped_loss': total_stopped_loss,
        'fees': total_fees,
        'open_value': open_long_value + open_short_value,
    }


print(f"\nPosition size: ${POSITION_SIZE:.0f} per entry")
print(f"Entry fee: {ENTRY_FEE*100:.2f}%  Exit fee: {ENTRY_FEE*100:.2f}%")
print()
print(f"{'stop':>6s} {'grace':>7s} {'stopped':>8s} {'held':>6s} {'open':>6s} {'deployed':>12s} {'recovered':>12s} {'residue':>12s} {'lost':>12s} {'fees':>12s} {'net':>12s}")
print("-" * 120)

for stop_bps in [50, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000]:
    stop_pct = stop_bps / 10000.0
    r = run_simulation(stop_pct)

    net = r['recovered'] + r['residue'] - r['deployed'] + r['open_value']

    print(f"{stop_pct*100:5.2f}% {r['grace']:7d} {r['stop']:8d} {r['hold_through']:6d} "
          f"{r['open_longs']+r['open_shorts']:6d} "
          f"${r['deployed']:10.0f} ${r['recovered']:10.0f} ${r['residue']:10.0f} "
          f"${r['stopped_loss']:10.0f} ${r['fees']:10.0f} ${net:+10.0f}")
