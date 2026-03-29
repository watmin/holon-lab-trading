# Inventory — what is where and why

The module layout IS the enterprise tree. When you read `src/`, you see roles, not files.

## The heartbeat

```
src/bin/enterprise.rs  (1,902 lines)
```

The orchestrator. One candle per heartbeat. Encodes, predicts, manages positions, learns, logs. Calls modules — doesn't define vocabulary, encoding, or domain logic. If you're adding a new thought, you don't touch this file. If you're adding a new expert or changing the learning loop, this is the only file.

## Layer 0 — candle to thoughts

```
src/thought/
  mod.rs               (1,274 lines)  ThoughtEncoder + stdlib eval methods
  pelt.rs              (81 lines)     PELT changepoint detection (pub, used by vocab/divergence)
```

**ThoughtEncoder** turns a candle window into a thought vector. It owns the fact_cache (pre-computed atom compositions) and dispatches to vocab modules based on the expert's profile.

**The stdlib** — eval methods that stay on ThoughtEncoder because they use its internal state:
- `eval_comparisons_cached` — "close is above SMA20." Baseline for all experts.
- `eval_segment_narrative` — PELT segments with direction, magnitude, duration, zone boundaries. The richest thought. 117 lines.
- `eval_temporal` — "RSI has been above SMA for 8 candles." Duration awareness.
- `eval_calendar` — circular hour/day encoding + categorical trading sessions.
- `eval_volume_confirmation` — "volume agrees with the move."
- `eval_range_position` — "close is at the 73rd percentile of the range." Scalar.
- `eval_rsi_sma_cached` — "RSI crossed above its SMA."

**To improve accuracy:** make these think richer thoughts. More compositional facts, deeper narrative, better range awareness. These are the levers.

**To add a new stdlib method:** add it here, add its call to the profile dispatch in `encode_view()`.

## Vocabulary modules — the enterprise's thoughts

```
src/vocab/
  mod.rs               (51 lines)   Fact enum + module registry
  regime.rs            (228)   KAMA ER, choppiness, DFA, DeMark, Aroon, fractal dim, entropy, GR b-value
  oscillators.rs       (144)   Williams %R, StochRSI, UltOsc, multi-ROC
  flow.rs              (148)   OBV, VWAP, MFI, buying/selling pressure
  persistence.rs       (101)   Hurst exponent, autocorrelation, ADX zones
  divergence.rs        (92)    RSI divergence via PELT structural peaks/troughs
  ichimoku.rs          (90)    Tenkan, kijun, spans, cloud zone, TK cross
  stochastic.rs        (69)    %K, %D, zones, crossover
  price_action.rs      (50)    Inside/outside bars, gaps, consecutive candles
  fibonacci.rs         (37)    Retracement levels and proximity
  keltner.rs           (40)    Channels + squeeze detection
  momentum.rs          (33)    CCI zones
```

**The contract** (from `wat/vocab.wat`): each module is a pure function. Candles in, `Vec<Fact>` out. No holon imports. No vectors. Data is the interface. The encoder has one `encode_facts()` method that renders any module's output.

**To add a new module:**
1. Create `vocab/foo.rs` with `pub fn eval_foo(candles: &[Candle]) -> Vec<Fact>`
2. Register in `vocab/mod.rs`: `pub mod foo;`
3. Add one line to the profile dispatch in `thought/mod.rs`
4. The encoder never changes.

**To add a new indicator to an existing module:** add computation + push `Fact::Zone`/`Scalar`/etc. The module stays pure.

## The market team

```
src/market/
  mod.rs               (21 lines)   Shared market primitives (parse_candle_hour, parse_candle_day)
  manager.rs           (179)   ManagerAtoms, ManagerContext, encode_manager_thought
  observer.rs          (48)    Observer struct + constructor
```

**Manager** encodes expert opinions into the manager's thought. One function, called at prediction and resolution. The encoding IS the thought — identical everywhere.

