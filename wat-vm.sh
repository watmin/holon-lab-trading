#!/usr/bin/env bash
set -euo pipefail

# Unset sandbox env vars that redirect cargo output
unset CARGO_TARGET_DIR 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/target/release/wat-vm"
DEFAULT_PARQUET="$SCRIPT_DIR/data/btc_5m_raw.parquet"

usage() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  build                   Build wat-vm binary (release)"
    echo "  run [flags]             Build + run with given flags"
    echo "  smoke [candles]         Build + run quick smoke test (default: 500)"
    echo "  kill                    Kill running wat-vm processes"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 smoke 1000"
    echo "  $0 run --stream USDC:WBTC:data/btc_5m_raw.parquet --max-candles 5000"
}

do_build() {
    echo "Building wat-vm (release)..."
    mkdir -p "$SCRIPT_DIR/.build"
    cd "$SCRIPT_DIR" && cargo build --release --bin wat-vm \
        > "$SCRIPT_DIR/.build/stdout.log" 2> "$SCRIPT_DIR/.build/stderr.log"
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "BUILD FAILED. See .build/stderr.log"
        tail -10 "$SCRIPT_DIR/.build/stderr.log"
        exit 1
    fi
    echo "Binary: $BINARY"
}

do_kill() {
    echo "Killing wat-vm processes..."
    pkill -f "target/release/wat-vm" 2>/dev/null && echo "Killed." || echo "No wat-vm running."
}

do_run() {
    do_build
    echo "Running wat-vm..."
    "$BINARY" "$@"
}

do_smoke() {
    local candles="${1:-500}"
    do_build
    echo "Smoke test: $candles candles..."
    "$BINARY" --stream "USDC:WBTC:$DEFAULT_PARQUET" --max-candles "$candles"
}

case "${1:-}" in
    build)
        do_build
        ;;
    run)
        shift
        do_run "$@"
        ;;
    smoke)
        shift
        do_smoke "$@"
        ;;
    kill)
        do_kill
        ;;
    *)
        usage
        exit 1
        ;;
esac
