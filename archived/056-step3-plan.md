# Step 3 Plan: Market Observer Builds Indicator Rhythms

## Current State

The market observer:
1. Receives `ObsInput { candle, window, encode_count }`
2. Samples a window size from its WindowSampler
3. Slices the window: `&input.window[start..]`
4. Calls `market_lens_facts(lens, candle, sliced, scales)` — ONE candle + window
5. The lens calls vocab modules: `encode_momentum_facts(candle)`, etc.
6. Each vocab module returns `Vec<ThoughtAST>` from the single candle
7. The window is only used by `encode_standard_facts` for distance-from calculations
8. The facts are bundled into ONE ThoughtAST, encoded into ONE Vector
9. The observer feeds the vector to its reckoner (noise subspace → anomaly → predict)
10. The chain carries: `market_raw`, `market_anomaly`, `market_ast`, `prediction`, `edge`

## Target State

The market observer:
1. Receives the same `ObsInput`
2. Samples window size, slices the window — same
3. Instead of calling vocab modules on ONE candle, extracts raw f64 values
   from EACH candle in the window for each indicator the lens selects
4. Calls `indicator_rhythm()` per indicator — returns one Vector per indicator
5. Calls `circular_rhythm()` for periodic values (hour, day-of-week)
6. Bundles all rhythm vectors into ONE thought vector
7. Feeds the thought to the reckoner — same interface (noise subspace → anomaly → predict)
8. The chain carries: `market_raw`, `market_anomaly`, `market_rhythms`, `prediction`, `edge`

## The Problem

The vocab modules (`encode_momentum_facts`, `encode_oscillator_facts`, etc.)
produce `Vec<ThoughtAST>` from a single candle. They compute derived
values (close-sma20 distance, di-spread) and wrap them in Bind + Linear
AST nodes. They also use ScaleTracker to learn the scale.

The rhythm approach needs raw f64 values per indicator across the window.
The vocab modules don't return raw values — they return AST nodes.

## Approach: Indicator Spec Table

Each lens defines a table of indicator specs:

```rust
struct IndicatorSpec {
    atom_name: &'static str,
    extractor: fn(&Candle) -> f64,
    value_min: f64,
    value_max: f64,
    delta_range: f64,
}

struct CircularSpec {
    atom_name: &'static str,
    extractor: fn(&Candle) -> f64,
    period: f64,
}
```

The lens returns `(Vec<IndicatorSpec>, Vec<CircularSpec>)`.

Example for DowTrend:
```rust
vec![
    // Momentum
    IndicatorSpec { atom_name: "close-sma20", extractor: |c| (c.close - c.sma20) / c.sma20, value_min: -0.1, value_max: 0.1, delta_range: 0.05 },
    IndicatorSpec { atom_name: "close-sma50", extractor: |c| (c.close - c.sma50) / c.sma50, value_min: -0.2, value_max: 0.2, delta_range: 0.1 },
    IndicatorSpec { atom_name: "adx", extractor: |c| c.adx, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
    IndicatorSpec { atom_name: "macd-hist", extractor: |c| c.macd_hist, value_min: -50.0, value_max: 50.0, delta_range: 20.0 },
    IndicatorSpec { atom_name: "atr-ratio", extractor: |c| c.atr_ratio, value_min: 0.0, value_max: 0.05, delta_range: 0.01 },
    // Persistence
    IndicatorSpec { atom_name: "hurst", extractor: |c| c.hurst, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
    IndicatorSpec { atom_name: "autocorrelation", extractor: |c| c.autocorrelation, value_min: -1.0, value_max: 1.0, delta_range: 0.3 },
    // Regime
    IndicatorSpec { atom_name: "kama-er", extractor: |c| c.kama_er, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
    IndicatorSpec { atom_name: "choppiness", extractor: |c| c.choppiness, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
    IndicatorSpec { atom_name: "aroon-up", extractor: |c| c.aroon_up, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
    IndicatorSpec { atom_name: "aroon-down", extractor: |c| c.aroon_down, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
    // ...
]
```

