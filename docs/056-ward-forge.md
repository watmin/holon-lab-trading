# Forge Ward — Proposal 056

**Files:** `src/encoding/rhythm.rs`, `src/programs/app/broker_program.rs`

---

## rhythm.rs

### `IndicatorSpec` — survives

Values, not places. A pure data struct. The `extractor` is `fn(&Candle) -> f64` — a function pointer, not a closure — which means it can be composed, stored, compared. The bounds live next to the extractor. One struct, one concern.

### `build_rhythm_asts` — survives

Takes data in (`&[Candle]`, `&[IndicatorSpec]`), returns data out (`Vec<ThoughtAST>`). No self, no state, no side effects. The caller bundles — separation is correct. Composes cleanly: market observer calls it, regime observer calls it, both get Vec back and extend their own fact lists.

### `indicator_rhythm` — mostly survives, three findings

**Finding 1: Duplicated budget computation.**
Lines 57 and 116 both compute `((10_000 as f64).sqrt()) as usize`. The first trims input values, the second trims output pairs. Both have `rune:forge(dims)` annotations acknowledging the hardcoded 10_000. The runes are noted — the datamancer knows this needs a dims parameter.

But: the budget is computed twice, identically. The first trim (line 57-62) restricts input to `budget + 3` values. After trigrams and pairs, the maximum output pairs from `budget + 3` values is exactly `budget - 1`. So the second trim (line 116-118) is almost always a no-op — the input trim already guarantees the output fits the budget. This is not a forge finding (temper territory), but it reveals a clarity issue: the reader sees two trims and wonders why. One trim at the top, with a comment explaining the math (`budget+3 values -> budget+1 trigrams -> budget-1 pairs`), would make the invariant visible.

**Direction:** One `let budget = ...` at the top. One trim at the input. Document the pipeline arithmetic. The second trim becomes a debug_assert.

**Finding 2: Five bare `f64` parameters.**
`indicator_rhythm(atom_name: &str, values: &[f64], value_min: f64, value_max: f64, delta_range: f64)` — you can swap `value_min` and `delta_range` and the compiler says nothing. The function works correctly today because `IndicatorSpec` groups them at the call site, and `build_rhythm_asts` destructures correctly. But `broker_program.rs` calls `indicator_rhythm` directly (line 53 via `portfolio_rhythm_asts`), bypassing `IndicatorSpec`. Two call patterns for one function is where swapped parameters hide.

**Direction:** The function already has `IndicatorSpec` — just take `&IndicatorSpec` plus `&[f64]` (since the broker extracts values from PortfolioSnapshot, not Candle). Or: take `IndicatorSpec` directly and let `build_rhythm_asts` be the only caller. The broker's `portfolio_rhythm_asts` could build `IndicatorSpec` values and call `build_rhythm_asts` with a trivial wrapper candle. Either path removes the bare-f64 surface.

**Finding 3: Empty Bundle as sentinel.**
When `values.len() < 4` or `pairs.is_empty()`, the function returns `ThoughtAST::Bundle(vec![])`. An empty bundle encodes to... what? The encoder's `Bundle` arm bundles nothing, producing a zero vector. A zero vector in a larger bundle is additive identity — it contributes nothing, silently. This is correct behavior, but the caller can't distinguish "not enough data" from "zero signal." If a caller ever needs to know whether the rhythm was computable, the return type should be `Option<ThoughtAST>`. Today no caller checks. Worth watching.

**Direction:** Future consideration. If a caller ever branches on "did rhythm compute," switch to `Option<ThoughtAST>`.

### Tests — well-forged

Four tests, each testing one property: determinism, atom orthogonality, structural inspectability, edge case. No test depends on another. The `enc` helper is clean — builds encoder, encodes, done. The 10_000 dims constant matches the hardcoded value in the function. If dims becomes a parameter, the tests will need updating — but that's the point of the rune.

---

## broker_program.rs

### `direction_from_prediction` — survives

Pure function. Takes a reference, returns a value. The `map_or(true, ...)` default-to-Up is a policy choice, not a bug — cold start assumes Up. Clear.

### `PortfolioSnapshot` — survives

Value type. Five fields, all f64. No behavior. The broker program builds it, `portfolio_rhythm_asts` reads it. One producer, one consumer.

### `portfolio_rhythm_asts` — survives, one finding

**Finding 4: The closure `extract_and_build` uses `fn` pointer for extraction.**
`extract: fn(&PortfolioSnapshot) -> f64` — this is the same pattern as `IndicatorSpec::extractor`, but inline. The function builds five rhythm ASTs from five different extractors. This is `build_rhythm_asts` reinvented for `PortfolioSnapshot` instead of `Candle`. The two functions are structurally identical: extract values from a window, call `indicator_rhythm` with bounds.

