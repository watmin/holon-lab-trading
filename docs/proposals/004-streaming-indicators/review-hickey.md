# Review: Rich Hickey

Verdict: CONDITIONAL

The direction is right. The diagnosis is precise. But the proposal conflates two distinct problems, and the solution carries unnecessary state.

## What you got right

The two-binary pipeline is complected. `build_candles` couples you to SQLite, to a specific schema, to a batch workflow. You correctly identify that the enterprise should consume OHLCV, not databases. Source independence is the right goal. You will not get to multi-asset without it.

The three-stage decomposition — transducer, functor, fold — is the right shape. Each stage has different concerns and different state lifecycles. You've separated them cleanly in the proposal. Good.

## What concerns me

### 1. The ring buffer is a place

You've proposed a mutable ring buffer of 2200 candles plus ~10 incremental running values. This is a *place* — a mutable location that gets updated. You're going to push into it, it's going to wrap around, and now you have a coordination problem: which indicators have been computed from the current buffer state, and which haven't? The buffer is shared mutable state for 54 indicator computations.

The alternative: each indicator is a *reducing function*. It takes its own accumulated state and a new candle, and returns new state plus a value. `(AccState, RawCandle) -> (AccState, f64)`. No shared buffer. Each indicator owns exactly the state it needs — the RSI reducer carries its smoothed averages, the SMA reducer carries its window, the MACD reducer carries its EMAs. They don't share a ring buffer. They share nothing.

This is the transducer idea applied properly. A transducer doesn't carry a shared buffer and index into it. A transducer is a transformation of a reducing function. You compose transducers; you don't compose reads from a shared mutable buffer.

### 2. Incremental vs. recompute is a false dichotomy

The proposal frames this as a choice: recompute from buffer (pure, slow) vs. incremental update (stateful, fast). But this framing hides a third option that is both pure *and* fast: *each indicator carries exactly the state it needs to produce the next value, and nothing more*.

SMA(20) needs 20 values. Not a ring buffer of 2200. Give it a VecDeque of 20.

RSI needs its previous smoothed gain and smoothed loss. Two f64s. Not a ring buffer.

ATR needs the previous ATR value. One f64.

OBV needs the running total. One f64.

When each indicator owns its minimal state, the question "incremental or recompute?" dissolves. Some indicators recompute from their small window. Some update incrementally. The indicator decides. No central buffer imposes a strategy.

### 3. The Candle struct is a place masquerading as a value

60 named fields. You add an indicator, you touch the struct, the loader, the encoder, the tests. This is the kind of positional coupling that makes systems rigid.

Consider: what if `Candle` were `RawCandle` plus a `BTreeMap<String, f64>` of derived indicators? Or even: `RawCandle` plus a `Vec<(&'static str, f64)>` sorted by name? The indicators become *data*, not *structure*. You add an indicator by registering a reducer. You don't touch a struct definition, a SQL column list, or a row mapper.

The 60-field struct is a schema. Schemas are fine for databases. They're poison for data pipelines. A pipeline should not know how many indicators there are. It should know that there are *some*, they have names, and they have values.

### 4. The transducer belongs outside the fold — but be precise about why

The proposal asks whether the indicator engine should live "inside" or "outside" the fold. The answer is outside, but not because of purity. The fold's state is the enterprise — journals, positions, treasury. The transducer's state is the indicator computation. These states have *different lifecycles*. The enterprise state persists across runs (or could). The indicator state is ephemeral — recomputable from the raw stream. Things with different lifecycles should not share a container.

### 5. build_candles should die, but not yet

Keep it until the indicator engine produces identical output. Then delete it. Don't maintain two implementations of the same math. That's where bugs live — in the space between two things that are supposed to be the same but aren't. Run them both, diff the output, then kill the old one.

## Answers to the six questions

**1. Transducer placement — outside the fold.** The indicator engine is a stream transformation. It maps `Stream<RawCandle>` to `Stream<Candle>`. The fold never sees raw candles. The runner owns the transducer. The fold owns the enterprise state. Different lifecycles, different owners.

**2. Incremental vs. recompute — per-indicator, not per-engine.** Don't make this a global choice. Each indicator is a reducing function that carries its own minimal state. SMA carries a window. RSI carries two smoothed values. The engine is a composition of reducers, not a monolith that reads from a shared buffer.

**3. Ring buffer as state — no.** Replace the central ring buffer with per-indicator state. The "ring buffer" pattern implies shared mutable storage that multiple consumers index into. Per-indicator reducers are simpler, compose better, and can be tested independently. If some indicators genuinely need the same raw history (range_pos, trend_consistency), give them a shared immutable window — a slice, not a mutable buffer they all write through.

There is one legitimate shared structure: the raw candle history that window-based indicators need. Make it a `VecDeque<RawCandle>` capped at 200 (the longest raw lookback). But it's *input* to the reducers, not *state* of the engine. The reducers read from it; they don't write to it. This is a value, not a place.

**4. Backtest performance — pre-computed DB remains the fast path.** 35M indicator computations is not free. Keep `--source db:path` for backtesting. The indicator engine is the *live* path and the *correctness* path. The DB is a cache. Caches are fine as long as you can regenerate them and verify they match.

**5. Candle identity — split it.** `RawCandle` (6 fields) is the input. Derived indicators are a map from name to value. The Candle struct as currently defined is a product type that encodes the current indicator set into the type system. That's fine for a fixed system. But you're proposing to make indicators composable and streaming. The type should reflect that: raw data plus derived data, with the derived data being open (a map), not closed (a struct).

**6. build_candles.rs fate — transitional.** Keep it as a verification oracle while you build the streaming engine. Once the streaming engine reproduces its output exactly, delete it. Two implementations of the same computation is a liability, not a feature.

## The deeper question

The proposal is almost there. The shape is right — source independence, three-stage pipeline, per-asset engines. But the implementation sketch reaches for a shared mutable ring buffer when the natural abstraction is a composition of independent reducing functions. The ring buffer is the "easy" choice (one big array, index into it). The reducers are the "simple" choice (each indicator is self-contained, composable, testable).

Simple is not easy. But you know that, or you wouldn't be writing proposals.

Condition for approval: replace the central ring buffer design with per-indicator reducing functions composed into a pipeline. Keep a small shared raw-candle window (immutable input, not mutable state) for the indicators that need historical lookback. Make `Candle` a `RawCandle` plus a derived-indicator map, not a 60-field struct.
