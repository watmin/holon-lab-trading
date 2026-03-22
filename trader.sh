#!/usr/bin/env bash
set -euo pipefail

# Unset sandbox env vars that redirect cargo output
unset CARGO_TARGET_DIR 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust"
DB_PATH="$SCRIPT_DIR/data/analysis.db"
BINARY="$RUST_DIR/target/release/trader"

usage() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  build              Build the trader binary (release)"
    echo "  run [flags]        Build + run trader with given flags"
    echo "  test <candles> [flags]  Build + run with --max-candles and log to file"
    echo "  compare <candles>  Run all 5 orchestration modes and print summary"
    echo "  log <name>         Tail a test log file"
    echo "  kill               Kill any running trader processes"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 run --max-candles 5000 --orchestration visual-only"
    echo "  $0 test 50000 --orchestration visual-only"
    echo "  $0 test 50000 --orchestration visual-only --name my-experiment"
    echo "  $0 compare 50000"
    echo "  $0 log visual-only"
    echo "  $0 kill"
    exit 1
}

do_build() {
    echo "Building trader (release)..."
    cd "$RUST_DIR" && cargo build --release --bin trader 2>&1
    echo "Binary: $BINARY"
}

do_kill() {
    local pids
    pids=$(pgrep -f "target/release/trader" 2>/dev/null | grep -v $$ || true)
    if [ -z "$pids" ]; then
        echo "No trader processes found."
    else
        echo "Killing: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
        echo "Done."
    fi
}

do_run() {
    do_build
    echo ""
    echo "Running: $BINARY --db-path $DB_PATH $*"
    echo "──────────────────────────────────────"
    "$BINARY" --db-path "$DB_PATH" "$@"
}

do_test() {
    local candles="$1"; shift

    # Parse optional --name flag
    local name=""
    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done

    # Auto-generate name from orchestration mode if not provided
    if [ -z "$name" ]; then
        for i in "${!extra_args[@]}"; do
            if [ "${extra_args[$i]}" = "--orchestration" ] && [ $((i+1)) -lt ${#extra_args[@]} ]; then
                name="${extra_args[$((i+1))]}"
                break
            fi
        done
        name="${name:-run-$(date +%H%M%S)}"
    fi

    local outdir="$SCRIPT_DIR/orchestration_results"
    local logfile="$outdir/${name}.log"
    mkdir -p "$outdir"

    do_build
    echo ""
    echo "Running: $candles candles, logging to $logfile"
    echo "Flags: ${extra_args[*]:-none}"
    echo "──────────────────────────────────────"
    "$BINARY" --db-path "$DB_PATH" --max-candles "$candles" "${extra_args[@]}" 2>"$logfile" &
    local pid=$!
    echo "PID: $pid"
    echo "Tail with: $0 log $name"
    wait "$pid"
    echo ""
    echo "Done. Results:"
    grep -E 'Equity:|Total return:|Win rate:|Rolling|recognition gate|noise_floor' "$logfile" || true
}

do_compare() {
    local candles="$1"
    local modes=("visual-only" "thought-only" "agree-only" "meta-boost" "weighted")
    local outdir="$SCRIPT_DIR/orchestration_results"
    mkdir -p "$outdir"

    do_build

    echo ""
    echo "=== Orchestration Strategy Comparison ==="
    echo "Candles: $candles"
    echo ""

    for mode in "${modes[@]}"; do
        echo "──── Running: $mode ────"
        local logfile="$outdir/${mode}.log"
        "$BINARY" --db-path "$DB_PATH" --max-candles "$candles" --orchestration "$mode" 2>"$logfile"
        echo "  -> $logfile"
        echo ""
    done

    echo "=== Results Summary ==="
    echo ""
    printf "%-15s %12s %12s %10s %10s %12s %12s\n" \
        "MODE" "EQUITY" "RETURN%" "TRADES" "WIN%" "VIS_ROLL%" "THT_ROLL%"
    printf "%-15s %12s %12s %10s %10s %12s %12s\n" \
        "───────────" "──────────" "──────────" "────────" "────────" "──────────" "──────────"

    for mode in "${modes[@]}"; do
        local logfile="$outdir/${mode}.log"
        local equity total_return trades win_rate vis_roll tht_roll

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
    echo "Full logs in $outdir/"
}

do_log() {
    local name="$1"
    local logfile="$SCRIPT_DIR/orchestration_results/${name}.log"
    if [ ! -f "$logfile" ]; then
        echo "No log file: $logfile"
        echo "Available:"
        ls "$SCRIPT_DIR/orchestration_results/"*.log 2>/dev/null || echo "  (none)"
        exit 1
    fi
    tail -f "$logfile"
}

[[ $# -lt 1 ]] && usage

cmd="$1"; shift

case "$cmd" in
    build)   do_build ;;
    run)     do_run "$@" ;;
    test)    [[ $# -lt 1 ]] && usage; do_test "$@" ;;
    compare) [[ $# -lt 1 ]] && usage; do_compare "$@" ;;
    log)     [[ $# -lt 1 ]] && usage; do_log "$@" ;;
    kill)    do_kill ;;
    *)       echo "Unknown command: $cmd"; usage ;;
esac