This is the composition joint that `IndicatorSpec` was designed to serve. But `IndicatorSpec` is typed to `fn(&Candle) -> f64`, so the broker can't use it. The generic shape is: `fn(&T) -> f64` for any T.

**Direction:** Either make `IndicatorSpec` generic over the source type (`IndicatorSpec<T>` with `extractor: fn(&T) -> f64`), or accept that two call sites with different source types is fine. The duplication is small (five lines of mapping). The abstraction cost of a generic may not be worth it for two callers. Watch for a third caller — that's when the function is born. Hickey: "every new thing has a cost."

### `broker_thought_ast` — survives

**This is the function that matters.** Six parameters, returns one ThoughtAST. Pure. No self, no mutation, no side effects. Composes market rhythms + regime rhythms + portfolio rhythms + phase rhythm + time facts into one bundle. Each source is independent — the function is a gather point, not a computation.

The parameter list is long but honest. Each parameter is a different source of truth:
- `market_ast` — from market observer, passed through chain
- `regime_facts` — from regime observer, passed through chain  
- `portfolio_window` — broker's own state as a time series
- `candle_phase_history` — structural phase from PELT
- `candle_hour`, `candle_day` — time coordinates

These can't be collapsed without lying. A "BrokerContext" struct would group them but add indirection with no type safety gain — the fields are already typed correctly. The function takes what it needs and returns what it builds. Beckman nods.

### `broker_program` — the main loop, two findings

**Finding 5: `anomaly` goes stale for late-resolving papers.**
Lines 198-200: the broker computes `anomaly` from this candle's thought, then at line 247 uses the same `anomaly` to teach the gate reckoner about papers that resolved this candle. But the paper might have been opened 200 candles ago. The gate learns "this anomaly pattern led to Grace/Violence" — but "this anomaly" is today's thought, not the thought that was active when the paper was opened.

This is architectural, not a forge finding per se — the forge sees that the `anomaly` variable is used in two temporal contexts within one loop iteration. The function is honest about it (one `let anomaly = ...`, used twice), but the semantics are mixed. A forge-clean version would either store the entry-time anomaly on the receipt or accept that "the exit moment's anomaly is the signal" (which may be the intended design for Gate 4 — "should I be exiting right now?" is about now, not about entry).

**Direction:** If Gate 4 is asking "is NOW a bad time to be holding," then today's anomaly is correct. Document that this is intentional — the gate predicts from the current moment, not the entry moment.

**Finding 6: The eight parameters.**
`broker_program` takes eight parameters. This is a program entry point — it receives everything it needs to run independently. The types are all honest: `QueueReceiver`, `CacheHandle`, `VectorManager`, `Arc<ScalarEncoder>`, `ConsoleHandle`, `QueueSender`, `Broker`, `TreasuryHandle`. Each is a capability. The function can't do anything the caller didn't explicitly grant.

This is correct for a thread body. A struct would hide the dependency list without reducing it. The forge sees eight seams and all eight are load-bearing.

### Runes acknowledged

- `rune:forge(dims)` at rhythm.rs:57, rhythm.rs:116, broker_program.rs:117 — hardcoded 10_000 for budget. The datamancer has been here. Needs dims as a parameter when ctx flows this deep.
- `rune:temper(disabled)` at broker_program.rs:264 — rhythm AST serialization disabled. Not a forge concern.

---

## Summary

| Function | Verdict | Notes |
|---|---|---|
| `IndicatorSpec` | Forged | Clean value type |
| `build_rhythm_asts` | Forged | Pure, composes |
| `indicator_rhythm` | Nearly forged | Duplicate budget trim (clarity), five bare f64s (swappable), empty Bundle sentinel (silent) |
| `direction_from_prediction` | Forged | Pure |
| `PortfolioSnapshot` | Forged | Clean value type |
| `portfolio_rhythm_asts` | Forged | Parallel to build_rhythm_asts; watch for third caller |
| `broker_thought_ast` | Forged | Pure gather function, honest parameter list |
| `broker_program` | Forged | Thread body, eight load-bearing seams, anomaly temporal note |

**The core of Proposal 056 is well-made.** `indicator_rhythm` is a genuine abstraction — three callers, one function, clean AST output. `broker_thought_ast` is a pure composition point that takes six independent data sources and produces one tree. The encode path (`AST -> cache -> Vector`) composes cleanly through the whole chain.

The dims rune is the biggest open seam. When ctx reaches these functions, the three hardcoded `10_000` sites become one parameter. Until then, the runes hold the line.
