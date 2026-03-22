#!/usr/bin/env bash
set -euo pipefail

unset CARGO_TARGET_DIR

MODES=("visual-only" "thought-only" "agree-only" "meta-boost" "weighted")
CANDLES=50000
OUTDIR="orchestration_results"
CARGO_CMD="cargo run --release --bin trader --"

mkdir -p "$OUTDIR"

echo "=== Orchestration Strategy Comparison ==="
echo "Candles: $CANDLES"
echo "Modes: ${MODES[*]}"
echo ""

for mode in "${MODES[@]}"; do
    echo "──── Running: $mode ────"
    logfile="$OUTDIR/${mode}.log"
    (cd rust && $CARGO_CMD \
        --max-candles "$CANDLES" \
        --orchestration "$mode" \
        2>"../$logfile")
    echo "  -> saved to $logfile"
    echo ""
done

echo ""
echo "=== Results Summary ==="
echo ""

printf "%-15s %12s %12s %10s %10s %12s %12s\n" \
    "MODE" "EQUITY" "RETURN%" "TRADES" "WIN%" "VIS_ROLL%" "THT_ROLL%"
printf "%-15s %12s %12s %10s %10s %12s %12s\n" \
    "───────────" "──────────" "──────────" "────────" "────────" "──────────" "──────────"

for mode in "${MODES[@]}"; do
    logfile="$OUTDIR/${mode}.log"

    equity=$(grep -oP 'Equity: \$\K[0-9.]+' "$logfile" | tail -1)
    total_return=$(grep -oP 'Total return: \K[-0-9.]+' "$logfile" | tail -1)
    trades=$(grep -oP 'Trades taken: \K[0-9]+' "$logfile" | tail -1)
    win_rate=$(grep -oP 'Win rate: \K[0-9.]+' "$logfile" | tail -1)
    vis_roll=$(grep -m1 -oP 'Rolling \(last [0-9]+\): \K[0-9.]+' "$logfile" || echo "N/A")
    tht_roll=$(grep -A999 'Thought prediction' "$logfile" | grep -oP 'Rolling \(last [0-9]+\): \K[0-9.]+' | head -1 || echo "N/A")

    printf "%-15s %12s %12s %10s %10s %12s %12s\n" \
        "$mode" "\$$equity" "${total_return}%" "$trades" "${win_rate}%" "$vis_roll%" "$tht_roll%"
done

echo ""
echo "Full logs in $OUTDIR/"
