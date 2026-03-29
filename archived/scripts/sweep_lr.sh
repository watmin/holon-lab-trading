#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDLES=30000
RATES=(1.0 0.5 0.1 0.05 0.01)
OUTDIR="$SCRIPT_DIR/orchestration_results"

# Unset sandbox env vars that redirect cargo output
unset CARGO_TARGET_DIR 2>/dev/null || true

echo "Building trader..."
cd "$SCRIPT_DIR/rust" && cargo build --release --bin trader 2>&1 | tail -2
cd "$SCRIPT_DIR"

echo ""
echo "=== Learning Rate Sweep ==="
echo "Candles: $CANDLES, Rates: ${RATES[*]}"
echo ""

for lr in "${RATES[@]}"; do
    name="lr-sweep-${lr}"
    rundb="$OUTDIR/${name}.db"
    logfile="$OUTDIR/${name}.log"

    if [ -f "$rundb" ]; then
        echo "SKIP $lr (db exists: $rundb)"
        continue
    fi

    echo "──── Running lr=$lr ────"
    "$SCRIPT_DIR/rust/target/release/trader" \
        --db-path "$SCRIPT_DIR/data/analysis.db" \
        --max-candles "$CANDLES" \
        --run-db "$rundb" \
        --learning-rate "$lr" \
        2>"$logfile"
    echo "  Done: $logfile"
done

echo ""
echo "=== Results ==="
printf "%-8s %8s %8s %8s %8s %8s\n" "LR" "VIS%" "THT%" "AGREE%" "WIN%" "P&L%"
printf "%-8s %8s %8s %8s %8s %8s\n" "------" "------" "------" "------" "------" "------"

for lr in "${RATES[@]}"; do
    name="lr-sweep-${lr}"
    logfile="$OUTDIR/${name}.log"
    if [ ! -f "$logfile" ]; then continue; fi

    # Grab the last checkpoint line
    last=$(grep -oP 'vis=\K[0-9.]+' "$logfile" | tail -1)
    tht=$(grep -oP 'thought=\K[0-9.]+' "$logfile" | tail -1)
    agree=$(grep -oP 'agree=\K[0-9]+' "$logfile" | tail -1)
    win=$(grep -oP 'win=\K[0-9.]+' "$logfile" | tail -1)
    pnl=$(grep -oP '\(([+-]?[0-9.]+%)\)' "$logfile" | tail -1 | tr -d '()')

    printf "%-8s %8s %8s %8s %8s %8s\n" "$lr" "${last}%" "${tht}%" "${agree}%" "${win}%" "$pnl"
done
