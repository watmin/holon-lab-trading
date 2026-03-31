# Review: Brian Beckman

Verdict: **CONDITIONAL**

Conditional on two refinements: (1) make the incremental indicator state an explicit algebra, and (2) type-separate RawCandle from Candle so the functor structure is visible in the code.

---

## Preamble

This is a clean proposal. The authors clearly understand that the enterprise is a fold, that the fold's input type is `EnrichedEvent`, and that everything upstream of `EnrichedEvent` is preprocessing. The three-stage decomposition -- transducer, functor, fold -- is categorically sound in outline. My concerns are about whether the implementation will honor the algebraic contracts that the diagram implies.

---

## Question 1: Transducer placement

> Should the indicator engine live inside the enterprise (as part of on_event) or outside (as a preprocessing stage in the runner)?

**Outside. Unambiguously.**

The proposal already has this right, but let me say why it is not merely a preference -- it is a categorical necessity.

The enterprise fold has the signature `(EnterpriseState, EnrichedEvent) -> EnterpriseState`. This is a catamorphism. Its algebra is `EnrichedEvent -> (EnterpriseState -> EnterpriseState)`, i.e. each event is an endomorphism on the state. The beauty of a catamorphism is that the algebra is *closed* -- the carrier (EnterpriseState) and the endomorphism are the entire world.

If you push the transducer inside, you contaminate the carrier. The fold state now includes ring buffers, Wilder smoothing accumulators, OBV running totals -- none of which participate in the algebra of trading. You have broken the closure. The fold is no longer about trading; it is about trading *and* signal processing. Two concerns, one algebra. This is precisely what "complected" means.

The transducer sits in the runner, before the fold. The runner is imperative scaffolding. The fold is the algebra. Keep them separate.

## Question 2: Incremental vs. recompute

> Should the engine prefer stateless recomputation or incremental updates?

**Incremental, but make it honest.**

The proposal identifies two classes of indicators: buffer-computable (SMA, BB, range position) and incrementally-stateful (RSI, MACD, ATR, OBV). This is the right distinction, but the proposal is imprecise about what "incremental state" means algebraically.

An SMA over a ring buffer is a function: `SMA: Buffer -> R`. It is stateless in the sense that it depends only on the current buffer contents. The buffer itself is the state, and it is shared.

RSI with Wilder smoothing is different. It carries a value `s_{n}` and updates via `s_{n+1} = (alpha * x_{n+1}) + ((1 - alpha) * s_n)`. This is an *accumulator* -- a left fold over the input stream with carrier `R` and algebra `(R, f64) -> R`. It is a perfectly legitimate algebraic object. It is a monoid action: the reals under Wilder smoothing form a semigroup acting on the state space.

The concern is not "stateful vs. stateless." The concern is: **does each accumulator compose?** If you have 10 independent accumulators (RSI state, ATR state, MACD fast EMA, MACD slow EMA, MACD signal EMA, OBV total, etc.), their product is the product of 10 independent monoid actions. This is fine -- product monoids compose trivially. But you must actually structure them as independent. If any accumulator reads another accumulator's state (e.g., if Stochastic RSI reads RSI), you have a dependency, and the product decomposition fails. You need a *layered* composition: first RSI, then StochRSI reads the result.

Recommendation: define the incremental state as a struct with named fields, and define `update` as a single function that takes a raw candle and returns the full derived indicator set. Make the dependency order explicit. This is a Kleisli arrow: `(IncrementalState, RawCandle) -> (IncrementalState, DerivedIndicators)`. The type signature tells you everything.

## Question 3: Ring buffer as state

> Is per-asset IndicatorEngine the right boundary?

**Yes. This is the free construction.**

Each asset's indicator stream is independent. BTC's SMA200 has nothing to do with SOL's SMA200. The indicator engine is a functor from `Stream<RawOHLCV>` to `Stream<Candle>`, and this functor is parameterized by the engine's internal state. Each asset gets its own instance of the functor.

In categorical terms: you have a product category `Asset x Time`, and the indicator engine is a family of endofunctors indexed by Asset. The product decomposition is trivial because the indices are independent. If you put all assets into one shared ring buffer, you would need to partition by asset inside the buffer, which is just a less honest encoding of the same product structure.

