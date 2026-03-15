# Holon Lab: Trading

A self-tuning BTC paper trader powered by [Holon](https://github.com/watmin/holon)'s
algebraic intelligence stack. Encodes OHLCV market data + technical indicators into
hypervectors, learns market-regime manifolds, and autonomously refines its pattern
memory through a two-phase feedback loop.

**This is a proving ground — zero modifications to holon core.**

> If anything about how Holon works is unclear, read [`HOLON_CONTEXT.md`](./HOLON_CONTEXT.md)
> before the code. The standard VSA/HDC literature has gaps that matter. That file captures
> what Holon has discovered that isn't in the papers.

## Quick Start

```bash
# 1. Set up environment (auto-creates venv, installs holon + deps)
./scripts/run_with_venv.sh python -c "print('ready')"

# 2. Download historical data (~2 years of 5m BTC candles)
./scripts/run_with_venv.sh python -c "from trading.feed import HistoricalFeed; HistoricalFeed().ensure_data()"

# 3. Discover seed engrams (offline, ~10 min)
./scripts/discover.sh

# 4. Run live self-tuning system
./scripts/run_live.sh
```

## Architecture

See [PLAN.md](PLAN.md) for the full battle plan.

```
Phase 1 (main thread)          Phase 2 (daemon thread)
─────────────────────          ────────────────────────
Live 5m BTC feed               Every 30 min:
  → encode window                → read recent decisions
  → probe engram library         → score engrams by outcome
  → match? deploy action         → reward/punish features
  → surprise? mint engram        → prune bottom 35%
  → log to SQLite                → ship updated engrams
  → hot-reload if new version    → consumer reloads
```

## Project Structure

```
trading/
  features.py    Technical indicators (SMA, BB, MACD, ADX, RSI, ATR)
  encoder.py     OHLCV → hypervector via encode_walkable
  feed.py        Live + historical BTC data feed
  tracker.py     Paper trading + metrics + SQLite audit trail
  harness.py     Brute-force engram discovery
  darwinism.py   Algebraic feature selection (reward/punishment)
  system.py      Two-phase orchestrator
```
