# Resolution: ACCEPTED with modifications

Both designers CONDITIONAL. Both conditions accepted with one override.

## Decisions

### Transducer outside the fold
Unanimous. The indicator engine is a stream transformation that precedes the fold. Different lifecycles — indicator state is ephemeral and recomputable, enterprise state is persistent. The runner owns the transducer. The fold owns the enterprise.

### Split RawCandle / Candle
Accepted. `RawCandle` (6 fields: ts, open, high, low, close, volume) is the input from any source. `Candle { raw: RawCandle, ...derived fields }` is the output of the indicator engine. The type system enforces the pipeline boundary. The compiler catches un-enriched candles.

### Per-indicator state, not shared ring buffer
Accepted per Hickey. Each indicator is a reducing function carrying its own minimal state. SMA carries 20 values. RSI carries 2 floats. ATR carries 1 float. The engine composes reducers. A small shared `VecDeque<RawCandle>` (capped at ~200) provides the read-only history that window-based indicators need. It's input to the reducers, not mutable shared state.

Dependency order per Beckman: RSI before StochRSI, ATR before Keltner. The update method makes the order explicit.

### Struct, not map
Override on Hickey's open map recommendation. In Rust, a struct with 54 named fields is zero-cost — no heap allocation, no hashing, no runtime lookup. A `BTreeMap<String, f64>` would mean 54 heap-allocated strings and a tree walk per access in the hot path. The struct IS the open map in Rust — adding a field triggers compiler errors at every site that needs updating. Beckman's typed pipeline wins in this language.

### No pre-computed DB dependency
Override on both designers' recommendation to keep the SQLite fast path. The pre-computed DB is an accident of backtesting. A websocket doesn't ship with a SQLite file. An RPC feed doesn't come pre-computed. The architecture must not depend on having pre-built indicator data.

`build_candles.rs` becomes a validation oracle during development: run both paths, diff the output, confirm they match. Once validated, it's an analysis tool (SQL queries over historical data), not a runtime dependency. The enterprise consumes OHLCV. Period.

The streaming indicator engine is both the backtest path and the live path. One pipeline. One truth.

### Multi-asset closes
Per Beckman: per-asset transducers (product) → per-asset encoding functors → coproduct merge → shared fold. Cross-asset coupling lives inside the fold. Everything upstream is independent per asset.

## Implementation plan

1. `RawCandle` struct (6 fields) in `candle.rs`
2. `IndicatorEngine` in new `src/indicator.rs` — per-indicator reducers, shared raw history buffer, single `update(raw: RawCandle) -> Candle` method
3. `Candle` struct keeps its 54 derived fields (typed, zero-cost) but now constructed by the engine, not loaded from SQLite
4. `src/bin/enterprise.rs` creates one `IndicatorEngine` per asset, feeds raw OHLCV, gets full Candles
5. Raw OHLCV loaders: `load_raw_from_db()`, `load_raw_from_csv()` — thin adapters, same output type
6. Validate: streaming engine output matches `build_candles.rs` output for all 652k candles
7. Remove `load_candles()` dependency from the hot path