The market observer program:
```rust
let (specs, circular_specs) = market_rhythm_specs(&lens);
let window = &input.window[start..];

let mut rhythms: Vec<Vector> = Vec::new();
for spec in &specs {
    let values: Vec<f64> = window.iter().map(|c| (spec.extractor)(c)).collect();
    rhythms.push(indicator_rhythm(&vm, &scalar, spec.atom_name, &values,
        spec.value_min, spec.value_max, spec.delta_range));
}
for spec in &circular_specs {
    let values: Vec<f64> = window.iter().map(|c| (spec.extractor)(c)).collect();
    rhythms.push(circular_rhythm(&vm, &scalar, spec.atom_name, &values, spec.period));
}
let refs: Vec<&Vector> = rhythms.iter().collect();
let thought = Primitives::bundle(&refs);
```

## What Happens to the Vocab Modules

The existing vocab modules (`encode_momentum_facts`, `encode_oscillator_facts`,
etc.) are NOT deleted. They still produce single-candle ThoughtAST facts.
They're still used by:
- The regime observer's lens facts (phase current, phase scalars)
- The DB snapshot (thought_ast for diagnostics)
- Any future consumer that needs single-candle facts

The market observer stops calling them for its primary encoding path.
It uses the spec table + `indicator_rhythm()` instead.

## What Happens to the ScaleTracker

The spec table has hardcoded bounds (value_min, value_max, delta_range).
These are from the indicator's nature — RSI [0,100], ADX [0,100], etc.
The ScaleTracker is no longer needed for the market observer's primary
encoding. The thermometer bounds ARE the scale.

The ScaleTracker still lives for the regime observer's lens facts and
for any indicator where the range isn't known in advance (deltas could
use it for the delta_range parameter — measure the typical per-candle
change and derive the range).

## What Changes on the Chain

`MarketChain` currently carries:
```rust
pub market_raw: Vector,       // raw thought
pub market_anomaly: Vector,   // anomaly from noise subspace
pub market_ast: ThoughtAST,   // the AST (for position observer extraction)
```

After step 3:
```rust
pub market_raw: Vector,       // raw rhythm bundle
pub market_anomaly: Vector,   // anomaly from noise subspace
pub market_ast: ThoughtAST,   // diagnostic snapshot (single-candle facts for logging)
```

The `market_raw` is now the rhythm bundle, not a single-candle encoding.
The `market_anomaly` is the anomaly of the rhythm bundle.
The `market_ast` remains for diagnostic logging but is NOT the encoding source.

The position observer currently cosines individual facts from `market_ast`
against `market_anomaly`. With rhythms, the `market_ast` is a diagnostic
artifact. The position observer needs to change (step 6) to work with
rhythm vectors instead of fact extraction. But that's step 6, not step 3.

For step 3 alone: the market observer changes. The chain shape stays
compatible. The position observer keeps working (it still receives
market_raw, market_anomaly, market_ast) but the meaning of market_raw
changed. The position observer's extraction will be stale until step 6
fixes it.

## Files Changed

1. `src/domain/lens.rs` — add `market_rhythm_specs(lens) -> (Vec<IndicatorSpec>, Vec<CircularSpec>)`
2. `src/encoding/rhythm.rs` — add `IndicatorSpec` and `CircularSpec` structs (or put them in lens.rs)
3. `src/programs/app/market_observer_program.rs` — replace fact encoding with rhythm building

## Files NOT Changed

- `src/vocab/*` — vocab modules stay. They're still consumed.
- `src/programs/chain.rs` — chain fields stay. Meaning shifts.
- `src/programs/app/position_observer_program.rs` — stale but functional until step 6.

## Risk

The position observer's anomaly extraction becomes meaningless after
step 3 — it cosines single-candle facts against a rhythm-encoded
anomaly. The cosines will be noise. This is acceptable as a transition
state. Step 6 fixes it. The broker-observer still receives position
facts (regime + extracted market facts) but the market extraction is
garbage until the regime observer is updated.

Alternative: do steps 3-7 as one atomic change. Riskier — larger
diff, harder to debug. The incremental approach accepts temporary
staleness in exchange for smaller, testable steps.

## Test

- Build and run 500-candle smoke test
- Query DB: rhythm-encoded observer snapshots should show different
  thought_ast shape (still single-candle for logging, but the actual
  encoding is rhythms)
- The reckoner should still predict (it sees a vector, doesn't care
  how it was built)
- Telemetry: `encode` time will change — rhythm building is more work
  but the cache helps
