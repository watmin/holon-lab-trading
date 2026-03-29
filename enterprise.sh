#!/usr/bin/env bash
set -euo pipefail

# Unset sandbox env vars that redirect cargo output
unset CARGO_TARGET_DIR 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust"
DB_PATH="$SCRIPT_DIR/data/analysis.db"
BINARY="$RUST_DIR/target/release/enterprise"

usage() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  build              Build enterprise binary (release)"
    echo "  run [flags]        Build + run with given flags"
    echo "  test <candles> [flags]  Build + run, log to orchestration_results/"
    echo "  kill               Kill running enterprise processes"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 test 100000 --swap-fee 0.0010 --slippage 0.0025 --asset-mode hold --name my-run"
    echo "  $0 run --max-candles 5000 --asset-mode hold"
}

do_build() {
    echo "Building enterprise (release)..."
    cd "$RUST_DIR" && cargo build --release --bin enterprise 2>&1
    echo "Binary: $BINARY"
}

do_kill() {
    touch "$RUST_DIR/trader-stop"
    sleep 1
    pkill -f "target/release/enterprise" 2>/dev/null || true
    rm -f "$RUST_DIR/trader-stop"
    echo "Killed."
}

case "${1:-}" in
    build)
        do_build
        ;;
    run)
        shift
        do_kill 2>/dev/null || true
        do_build
        echo "Running: $BINARY --db-path $DB_PATH $*"
        "$BINARY" --db-path "$DB_PATH" "$@"
        ;;
    test)
        shift
        candles="${1:?Usage: $0 test <candles> [flags]}"
        shift
        do_kill 2>/dev/null || true
        do_build

        # Parse --name flag for log/db naming
        name=""
        extra_args=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) name="$2"; shift 2 ;;
                *) extra_args+=("$1"); shift ;;
            esac
        done
        if [[ -z "$name" ]]; then
            name="run-$(date +%H%M%S)"
        fi

        logfile="$SCRIPT_DIR/orchestration_results/${name}.log"
        rundb="$SCRIPT_DIR/orchestration_results/${name}.db"

        if [[ -f "$rundb" ]]; then
            echo "ERROR: Run DB already exists: $rundb"
            echo "Pick a different --name or delete the old run first."
            exit 1
        fi

        echo "Running enterprise: $candles candles → $logfile"
        echo "Flags: ${extra_args[*]:-}"
        echo "──────────────────────────────────────"

        "$BINARY" --db-path "$DB_PATH" --max-candles "$candles" --run-db "$rundb" "${extra_args[@]}" 2> "$logfile"

        echo ""
        echo "Done. Key results:"
        tail -6 "$logfile"
        ;;
    kill)
        do_kill
        ;;
    *)
        usage
        exit 1
        ;;
esac
