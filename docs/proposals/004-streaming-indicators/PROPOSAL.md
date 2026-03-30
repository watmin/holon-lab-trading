# Proposal 004: Streaming Indicator Engine

**Scope:** userland — replace pre-computed SQLite candles with a streaming OHLCV ingest layer.

## 1. The current state

The enterprise loads pre-computed candles from `analysis.db` — 652,608 rows with 60 fields each. The `build_candles.rs` binary reads raw OHLCV from parquet, computes 54 technical indicators (SMA, RSI, MACD, BB, ATR, DMI/ADX, Stochastic, Ichimoku, Keltner, etc.), and writes them to SQLite. The enterprise binary loads the pre-computed candles and processes them.

This means:
- The data pipeline has two steps: build_candles → enterprise
- The Candle struct is tightly coupled to the SQLite schema
- Adding a new asset requires building a new database
- The enterprise cannot consume a raw OHLCV stream (websocket, CSV, API)
- Multi-asset requires multiple pre-built databases

## 2. The problem

The enterprise claims to be a fold over `Stream<Event>`. But it can only consume events from a pre-computed SQLite database. A raw candle — timestamp, open, high, low, close, volume — cannot enter the system. The streaming interface is aspirational until the enterprise can compute its own indicators.

BTC happens to be in SQLite. SOL might be in a CSV. ETH might come from a websocket. They're all OHLCV streams. The enterprise should consume OHLCV, not pre-computed databases. The source is irrelevant.

## 3. The proposed change

### A ring buffer indicator engine

```
raw OHLCV → ring_buffer(~2200) → compute_indicators → full Candle(60 fields)
          → thought_encoder(window) → EnrichedEvent → fold
```

A new module: `src/indicator.rs` (or `src/candle/indicator.rs`).

**`IndicatorEngine`** — a struct that:
1. Accepts raw OHLCV: `fn push(&mut self, ts: &str, o: f64, h: f64, l: f64, c: f64, v: f64) -> Candle`
2. Maintains a ring buffer of ~2200 raw candles (2016 for max window + 200 for SMA200)
3. Computes all 54 derived fields from the buffer on each push
4. Returns a complete Candle struct ready for thought encoding

The indicator math already exists in `build_candles.rs`. It's batch-oriented (operates on the full parquet). The streaming version operates on the ring buffer — same formulas, different data source.

### What changes

**`src/candle.rs`** — `load_candles()` becomes one of several ingest paths, not the only one. A new `RawCandle { ts, open, high, low, close, volume }` struct for the minimal input.

**`src/indicator.rs`** (new) — `IndicatorEngine` with the ring buffer and all computations. Each indicator is a function of the buffer: `fn sma(buffer: &[f64], period: usize) -> f64`, `fn rsi(buffer: &[f64], period: usize) -> f64`, etc.

**`src/bin/enterprise.rs`** — Two ingest modes:
- `--source db:path` — load pre-computed candles from SQLite (current behavior, fast backtest)
- `--source ohlcv:path.csv` — stream raw OHLCV through the indicator engine
- `--source ohlcv:path.parquet` — same, from parquet
- Future: `--source ws:url` — websocket OHLCV stream

**`build_candles.rs`** — becomes optional. A batch pre-computation tool for fast backtesting. Not required for the enterprise to function.

### The ring buffer

The buffer needs ~2200 candles:
- 2016 for the max observer window (thought encoding lookback)
- 200 for SMA200 (the longest indicator lookback)
- These overlap — 2016 already covers 200

Some indicators need incremental state beyond the buffer:
- RSI uses Wilder smoothing (needs the previous smoothed value, not the full history)
- MACD uses EMA (same — needs previous EMA, not full history)
- OBV is cumulative (needs running total)
- ATR uses Wilder smoothing

The indicator engine carries this incremental state alongside the ring buffer. Each indicator either computes from the buffer (SMA, BB, range position) or updates incrementally (RSI, MACD, ATR, OBV).

### Multi-asset becomes trivial

```rust
let mut btc_engine = IndicatorEngine::new();
let mut sol_engine = IndicatorEngine::new();

for raw in merged_ohlcv_stream {
    let candle = match raw.asset {
        "BTC" => btc_engine.push(raw.ts, raw.o, raw.h, raw.l, raw.c, raw.v),
        "SOL" => sol_engine.push(raw.ts, raw.o, raw.h, raw.l, raw.c, raw.v),
        _ => continue,
    };
    let event = EnrichedEvent::Candle { candle, ... };
    state.on_event(event, &ctx);
}
```

Each asset has its own indicator engine, its own ring buffer, its own incremental state. The engines are independent. The fold is shared.

## 4. The algebraic question

The indicator engine is a stateful transducer: `(EngineState, RawOHLCV) → (EngineState, Candle)`. It sits between the event source and the encoding functor:

```
source → transducer(indicator_engine) → functor(thought_encoder) → fold(enterprise)
```

Is this transducer part of the fold? No. It precedes the fold. The fold consumes `EnrichedEvent`. The transducer produces `Candle`. The encoding functor maps `Candle → EnrichedEvent`. Three stages, each with its own state:

1. **Transducer state**: ring buffer + incremental indicator values (per-asset)
2. **Functor state**: VectorManager cache, window samplers (per-observer)
3. **Fold state**: EnterpriseState (journals, treasury, positions)

Each stage's state is independent. The transducer doesn't know about vectors. The functor doesn't know about OHLCV. The fold doesn't know about indicators.

## 5. The simplicity question

The current system has two binaries: `build_candles` and `enterprise`. The proposed system has one binary that can do both — compute indicators on the fly or load pre-computed ones. Fewer moving parts. One pipeline.

The indicator engine adds ~500 lines (the math already exists in build_candles.rs, just restructured for streaming). The ring buffer is a VecDeque with a cap. The incremental state is ~10 running values (previous RSI, previous ATR, running OBV, etc.).

The complexity is in the indicators, not the engine. The indicators are the domain. The engine is the plumbing.

## 6. Questions for designers

1. **Transducer placement**: should the indicator engine live inside the enterprise (as part of on_event for raw candles) or outside (as a preprocessing stage in the runner)? The fold is pure — should the transducer be too?

2. **Incremental vs recompute**: some indicators (SMA, BB) can be recomputed from the buffer each candle. Others (RSI, ATR) benefit from incremental state. Should the engine prefer stateless recomputation (purer, simpler, slower) or incremental updates (stateful, faster, more complex)?

3. **Ring buffer as state**: the indicator engine carries state (the buffer + incremental values). This is per-asset state that exists outside the fold. In a multi-asset system, each asset has its own engine. Is this the right boundary — or should the ring buffer live on the enterprise state?

4. **Backtest performance**: pre-computed SQLite is fast (just load and go). The indicator engine computes 54 indicators per candle. At 652k candles, that's ~35M indicator computations. Is this acceptable, or should pre-computed DB remain the fast path with the engine as the live path?

5. **Candle identity**: should the Candle struct remain the same 60-field struct, or should it split into `RawCandle(6 fields) + DerivedIndicators(54 fields)`? The split makes the derivation explicit in the type but doubles the struct count.

6. **build_candles.rs fate**: does it become dead code, or does it remain as a batch optimization tool? If the engine can compute everything the batch tool can, the batch tool is redundant. But the batch tool also writes to SQLite, which is useful for analysis queries.