**Observer** is the leaf node. Each has a Journal, a WindowSampler, a resolved predictions queue, and a proof gate.

**Time encoding** lives in `market/mod.rs` — shared between manager and observers. Circular. Hour 23 is near hour 0.

**To add a new market-level module** (e.g. exit expert encoding): create `market/exit.rs`.

## The risk team

```
src/risk/
  mod.rs               (22 lines)   RiskBranch struct + constructor
```

Skeleton. Five branches (drawdown, accuracy, volatility, correlation, panel) initialized in enterprise.rs. The encoding lives on `Portfolio::risk_branch_wat` — migrates here when the risk manager is built.

**To build the risk manager:** create `risk/manager.rs` following `market/manager.rs` pattern.

## The primitives

```
src/journal.rs         (238 lines)  Journal — accumulate, predict, recalibrate. Generic.
src/candle.rs          (79)         Candle struct + SQLite loader
src/ledger.rs          (130)        Run DB schema — the ledger that counts
src/portfolio.rs       (309)        Portfolio struct — equity, phase, risk_branch_wat
src/position.rs        (231)        Pending, ExitObservation, ManagedPosition
src/treasury.rs        (153)        Asset map — claim, release, swap
src/sizing.rs          (72)         Kelly criterion + signal weight
src/window_sampler.rs  (96)         Deterministic log-uniform window sampling
```

**Journal** is domain-agnostic. Every expert, the manager, and the exit expert all use it. Two accumulators, one discriminant, one cosine. The learning primitive.

**Portfolio** holds the enterprise's state: equity, phase transitions, rolling accuracy, risk branch encoding. `risk_branch_wat` should eventually migrate to `risk/`.

**Position** tracks trade lifecycle: entry → management → partial exit → runner → close.

**Treasury** holds assets. Knows balances, not predictions. Executes swaps.

## The specifications

```
wat/
  vocab.wat            The Fact interface contract
  manager.wat          Manager encoding spec
  risk.wat             Risk specialist spec (aspirational — implementation is skeleton)
  treasury.wat         Treasury operations spec
  ledger.wat           Ledger tables and contract
  position.wat         Position lifecycle spec
  generalist.wat       Generalist status (questioned by its own spec)
  expert/*.wat         Per-observer vocabulary assignments
  DISCOVERIES.md       34 entries of things learned during development
```

**To add a new domain spec:** write it in wat/. The spec is the source of truth for what the enterprise SHOULD do. The Rust implements it.

## How to entertain additions

**New thought (new indicator, new composition):**
→ Add to an existing `vocab/` module or create a new one. Return `Vec<Fact>`. One line in dispatch. The encoder never changes.

**New expert profile (new way to think about candles):**
→ Add a profile name to the `encode_view()` dispatch. List which modules and stdlib methods it uses. Create the observer in enterprise.rs.

**New enterprise role (risk manager, exit expert, horizon expert):**
→ Create a module in the role's namespace (`risk/manager.rs`, `market/exit.rs`). Follow the existing pattern — atoms struct, context struct, encode function. Wire in enterprise.rs.

**Richer stdlib method (better comparisons, deeper narrative):**
→ Edit the method in `thought/mod.rs`. The stdlib uses encoder state — that's by design.

## How to avoid bad thoughts

1. **Vocab modules are pure functions.** They don't import holon. They don't create vectors. If you're reaching for `Primitives::bind` in a vocab module, you've crossed the boundary.

2. **One encoding path.** If the same concept is encoded at two call sites, extract to a function. The manager encoding was this — three sites, now one function.

3. **No magic averages.** If you're computing a percentile and hardcoding it, stop. Derive from ATR, conviction, or dims. Let it breathe.

4. **The Fact is the interface.** Zone, Comparison, Scalar, Bare. If a new thought doesn't fit these four, either it's a new Fact variant or you're overcomplicating the thought.

5. **The curve judges.** Don't defend a thought theoretically. Run 100k candles. The conviction-accuracy curve says if it's a good thought. The discriminant decides, not us.