Per-asset engines are the right call. The fold is shared (it sees all assets' events in time order), but the transducers are per-asset. This is exactly the multi-asset composition described in Section 3.

One note: the proposal says "the engines are independent, the fold is shared." This is the key sentence. It means the system is a *coproduct* of independent transducer pipelines feeding into a shared fold. The coproduct is the merged event stream. The `merge_streams` function in `event.rs` is exactly this coproduct. The algebra is sound.

## Question 4: Backtest performance

> Is computing 54 indicators per candle acceptable at 652k scale?

**Yes, with a caveat.**

The proposal estimates ~35M indicator computations. At the speeds Rust delivers for arithmetic over contiguous buffers, this is on the order of seconds, not minutes. The ring buffer is a `VecDeque` -- cache-friendly, sequential access for SMA/BB window scans. The incremental indicators (RSI, ATR, MACD) are O(1) per candle. The buffer-scan indicators (SMA200) are O(200) per candle but that is 200 multiplies and adds -- trivial.

The caveat: **keep the pre-computed SQLite path.** Not because the streaming path will be slow, but because the two paths serve different purposes. The streaming path is the *truth* -- it proves the enterprise can consume raw OHLCV. The pre-computed path is a *cache* -- it accelerates iteration during development. A cache that you can validate against the truth is enormously valuable. Run the streaming path once, compare outputs against the SQLite path, and you have a regression test for the indicator engine for free.

The batch tool (`build_candles.rs`) also writes to SQLite, which is useful for ad-hoc SQL analysis. Keep it. It is not dead code; it is a different morphism in the same category (batch materialization vs. streaming transduction). Both are legitimate.

## Question 5: Candle identity

> Should the Candle struct split into RawCandle + DerivedIndicators?

**Yes. This is not optional.**

The entire proposal rests on the claim that there is a three-stage pipeline: transducer, functor, fold. But if the Candle struct is a flat 60-field blob at every stage, the type system does not witness the pipeline structure. The transducer's input and output are the same type. The functor from Candle to EnrichedEvent cannot distinguish "this Candle has valid indicators" from "this Candle has zero-valued indicator fields because nobody computed them yet."

The split makes the pipeline a composition of typed morphisms:

```
RawCandle --(transducer)--> Candle { raw: RawCandle, derived: DerivedIndicators }
Candle    --(functor)-----> EnrichedEvent
EnrichedEvent --(fold)----> EnterpriseState
```

Each arrow has a distinct domain and codomain. The types *enforce* the pipeline. You cannot accidentally feed a RawCandle to the thought encoder. You cannot accidentally feed an un-enriched Candle to the fold. The compiler does the checking.

This is not "doubling the struct count." This is making implicit structure explicit. The current Candle struct has 6 raw fields and 54 derived fields pretending to be peers. They are not peers. The raw fields are data. The derived fields are computations over data. The type system should say so.

If you want to keep a flat field access pattern for the thought encoder (so it does not care about the split), implement `Deref` or accessor methods. The internal structure is for the pipeline; the external interface is for convenience. Both can coexist.

## Question 6: build_candles.rs fate

> Does it become dead code?

**It becomes a materialized view.**

In database terms, the streaming indicator engine is the *query* and `build_candles` is the *materialized view*. The query is the source of truth. The materialized view is a performance optimization and an analysis tool. You keep both.

The validation discipline is: after implementing the streaming engine, run it over the same parquet input that `build_candles` uses, and diff the outputs. Every indicator value should match to within floating-point tolerance. If they diverge, one of them has a bug. This is a property test: `streaming(input) == batch(input)` for all inputs.

Once validated, `build_candles` is the fast path for backtesting and the SQL-queryable artifact for analysis. The streaming engine is the live path and the proof that the enterprise is truly a fold over `Stream<Event>`.

---

## The multi-asset closure question

The proposal does not ask this explicitly, but I will answer it because it matters.

Does `IndicatorEngine::new()` per asset, feeding into a shared `merge_streams` and a single fold, *close* under the enterprise algebra?

Yes. Here is why:

1. Each `IndicatorEngine` is an independent Mealy machine: `(EngineState, RawOHLCV) -> (EngineState, Candle)`. Independence means the product of N engines is the product Mealy machine. No interaction, no shared state, no coupling.

2. The coproduct (merged stream) is order-preserving (sorted by timestamp). The fold processes events in time order regardless of asset origin. The fold's algebra (`EnrichedEvent -> Endo(EnterpriseState)`) does not assume single-asset -- it dispatches on `event.asset()`.

3. The encoding functor (thought encoder) is also per-asset (each observer has its own window sampler state). So the full pipeline is: `per-asset transducer -> per-asset functor -> coproduct merge -> shared fold`.

This is a standard construction: a family of independent pipelines coproduced into a single consumer. It closes because:
- The transducer product closes (independent components).
- The functor product closes (independent components).
- The coproduct is a free construction (merge is just interleaving with time ordering).
- The fold is a catamorphism over the coproduct (it consumes events from any asset).

The only subtlety is that the fold's state *does* couple across assets (treasury holds multi-asset positions, risk branches see cross-asset correlations). But this coupling is *inside* the fold, where it belongs. The pipeline stages before the fold are independent per asset. The fold is the place where assets interact. This is the correct boundary.

---

## Summary

The proposal is algebraically sound. The three-stage pipeline (transducer, functor, fold) is a composition of well-defined morphisms. The ring buffer with incremental state is a legitimate accumulator. Per-asset engines compose as a product. Multi-asset merging is a coproduct. The fold remains a catamorphism.

Two conditions for approval:

1. **Type the pipeline.** Split Candle into `RawCandle` and `Candle { raw, derived }`. Make the transducer boundary visible to the compiler, not just to the reader.

2. **Structure the incremental state.** Define the Wilder/EMA/OBV accumulators as an explicit struct with a single `update` method. Make the dependency order (e.g., RSI before StochRSI) visible in the code. The accumulator is a Kleisli arrow; write it as one.

With these two refinements, this is a clean extension that fulfills the enterprise's promise: a genuine fold over `Stream<Event>`, regardless of source.
