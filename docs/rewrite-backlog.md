# Trading Lab Rewrite — Backlog

**Opened:** 2026-04-22.
**Status:** Phases 0–1.2 ready; everything after pending.
**Source of truth for the rewrite:** `archived/pre-wat-native/` — the last mature Rust version before the wat language work began. Full Cargo crate `enterprise`, binary `wat-vm`, 10,380 LoC across src/, 10 integration tests.
**Method:** Leaves-to-root.

---

## Why this document exists

The trading lab reached maturity as a working Rust system. Over several months, expressing domain logic through Rust's syntax imposed enough ceremony to slow iteration — that observation produced the 058 algebra proposal, then the wat language shipped as `wat-rs` across four days (arcs 001–016, closing 2026-04-21). The lab rewrite is the first real consumer of wat — and the proof the language was worth building.

`CLAUDE.md` describes the aspirational target architecture (Market Observer / Regime Observer / Broker-Observer / Post / Treasury / Enterprise / four-step loop). Parts of it may be stale relative to `archived/pre-wat-native/`; this backlog treats `pre-wat-native/` as the authoritative reference and flags CLAUDE.md divergences inline. CLAUDE.md gets rewritten once Phase 5 lands and the new wat shape is settled.

---

## Architectural decisions locked

- **Top-level namespace `:trading::*`.** Reserved-prefix gate in `wat-rs/src/resolve.rs:238-249` reserves only `:wat::*` sub-prefixes and `:rust::*`. Every other prefix is legal. `:trading::*` at top-level saves one segment at every call site vs `:user::trading::*`. Requires a one-line amendment to `wat-rs/docs/CONVENTIONS.md` naming app-owned top-level roots as a valid shape alongside `:user::<app>::*`. Ships as part of Phase 0.
- **Fresh Cargo consumer crate.** Single-crate to start — `holon-lab-trading` depending on `wat`. Sibling crates (`wat-holon`, `wat-rusqlite`, `wat-parquet`) added as Rust-interop demand surfaces, mirroring the `wat-lru` precedent from arc 013.
- **Consumer template layout (arc 018 minimal form).** `Cargo.toml`, `src/main.rs` (one-line `wat::main! { deps: [...] }`), `tests/test.rs` (one-line `wat::test! {}`), `wat/main.wat` (entry — config + `:user::main`), `wat/**/*.wat` (library tree, loaded recursively), `wat-tests/**/*.wat` (test files). Same shape as `wat-rs/examples/with-loader/` post-arc-018.
- **Wat namespace mirrors Rust module structure.** `src/types/enums.rs` → `:trading::types::*`, `src/vocab/market/standard.rs` → `:trading::vocab::market::standard::*`, etc.

## Architectural decisions pending

- **Post as a first-class wat struct, or implicit orchestration?** `pre-wat-native` has Post implicit — realized as a `Pipeline` struct inside `bin/wat-vm.rs` holding candle window + IndicatorBank + observer grid wiring. CLAUDE.md names Post as a distinct per-asset-pair orchestrator. The rewrite is an opportunity to promote it. Lean: **promote**. Wat's entire purpose is expressing domain logic without fighting Rust's syntax; keeping orchestration procedural in the binary is Rust-ergonomics territory, exactly what we built wat to exit. Resolve by Phase 8.
- **Enterprise as a first-class wat struct, or procedural in the binary?** Same shape as above. Resolve by Phase 8.
- **`wat-holon` sibling crate — when?** Atom / Bind / Bundle / Cosine / Permute / Thermometer / Reckoner / OnlineSubspace all live in `holon-rs`. The wat language has `:rust::*` + `#[wat_dispatch]` for consuming Rust crates (arc 013 precedent). Before Phase 3 opens, confirm: does wat-rs already ship `:wat::algebra::*` Atom / Bundle / Bind primitives that suffice? If yes, no sibling needed. If no, ship `wat-holon` as a sibling crate at `crates/wat-holon/` with `#[wat_dispatch]` wrapping holon-rs's public API.
- **Services shape.** `pre-wat-native/src/services/{queue, topic, mailbox}.rs` are three distinct messaging types (atom / one-to-many / many-to-one) over crossbeam. Wat ships `:wat::kernel::make-bounded-queue`, `send`, `recv`, `select`, `spawn`. Confirm at Phase 6 whether wat's substrate expresses all three shapes directly (likely yes for queue, maybe for mailbox via `select`, possibly not for topic fan-out) or whether new wat combinators are needed.

---

## Build order — leaves to root

Status markers:
- **ready** — dependencies satisfied; can be written now.
- **obvious in shape** — will be ready when the prior slice lands.
- **foggy** — needs design work before it's ready.

### Phase 0 — Scaffold

**0.1** — Fresh Cargo consumer crate at repo root using the arc 018 minimal form:
- `Cargo.toml` with `wat` dep (sibling path).
- `src/main.rs` → `wat::main! { deps: [] }` (one line, no deps yet — grows as `wat-holon` etc. ship).
- `tests/test.rs` → `wat::test! {}` (one line, defaults to `wat-tests/` + `"wat-tests"` loader scope).
- `wat/main.wat` — entry. Commits `(:wat::config::set-dims! 10000)` + `(:wat::config::set-capacity-mode! :error)` + defines `:user::main` (3-arg stdio contract). At first, body prints a hello string to prove the wiring.
- Empty `wat-tests/` sibling dir (tests added in Phase 9).
  
**Status: ready.**

**0.2** — **Shipped 2026-04-22** (`wat-rs fe3e422`). `wat-rs/docs/CONVENTIONS.md` gained an "App-owned top-level roots" subsection naming `:trading::*`, `:ddos::*`, `:mtg::*` as valid shapes alongside `:user::<app>::*`. Substrate already permitted this; the doc amendment records the convention before the first `:trading::*` type lands.

### Phase 1 — Types (zero internal deps)

All source files: `archived/pre-wat-native/src/types/`.

**Dependency reorder from original listing.** The initial survey put pivot at 1.7 and candle at 1.5; deeper read of candle.rs showed it references pivot's `PhaseLabel` / `PhaseDirection` / `PhaseRecord`. Actual dependency order: pivot before candle. Log_entry moves out of Phase 1 because it references `holon::kernel::vector::Vector` — not reachable from wat until a `wat-holon` sibling crate ships (Phase 3 territory).

**1.1** — **Shipped 2026-04-22** (`3390206`). `:trading::types::*` enums from `enums.rs` (260L). 8 sum types: `Side`, `Direction`, `Outcome`, `TradePhase`, `Prediction`, `ScalarEncoding`, `MarketLens` (11 variants), `RegimeLens`. Tagged variants (Prediction, ScalarEncoding) land with field types via wat's `(variant-name (field :Type) ...)` shape.

**1.2** — **Shipped 2026-04-22** (`09e7c4d`). `:trading::types::{TradeId,Price,Amount}` from `newtypes.rs` (149L) via `(:wat::core::newtype :name :Inner)` — wat's built-in nominal wrapper. **Correction on prior backlog note**: earlier entry claimed "wat has no newtype sugar per 058-030"; that was wrong — wat ships `:wat::core::newtype` directly.

**1.3** — **Shipped 2026-04-22** (`5a60286`). `:trading::types::{Asset,Ohlcv}` from `ohlcv.rs` (119L). First cross-file type reference (Ohlcv's source-asset / target-asset fields reference Asset).

**1.4** — **Shipped 2026-04-22** (`9c44860`). `:trading::types::{Distances,Levels}` from `distances.rs` (46L). Levels references the Price newtype from 1.2. The Rust `Distances::to_levels(price, side) -> Levels` conversion stays in the archive; it ships with its Phase 5 callers (treasury / simulation).

**1.5** — **Shipped 2026-04-22** (`267c84a`). `:trading::types::{PhaseLabel,PhaseDirection,PhaseRecord}` from `pivot.rs` (432L). Only the three value types; `PhaseState` streaming state machine shipped early via **lab arc 025 slice 2** (2026-04-25) at `wat/encoding/phase-state.wat` — the simulator's yardstick needed the trigger machinery before Phase 5 could justify materializing IndicatorBank. Sub-fog 1.7a (state-machine expressiveness in wat) resolved by that arc; archive's pivot.rs tests ported verbatim.

**1.6** — **Shipped 2026-04-22** (`dd32fda`). `:trading::types::Candle` from `candle.rs` (243L). 73 fields (identity + raw OHLCV + 60+ indicator scalars + 5 time scalars + 4 phase-labeler fields). Sub-fog 1.5a (struct field-count limit) **resolved** — the substrate freezes a 73-field struct cleanly. Indicator values stay `:f64` bare per the archive's `rune:forge(bare-type)` note.

**1.7** — **DEFERRED to Phase 3+** (was `:trading::types::LogEntry` from `log_entry.rs` (240L)). LogEntry references `holon::kernel::vector::Vector` in its `ProposalSubmitted.composed_thought` field; `Vector` isn't `#[wat_dispatch]`'d in wat-rs today. Ships with the `wat-holon` sibling crate in Phase 3.

**1.8** — **Shipped 2026-04-24** (lab arc 022, alongside the broker/portfolio vocab). `:trading::types::PortfolioSnapshot` from `archived/pre-wat-native/src/vocab/broker/portfolio.rs`'s 5-field struct (avg-age, avg-tp, avg-unrealized, grace-rate, active-count — all f64). Type ships retroactively at Phase 1 because the archive defined it inside the broker vocab file rather than under `src/types/`; the lab puts it in `wat/types/portfolio.wat` to keep the types directory authoritative for type defs. **Plural typealias** `:trading::types::PortfolioSnapshots = :Vec<trading::types::PortfolioSnapshot>` ships in the same file per arc 020's pattern (third lab-tier plural after PhaseRecords + Candles).

**1.9** — **Shipped 2026-04-24** (lab arc 023, alongside the exit/trade_atoms vocab). `:trading::types::PaperEntry` from `archived/pre-wat-native/src/trades/paper_entry.rs`'s 15-field struct. **First lab consumer of arc 049's newtype value semantics** — three Price fields (entry-price, trail-level, stop-level) properly typed via `(:Price/new f64)` construction. **First lab struct with `:wat::holon::HolonAST` fields** (composed-thought, market-thought, position-thought) — the wat-native shape replaces archive's `Vector` fields, since the substrate's `(ast-hash, d)`-keyed cache makes vector materialization implicit. The "Vector blocker" framing was Rust-tier reasoning leaking into the wat plan; the experiment under arc 023's directory (2026-04-24, 3 tests green) confirmed HolonAST round-trips through struct fields. Field-type deltas: archive `usize` → wat `:i64` for paper-id/age/entry-candle (per pivot.wat convention). Tick logic, constructor sugar, and is_grace?/is_violence?/is_runner? predicates ship with broker mechanics in Phase 5.

### Phase 2 — Vocabulary (pure functions over types)

Roughly 11 submodules under `archived/pre-wat-native/src/vocab/{market,exit,broker,shared}/`. Each is pure `encode_*_facts` functions that take a `Candle` and produce `ThoughtAST` fragments.

**Status: PHASE 2 VOCABULARY CLOSES with row 2.20 (lab arc 023, 2026-04-24). All 20 vocab modules shipped: market sub-tree COMPLETE (13/13), exit sub-tree COMPLETE (4/4: phase + regime + time + trade_atoms), broker sub-tree COMPLETE (1/1), shared sub-tree (2/2: helpers + time). Phase 3.5 (encoding dispatcher) is the next horizon.**

**Cross-sub-struct vocab signature rule (arc 008; leaf-name clarification in arc 011; closes task #49).** A vocab function's signature declares every sub-struct it reads, one parameter per sub-struct, **ordered alphabetically by the sub-struct's leaf (unqualified) type name**. `Scales` is the last parameter before the return type. Emission order inside the function body is independent — each module picks its own semantic order (often preserving the archive's). The rule continues arcs 001 – 007's "vocab reads its specific sub-struct" pattern from K=1 to K≥2 sub-structs; the dispatcher (Phase 3.5) extracts each vocab's declared sub-structs at one site and calls with exactly what's declared. Full derivation + rejected alternatives in `docs/arc/2026/04/008-market-persistence-vocab/DESIGN.md`; leaf-vs-full-path clarification in `docs/arc/2026/04/011-market-timeframe-vocab/DESIGN.md` (ordering is stable under future namespace reorganization). Subsequent cross-sub-struct arcs cite this rule and ship; they do not re-derive it.

**2.1 — Shipped 2026-04-23** (lab arc 001, `docs/arc/2026/04/001-vocab-opening/`). `:trading::vocab::shared::time::*` — port of `vocab/shared/time.rs` (113L). Two defines (`encode-time-facts` + `time-facts`), two file-private helpers (`circ`, `named-bind`). Rounding rationale captured: per-site `(f64::round val 0)` is cache-key quantization (proposals 057 + 033); for time, integer quantization is the honest granularity. **Design refinement surfaced:** vocab functions take the specific Candle sub-struct (here `:trading::types::Candle::Time`), not the full Candle. Matches `candle.wat`'s own header comment. Pattern established for all subsequent vocab modules. First lab-repo arc — adopted the wat-rs arc discipline (DESIGN + BACKLOG + INSCRIPTION). Six outstanding tests green on first pass, 19 → 25 lab wat tests.

**2.2 — Shipped 2026-04-23** (lab arc 002, `docs/arc/2026/04/002-exit-time-vocab/`). `:trading::vocab::exit::time::*` — port of `vocab/exit/time.rs` (76L). One define (`encode-exit-time-facts`) — 2 leaf binds (hour + day-of-week). Strict subset of shared/time for exit observers. **Shared helpers extracted:** `wat/vocab/shared/helpers.wat` now owns `:trading::vocab::shared::circ` + `:trading::vocab::shared::named-bind`, migrated from arc 001's file-private defines. Closes arc 001's deferred "extract when second caller surfaces" note. Every future vocab module loads `shared/helpers.wat` for the pair. Arc-001 template carried over cleanly; zero substrate gaps. Four outstanding tests green on first pass, 25 → 29 lab wat tests.

**2.3 — Shipped 2026-04-23** (lab arc 005, `docs/arc/2026/04/005-market-oscillators-vocab/`). `:trading::vocab::market::oscillators::encode-oscillators-holons` — port of `vocab/market/oscillators.rs` (84L). Eight holons per candle: four scaled-linear (rsi, cci, mfi, williams-r; thread `Scales` values-up) and four ReciprocalLog 2.0 (roc-1/3/6/12; fixed reciprocal-pair bounds). Returns `(Holons, Scales)` tuple. **Cave-quested wat-rs arc 034** mid-arc for the ReciprocalLog macro after an empirical `explore-log.wat` program revealed that the archive's single-arg Log (cosine-rotation, wrap-around) doesn't translate to 058-017's Thermometer-based Log at (1e-5, 1e5) bounds. The first-principles reciprocal-pair family `(1/N, N)` emerged from the observation; N=2 is the smallest member for ratio-valued ROC atoms. **Two latent-bug fixes along the way:** file-scope loads in test files scope to the file's own dir (not CARGO_MANIFEST_DIR) — helpers moved into the make-deftest default-prelude. scaled-linear.wat didn't self-load round.wat (shipped for weeks, masked by main.wat's load order) — fixed at source per arc 027's types-self-load pattern. Five outstanding tests green on first pass; 29 → 34 lab wat tests. Market sub-tree opens; 13 remaining.

**2.4 — Shipped 2026-04-23** (lab arc 006, `docs/arc/2026/04/006-market-divergence-vocab/`). `:trading::vocab::market::divergence::encode-divergence-holons` — port of `vocab/market/divergence.rs` (60L). **First conditional-emission vocab module.** Three atoms (rsi-divergence-bull, rsi-divergence-bear, divergence-spread), each emitting only when its guard fires. Variable-length `Holons` (0/1/2/3 per call). File-private `maybe-scaled-linear` helper threads `(holons, scales)` values-up through each maybe-emit step — the wat translation of archive's `facts.push(...)` pattern. **Named `:trading::encoding::VocabEmission`** alias when arc 006 became the second caller to emit `(Holons, Scales)`; pairs with arc 004's `ScaleEmission`. 14-swap migration across oscillators + divergence. Six tests green on first pass covering the emission truth-table (none/bull/bear/both) + shape + no-emit-preserves-scales. 34 → 40 lab wat tests. Market sub-tree: 2 of 14 shipped; conditional-emission pattern standing for trade_atoms + others.

**2.5 — Shipped 2026-04-23** (lab arc 007, `docs/arc/2026/04/007-market-fibonacci-vocab/`). `:trading::vocab::market::fibonacci::encode-fibonacci-holons` — port of `vocab/market/fibonacci.rs` (72L). Eight scaled-linear atoms from `Candle::RateOfChange`: three raw window positions (`range-pos-12/24/48`) plus five Fibonacci retracement distances (`fib-dist-236/382/500/618/786`), each computed as `range-pos-48 - level` then `round-to-2`. Simplest vocab shape so far — oscillators' pattern minus the Log tier minus the conditional tier; single sub-struct, all scaled-linear. **Cave-quested wat-rs arc 035** mid-test-writing when `(:wat::core::length updated-scales)` tripped type-check — `length` was Vec-only. Arc 035 promoted it to polymorphic over HashMap/HashSet/Vec, mirroring arc 025's pattern. Drive-by clippy recovery in `src/fork.rs` (arc 031 drift caught). Five tests green; 40 → 45 lab wat tests. Market sub-tree: 3 of 14 shipped.

**2.6 — Shipped 2026-04-23** (lab arc 008, `docs/arc/2026/04/008-market-persistence-vocab/`). `:trading::vocab::market::persistence::encode-persistence-holons` — port of `vocab/market/persistence.rs` (36L). **First cross-sub-struct vocab module.** Three scaled-linear atoms from two sub-structs: `hurst` + `autocorrelation` from `Candle::Persistence`, `adx` (normalized `/100.0`) from `Candle::Momentum`. **Names and exercises the cross-sub-struct signature rule** (closes task #49) — see the top-of-Phase-2 note above for the rule itself. Signature is `(m :Momentum) (p :Persistence) (scales :Scales) → :VocabEmission` — alphabetical by sub-struct type. 4/5 tests green on first pass; test #5 (different-candles-differ) surfaced a **scale-collision footnote**: first-call ScaleTracker rounding maps values in roughly [0.25, 0.75] to the same scale of 0.01, so same-scale inputs saturate identically in Thermometer encoding and coincide. Fix: pick values across the scale-rounding boundary (A=0.1 floors to 0.001, B=0.9 rounds to 0.02). Durable caveat for every future vocab arc with a "different candles differ" test. 45 → 50 lab wat tests. Market sub-tree: 4 of 14 shipped.

**2.7 — Shipped 2026-04-23** (lab arc 009, `docs/arc/2026/04/009-market-stochastic-vocab/`). `:trading::vocab::market::stochastic::encode-stochastic-holons` — port of `vocab/market/stochastic.rs` (36L). Second cross-sub-struct vocab; first module to ship entirely under arc 008's signature rule with no re-derivation. Four scaled-linear atoms: `stoch-k` + `stoch-d` (normalized `/100.0`) and `stoch-kd-spread` (computed) from `Candle::Momentum`; `stoch-cross-delta` (clamped to `[-1, 1]`) from `Candle::Divergence`. Signature `(d :Divergence) (m :Momentum) (scales)` — alphabetical. **Introduces the inline-clamp shape** for `.max(-1.0).min(1.0)` values via nested `if`; kept inline per stdlib-as-blueprint (single use). Extraction to `shared/helpers.wat` deferred until a second clamp caller surfaces (candidates: price_action, possibly regime's `variance_ratio.max(0.001)` though that's a one-sided floor). Arc 008's scale-collision footnote held on first try — test values chosen across scale boundary from the start. Five tests green on first pass. 50 → 55 lab wat tests. Market sub-tree: 5 of 14 shipped.

**2.8 — Shipped 2026-04-23** (lab arc 010, `docs/arc/2026/04/010-market-regime-vocab/`). `:trading::vocab::market::regime::encode-regime-holons` — port of `vocab/market/regime.rs` (83L). Single sub-struct (`Candle::Regime`, K=1). Eight atoms: seven scaled-linear (`kama-er`, `choppiness`, `dfa-alpha`, `entropy-rate`, `aroon-up`, `aroon-down`, `fractal-dim`) plus one ReciprocalLog for `variance-ratio`. **First non-N=2 use of arc 034's ReciprocalLog family**: N=10 bounds `(0.1, 10)` picked via empirical observation program `explore-log.wat` (on disk alongside DESIGN) — tabulated cosine-vs-reference-1.0 at N=2/3/10 for values 0.1-20. N=10 preserves the full variance-ratio financial range (mean-reverting ≤ 0.5 through trending ≥ 2.0 stay distinguishable) while collapsing noise near 1.0. Arc 005's N=2 was per-1%-near-1.0 for ROC; regime's domain is the mirror image (coarse-near-1, fine-across-range). **Confirms Chapter 35's observation reflex as permanent standing practice** — same pattern, different domain, landed the right answer first pass. Variance-ratio one-sided floor at 0.001 preserved via inline one-arm `if` (defensive marker; operationally moot at N=10's bounds). Six tests green on first pass including an explicit floor-behavior test. 55 → 61 lab wat tests. Market sub-tree: 6 of 14 shipped.

**2.9 — Shipped 2026-04-23** (lab arc 011, `docs/arc/2026/04/011-market-timeframe-vocab/`). `:trading::vocab::market::timeframe::encode-timeframe-holons` — port of `vocab/market/timeframe.rs` (59L). Third cross-sub-struct module; **first Ohlcv read in a vocab**. Six scaled-linear atoms, no Log: `tf-1h-trend` + `tf-4h-trend` + `tf-agreement` (round-to-2) from `Candle::Timeframe`, `tf-1h-ret` + `tf-4h-ret` (round-to-4) from `Candle::Timeframe`, `tf-5m-1h-align` (computed, round-to-4) from BOTH sub-structs. Signature `(o :Ohlcv) (t :Candle::Timeframe) (scales)` — **first arc to mix Candle::* sub-structs with non-Candle types**, surfacing the leaf-name clarification to arc 008's rule: alphabetical by LEAF (unqualified) type name, not full path. O < T. Introduces `round-to-4` helper in `encoding/round.wat` alongside `round-to-2` — second named digit-width (stdlib-as-blueprint holds until a third surfaces). `tf-5m-1h-align` is the first vocab atom whose VALUE (not just scope) crosses both sub-structs — `signum(tf-1h-body) × (close - open) / close`. Signum inline (single use, per arc 009's inline-clamp precedent). Six tests green on first pass including a symmetric-recompute verification of the cross-compute atom. 61 → 67 lab wat tests. Market sub-tree: 7 of 14 shipped.

**2.10 — Shipped 2026-04-24** (lab arc 013, `docs/arc/2026/04/013-market-momentum-vocab/`). `:trading::vocab::market::momentum::encode-momentum-holons` — port of `vocab/market/momentum.rs` (44L). Fourth cross-sub-struct module; **highest arity yet (K=4 sub-structs)**. Six atoms: five scaled-linear (`close-sma20`, `close-sma50`, `close-sma200`, `macd-hist`, `di-spread`) and one **plain `:wat::holon::Log`** for `atr-ratio`. Signature `(m :Candle::Momentum) (o :Ohlcv) (t :Candle::Trend) (v :Candle::Volatility) (scales)` — leaf-alphabetical M < O < T < V. **First lab plain-Log caller.** atr-ratio is asymmetric (always < 1, volatility-as-fraction-of-price); plain Log with bounds (0.001, 0.5) gives 2× Thermometer resolution vs ReciprocalLog 1000's wasted upper half. Lab now has both Log family forms in active use — plain Log for asymmetric domains, ReciprocalLog (arcs 005, 010) for symmetric-around-1 domains. **Substrate-discipline correction over archive port:** `round-to-4` for atr-ratio (not archive's `round-to-2`) — wat-rs's plain Log requires positive inputs; round-to-2 would collapse the 0.001 floor to 0.00 → ln(0). round-to-4 preserves the floor exactly. **Cross-sub-struct compute pattern recurrence** (close-sma20/50/200 + macd-hist all compute "field / close" across sub-struct pairs) — arc 011's "compute-atom helper?" question answered: yes recurrence is real, no helper isn't worth it yet (six let-bindings of the same shape are honest as repetition). Question moves to arc 014. Eight tests; seven first-pass; test 8 (different-candles-differ) fixed by widening values across the ScaleTracker round-to-2 boundary — arc 008's footnote in action again, threshold ≈ 0.25 minimum for the larger value documented in the INSCRIPTION. 72 → 80 lab wat tests (arc 012 shipped 67 → 72 in the gap between arcs 011 and 013). Market sub-tree: 8 of 14 shipped.

**2.11 — Shipped 2026-04-24** (lab arc 014, `docs/arc/2026/04/014-market-flow-vocab/`). `:trading::vocab::market::flow::encode-flow-holons` — port of `vocab/market/flow.rs` (47L). Eleventh Phase-2 vocab arc, fifth cross-sub-struct. **First K=3 module** (Momentum + Ohlcv + Persistence; signature alphabetical-by-leaf M < O < P). Six atoms: four scaled-linear (`vwap-distance`, `buying-pressure`, `selling-pressure`, `body-ratio`) and **two log-bound Thermometers** (`obv-slope`, `volume-ratio`). **Substrate-gap → algebraic-equivalence move:** `:wat::std::math` has `ln` but no `exp`. The archive's `Log(exp(x))` chain reduces to `Thermometer(x, -ln(N), ln(N))` — semantically identical, zero substrate cost. N=10 chosen to match arc 010's regime variance-ratio precedent; ships as best-current-estimate. (Arc 015 retired this Path B once wat-rs arc 046 shipped `math::exp`; flow.wat now uses the natural `(ReciprocalLog 10.0 (exp v))` form. The Path-B story stays in arc 014's INSCRIPTION as historical record.) **Range-conditional pattern named:** three atoms (buying-pressure, selling-pressure, body-ratio) guard `(field) / range` against zero-range candles. Compute `range` and `range-positive` once, branch per atom — different numerators and defaults (0.5 / 0.5 / 0.0) fight a shared helper, stay inline per stdlib-as-blueprint. Eight tests green on first pass — including a "range == 0 default" test exercising the conditional default branch (test 5). 80 → 88 lab wat tests. Market sub-tree: 9 of 14 shipped.

**2.12 — Shipped 2026-04-24** (lab arc 015, `docs/arc/2026/04/015-market-ichimoku-vocab/`). `:trading::vocab::market::ichimoku::encode-ichimoku-holons` — port of `vocab/market/ichimoku.rs` (61L). Twelfth Phase-2 vocab arc, sixth cross-sub-struct port, second K=3 module (Divergence + Ohlcv + Trend; signature alphabetical-by-leaf D < O < T). Six atoms: five scaled-linear (cloud-position, tk-cross-delta, tk-spread, tenkan-dist, kijun-dist) clamped to ±1, and one plain Log (cloud-thickness, asymmetric, bounds (0.0001, 0.5)). **Pivoted mid-arc from lab-userland helper extraction to substrate uplift.** Started planning to extract `clamp` and `f64-max` to `:trading::vocab::shared::*` (five clamp callers in ichimoku + arc 009 inline + four floor callers across arcs 010/013/014). Builder caught the framing — these are core, not userland. Pivoted to **wat-rs arc 046** which shipped `:wat::core::f64::max/min/abs/clamp` + `:wat::std::math::exp` as substrate primitives. Arc 015 resumed with substrate-direct calls; lab helpers never landed. **Cross-arc cleanup sweep along the way:** arc 009 stochastic's inline clamp + arc 010 regime's variance-ratio floor + arc 013 momentum's atr-ratio floor + arc 014 flow's inline abs all migrated to substrate primitives in this same arc. Plus arc 014's algebraic-equivalence Path-B retired to the natural form. Arc INSCRIPTIONs stay frozen as historical record; arc source code updates when a clean substrate replacement ships. **The "use the right thing now" principle named:** "why defer a migration if you have the correct thing now" — applies when the new substrate primitive is strictly better and migration is mechanical. Eight new ichimoku tests green first-pass; five cross-arc migrations zero-regression. 88 → 96 lab wat tests. Market sub-tree: 10 of 14 shipped.

**2.13 — Shipped 2026-04-24** (lab arc 016, `docs/arc/2026/04/016-market-keltner-vocab/`). `:trading::vocab::market::keltner::encode-keltner-holons` — port of `vocab/market/keltner.rs` (45L). Thirteenth Phase-2 vocab arc, seventh cross-sub-struct, K=2 (Ohlcv + Volatility; signature alphabetical-by-leaf O < V). Six atoms: five scaled-linear (`bb-pos`, `kelt-pos`, `squeeze` pure-Volatility round-to-2; `kelt-upper-dist`, `kelt-lower-dist` cross-Ohlcv-Volatility round-to-4) and one plain Log (`bb-width`, asymmetric, bounds (0.001, 0.5)). **First post-arc-046 pure substrate-direct vocab arc** — wrote the port using `:wat::core::f64::max` directly without any thinking about helpers; calibration check that arc 015's substrate-uplift work landed. **Third plain-Log caller** (after arc 013 atr-ratio + arc 015 cloud-thickness) — asymmetric-domain pattern now confirmed across three indicator families (volatility, cloud, channel-width); all three use bounds (0.001, 0.5) and round-to-4 for substrate-discipline floor preservation. Future fraction-of-price atoms inherit this shape without re-deriving. Seven tests green on first pass. 96 → 103 lab wat tests. Market sub-tree: 11 of 14 shipped.

**2.14 — Shipped 2026-04-24** (lab arc 017, `docs/arc/2026/04/017-market-price-action-vocab/`). `:trading::vocab::market::price-action::encode-price-action-holons` — port of `vocab/market/price_action.rs` (52L). Fourteenth Phase-2 vocab arc, eighth cross-sub-struct, K=2 (Ohlcv + PriceAction; signature alphabetical-by-leaf O < P). **Seven** atoms (one more than typical) — 4 scaled-linear (`gap` clamped via `f64::clamp`; `body-ratio-pa`, `upper-wick`, `lower-wick` range-conditional) + **3 plain Log** (`range-ratio`, `consecutive-up`, `consecutive-down`). **Biggest plain-Log surface yet across two domain shapes:** range-ratio joins the fraction-of-price family (4th caller); consecutive-up/down introduce a NEW count-starting-at-1 family with bounds `(1.0, 20.0)` (asymmetric, lower-bounded at 1.0, upper saturating at ~20 consecutive periods which is rare and meaningful for crypto 5m). **First lab `:wat::core::f64::min` consumer** — substrate primitive shipped in arc 046, finally finds a caller (lower-wick's `min(open, close) - low`). Second `f64::abs` caller (body-ratio-pa). First `f64::max` caller of two-free-values shape (upper-wick's `max(open, close)` — prior callers were all "value floored at constant"). Range-conditional pattern's sixth caller across two modules (flow + price-action); helper extraction still doesn't tip — defaults differ across modules (flow non-uniform, price-action uniform 0.0). Threshold rephrased: third module with same shape AND uniform defaults would tip. Eight tests green on first pass. 103 → 111 lab wat tests. Market sub-tree: 12 of 14 shipped (only `standard` remains in this sub-tree).

**2.15 — Shipped 2026-04-24** (lab arc 018, `docs/arc/2026/04/018-market-standard-vocab/`). `:trading::vocab::market::standard::encode-standard-holons` — port of `vocab/market/standard.rs` (166L). Fifteenth Phase-2 vocab arc. **Last market sub-tree vocab — market sub-tree COMPLETE (13 of 13).** Heaviest port + **first window-based vocab** (takes `Vec<Candle>`, not sub-struct slices; departs from arc 008/011's K-sub-struct rule by necessity — window aggregates need full candles). Eight atoms: 4 plain Log (since-rsi-extreme/since-vol-spike/since-large-move/session-depth, all count-starting-at-1 family with NEW bounds `(1.0, 100.0)` for window-spanning counts) + 4 scaled-linear (dist-from-high/low/midpoint/sma200, all cross-Ohlcv-Trend compute). Empty-window guard returns zero holons. **Bootstrapped two wat-rs substrate uplifts during sketch:** arc 047 (`last`, `find-last-index`, `f64::max-of`, `f64::min-of` + Vec accessors return Option) and arc 048 (user-enum value support — unblocks Phase construction in test fixtures). Each substrate arc shipped before arc 018 resumed; "natural-form-then-promote" rhythm at full strength. Plain-Log family now has THREE variants (fraction-of-price, count-small-window 1-20, count-full-window 1-100). 8 tests green first-pass after substrate landed. 111 → 119 lab wat tests. **Market sub-tree COMPLETE (13 of 13).**

**2.16 — Shipped 2026-04-24** (lab arc 019, `docs/arc/2026/04/019-exit-phase-vocab/`). `:trading::vocab::exit::phase::*` — ports the current-facts + scalar-facts functions from `vocab/exit/phase.rs` (348L); the third function (phase-rhythm, with stateful 5-way-index iteration + bigrams-of-trigrams + budget truncation) defers to arc 020 as its own piece of work. Sixteenth Phase-2 vocab arc. **First exit sub-tree vocab; first lab consumer of arc 048's user-enum match.** Three entries: `phase-label-name` helper (nested match on `PhaseLabel` + `PhaseDirection` → String, 5 possible outputs); `encode-phase-current-holons` (2 atoms — phase-label binding + phase-duration scaled-linear, reads Candle::Phase); `encode-phase-scalar-holons` (up to 4 atoms — valley-trend/peak-trend/range-trend/spacing-trend, each conditionally emitted based on history composition). **Conditional-emission with threaded accumulator** — scalar-facts threads a `(holons, scales)` tuple through four conj-or-skip steps; cleaner than per-condition sub-emission + concat. Arc 048's user-enum match landed cleanly under real lab load (5 match-arm tests green first-pass). 11 tests green first-pass. 119 → 130 lab wat tests. Exit sub-tree 1 of 4.

**2.17 — Shipped 2026-04-24** (lab arc 020, `docs/arc/2026/04/020-exit-phase-rhythm/`). `:trading::vocab::exit::phase::phase-rhythm-holon` — completes the exit/phase port (3 of 3 archive functions). Seventeenth Phase-2 vocab arc. **Stateful per-record Bundle construction via find-last-index per record (O(n²), n ≤ 103 by budget); avoids 5-tuple state thread.** Each record's Bundle: 5 base facts (label + 4 thermometer) + conditional +3 prior-deltas (i > 0) + conditional +3 same-label-deltas (find-last-index hit). Composition: window-3 records → Sequential trigrams → window-2 trigrams → plain-Bind pairs (NOT Bigram — archive omits Permute on the second) → Bundle pairs → wrap in `(Bind (Atom "phase-rhythm") <bundle>)`. Budget truncation at 100 pairs. **Empty-Bundle sentinel pattern reaffirmed** per arc 026 — singleton-Atom Bundle for the < 4 records case, since holon-rs's vector-layer bundle panics on empty input. Same-label-and-direction? predicate is itself an arc 048 user-enum match exercise (3-way nested PhaseLabel + PhaseDirection delegation). **Plural-via-typealias** shipped alongside per builder direction "expressivity wins": `:trading::types::PhaseRecords` for `:Vec<PhaseRecord>` + `:trading::types::Candles` for `:Vec<Candle>`. 25 callsites swept across phase + standard. 6 new rhythm tests + 4 same-label tests; 130 → 136 lab wat tests. Exit sub-tree: phase complete (1 of 4 vocab modules done).

**2.18 — Shipped 2026-04-24** (lab arc 021, `docs/arc/2026/04/021-exit-regime-vocab/`). `:trading::vocab::exit::regime::encode-regime-holons` — port of `vocab/exit/regime.rs` (84L). Eighteenth Phase-2 vocab arc; second exit sub-tree module. **Functionally identical to market/regime (arc 010)** — same 8 atoms (kama-er, choppiness, dfa-alpha, variance-ratio with ReciprocalLog 10.0, entropy-rate, aroon-up, aroon-down, fractal-dim), same encoding, same one-sided floor, same Scales contract. Only the namespace differs. **Honest wat translation: thin delegation, not a copy.** One define, body is `(:trading::vocab::market::regime::encode-regime-holons r scales)`. The archive duplicates the function body so the Rust dispatcher can route by name; wat preserves the same distinction via the namespaced path without duplicating identical logic. Future divergence (different floor, different bounds, exit-only atoms) replaces the body at that point. **Contract-only test scope** — three tests verify the delegation (holon count = 8, coincidence with market/regime on holon[0] at d=10000, scales count = 7); the full 8-atom truth-table tests live in arc 010 and aren't duplicated. **The thin-delegation idiom is named**: namespace-as-name makes "duplicate the function for namespace clarity" unnecessary. Likely recurs (broker/regime, broker/time); each future delegating module ships the same shape and cites this arc. 3 new tests green first-pass; 136 → 139 lab wat tests. Zero substrate gaps surfaced. Exit sub-tree: 2 of 4 modules done (phase + regime).

**2.19 — Shipped 2026-04-24** (lab arc 022, `docs/arc/2026/04/022-broker-portfolio-vocab/`). `:trading::vocab::broker::portfolio::portfolio-rhythm-asts` — port of `vocab/broker/portfolio.rs` (45L). Nineteenth Phase-2 vocab arc; **first broker sub-tree vocab.** Five `indicator-rhythm` calls over a snapshot window: `avg-paper-age`, `avg-time-pressure`, `avg-unrealized-residue`, `grace-rate`, `active-positions`. Each `(name, field-projection, vmin, vmax, delta-range)` tuple matches archive verbatim. **Blocker reassessment retired the wait** — the original "BLOCKED on PortfolioSnapshot + rhythm" note conflated this type's shape (5 plain f64) with PaperEntry's genuine `Vector` blocker; rhythm shipped as Phase 3.4 / arc 003. Both dependencies were met by the time arc 022 opened; reading the archive directly surfaced the misclassification. **PortfolioSnapshot ships alongside as Phase 1.8 retroactive.** 5-f64 struct + `:trading::types::PortfolioSnapshots` plural typealias (third lab-tier plural after PhaseRecords + Candles). **Result-typed return signature**: function returns `:Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>` per arc 032's BundleResult convention — five sequential `try`-unwraps inherit Result through the surrounding function. Err is unreachable at substrate-safe dims (indicator-rhythm trims internally) but type-system honest. 4 tests green first-pass (count, deterministic, different-windows-differ, short-window fallback); 139 → 143 lab wat tests. Zero substrate gaps surfaced. Broker sub-tree: 1 of 1 vocab module shipped (the only archive broker vocab; broker observer is Phase 5 logic, not vocab).

**2.20 — Shipped 2026-04-24** (lab arc 023, `docs/arc/2026/04/023-exit-trade-atoms-vocab/`). `:trading::vocab::exit::trade-atoms::compute-trade-atoms` + `select-trade-atoms` — port of `vocab/exit/trade_atoms.rs` (120L). Twentieth Phase-2 vocab arc. **Exit sub-tree COMPLETE (4 of 4); Phase 2 vocabulary CLOSES.** 13 atoms (5 Log + 8 Thermometer; no Scales threading) describing a paper trade's state: excursion, retracement, age, peak-age, signaled, trail/stop distances, R-multiple, heat, trail-cushion, plus 3 phase-biography atoms. **First lab consumer of arc 049's newtype value semantics** — reads `:trading::types::Price` fields via `:Price/0` accessor. **First lab vocab over a struct with `:wat::holon::HolonAST` fields** — PaperEntry's three thought fields come along for the ride (vocab function reads only mechanics fields). **Two latent blockers retired**: (a) "Vector field" framing was Rust-tier reasoning, not a wat substrate gap — the wat-native PaperEntry stores HolonAST and substrate caches vector materialization implicitly; experiment under arc 023's directory proved this 2026-04-24; (b) Price newtype inconstructibility closed via wat-rs arc 049 in the same session. **R-multiple Log family `(0.0001, 10.0)` introduced** — third active Log family in lab use (joining fraction-of-price and count-full-window); future trade-mechanics atoms with multiple-of-baseline shape inherit. Lens selector via two-arm exhaustive match on RegimeLens (Core → take 5; Full → all 13). 6 tests green first-pass after one comparison-op naming sweep (`:wat::core::f64::>` → `:wat::core::>`; substrate ops are polymorphic-over-numerics); 143 → 149 lab wat tests. Zero substrate gaps surfaced this arc (arc 049's prerequisites consumed cleanly). Exit sub-tree COMPLETE; **Phase 2 closes — 20 vocab modules ported**.

**Remaining vocab modules (each its own lab arc as it lands):**

- `vocab/market/standard.rs` (166L) — window-based, struct (StandardThought), HashMap<ScaleTracker> threading, Log + scaled-linear emission. Heaviest of the candidates.
- `vocab/market/oscillators.rs` (84L) — per-candle, no struct needed, mixed Log + scaled-linear. Good candidate for arc 002.
- `vocab/market/momentum.rs`, `flow.rs`, `persistence.rs`, `regime.rs`, `divergence.rs`, `ichimoku.rs`, `keltner.rs`, `stochastic.rs`, `fibonacci.rs`, `price_action.rs`, `timeframe.rs` — the remaining 11 market modules.
- `vocab/exit/phase.rs` (348L), `regime.rs`, `time.rs`, `trade_atoms.rs` — the exit observer's vocabulary.
- `vocab/broker/portfolio.rs` (45L) — may depend on types not yet ported.

Second-arc choice for the next slice probably sits between `oscillators.rs` (simpler, per-candle shape) and `standard.rs` (window-based, the archetype for the heavier market modules). Decision at that arc's DESIGN.

### Phase 3 — Encoding (AST schema)

Source: `archived/pre-wat-native/src/encoding/`.

- `thought_encoder.rs` (530L) — `ThoughtAST`, `ThoughtASTKind`, composition cache.
- `encode.rs` (302L) — dispatcher over vocab.
- `rhythm.rs` (200L) — builds rhythm ASTs from a candle window.
- `scale_tracker.rs` (142L) — tracks scale changes across windows.

**`wat-holon` question resolved.** No sibling crate needed. `wat-rs` ships `:wat::holon::*` (arc 022) — Atom, Bind, Bundle, Blend, Permute, Thermometer, cosine, dot, presence?, plus the ten wat-written idioms (Amplify, Subtract, Reject, Project, Sequential, Ngram, Bigram, Trigram, Log, Circular). That surface covers the archive's `ThoughtASTKind` variants. `Linear` maps to `Thermometer(value, -scale, scale)` (058-008 Linear REJECTED as redundant).

**3.1** — **Shipped 2026-04-22** (`33170ad`). `:trading::encoding::round-to-2` — one-line wrap of arc 019's `:wat::core::f64::round` primitive. Fixed digit-count at 2 per archive's `round_to(v, 2)` convention.

**3.2** — **Shipped 2026-04-22** (`ecb847b`). `:trading::encoding::ScaleTracker` — learned-scale EMA tracker. `/fresh`, `/update`, `/scale`, plus `/COVERAGE` + `/FLOOR` constants. Values-up: `update` returns a new tracker. Five tests green via the manual `run-sandboxed-ast` pattern (bypasses deftest's `:None`-scope hermetic sandbox).

**3.3** — **Shipped 2026-04-22**. `:trading::encoding::scaled-linear` — convenience helper that looks up a per-atom-name tracker, updates it, and returns a `Bind(Atom(name), Thermometer(value, -scale, scale))` fact with the updated `HashMap<String, ScaleTracker>`. Values-up: returns `(HolonAST, updated-scales)` tuple. Forcing function for `:wat::core::assoc` (arc 020) — HashMap put without which every values-up `HashMap` caller would be stuck. Four tests green. Archive's `Linear { value, scale }` maps cleanly to `Thermometer(value, -scale, scale)` — symmetric bounds around zero, width 2·scale.

**3.4** — **Shipped 2026-04-23.** `:trading::encoding::rhythm::indicator-rhythm` — builds rhythm ASTs from a candle window per archive semantics (facts → trigrams → bigram-pairs → budget-trimmed Bundle, Bind'd with the name atom). Six tests (deterministic, different-atoms-not-coincident, different-values-not-coincident, few-values-still-succeeds, prefix-beyond-budget-is-dropped, short-window-shape) all green at d=1024. Surfaced two cave-quests along the way: **arc 025** (Vec-indexing via polymorphic get/assoc/conj/contains?) was the Phase 3.4 compile unblock; the **Little-Schemer-null sentinel** `(:wat::holon::Atom (:wat::core::quote ()))` is the userland idiom for the substrate's empty-Bundle panic (captured in USER-GUIDE § 6 and arc 026's DESIGN). Bonus: **arc 026** (`eval-coincident?` family) shipped as a substrate primitive the evaluation story needed — not a blocker for 3.4 once the sentinel unblocked the test, but a real primitive for the distributed-by-construction shape. Both arcs shipped at wat-rs level same session. Full details in arc 025 + 026 INSCRIPTIONs.

**Phase 3 test retrofit — Shipped 2026-04-23** (lab arc 003, `docs/arc/2026/04/003-phase3-test-retrofit/`). `wat-tests/encoding/{scale_tracker,scaled-linear,rhythm}.wat` migrated from the pre-arc-027 manual `run-sandboxed-ast` + `:wat::test::program` shape to arc 031's `make-deftest` + inherited-config shape. 784 → 507 lines (−277, −35%); 18/18 tests still green on first pass. Zero semantic test changes, zero substrate work — the retrofit applies the substrate's ergonomic capability to tests that predated it. Helper-in-default-prelude pattern captured: when a single test needs a non-trivial helper, the factory's default-prelude is the honest place for it.

**Phase 3 naming sweep — Shipped 2026-04-23** (lab arc 004, `docs/arc/2026/04/004-lab-naming-sweep/`). Five /gaze-named moves in one arc: `:trading::encoding::Scales` typealias for the `HashMap<String, ScaleTracker>` registry; `:trading::encoding::ScaleEmission` typealias for scaled-linear's `(HolonAST, Scales)` return; lab-wide migration to wat-rs-arc-033's `:wat::holon::Holons`; vocab function renames `encode-*-facts` → `encode-*-holons` (the return type is Holons, the verb follows); test variable renames `facts` → `holons`. 79 swaps across 8 files (slice 1) + 50 swaps across 5 files (slice 2) + 3 FOUNDATION.md updates (slice 3). All 29 lab wat-tests green.

**3.5** — **Foggy.** `:trading::encoding::thought_encoder` (ThoughtAST, ThoughtASTKind, composition cache) + `:trading::encoding::encode` (dispatcher over vocab). Both depend on Phase 2 (vocab), which is still unstarted. Opens once vocab has a shape to dispatch over.

**3.3+ (arc 012) — Shipped 2026-04-23** (lab arc 012, `docs/arc/2026/04/012-geometric-bucketing/`). Substrate amendment to `scaled-linear`: replaces `round-to-2` value quantization with **geometric bucketing at `scale × noise-floor` width**. Each atom gets a cache-key grid matched to the substrate's actual discrimination resolution — `2√d` distinguishable positions per atom (200 at d=10k). Cave-quested from arc 011's scale-precision conversation; the builder's "Venn diagrams that are cache friendly" insight named the rule. Observation program `explore-bucket.wat` confirmed the math across large/medium/small scale regimes — round-to-2 over-splits for scale > 0.32 (cache misses with no gain) and under-splits for scale < 0.32 (cache hits hiding substrate-distinguishable differences). **Option B defensive fallback** in `::bucket`: if bucket-width ≤ 0, return value unchanged — absorbs the pre-existing `ScaleTracker::scale` quirk (`round(0.001, 2) = 0.00`) without changing observable behavior. Five new unit tests for the bucket function; all 67 prior lab tests pass unchanged (bucketing at mature scales shifts Thermometer inputs by less than noise-floor, so hand-built expecteds still coincide). 67 → 72 lab wat tests. Flagged follow-ups: scale-formula fix (separate arc), arc 013 (bidirectional cache via SimHash — formalizes the `Atom(integer)` family as an LSH anchor basis; BOOK Chapter 36 names the unification). Full INSCRIPTION + DESIGN + observation program on disk.

**Status: 3.1–3.4 shipped + 3.3 substrate amendment (arc 012 bucketing); 3.5 foggy.**

### Phase 4 — Learning (Reckoner + OnlineSubspace)

Source: `archived/pre-wat-native/src/learning/`.

- `engram_gate.rs` (200L) — prevents stale prediction reuse via state-subspace divergence.
- `window_sampler.rs` (130L) — per-observer log-uniform sampling.
- `scalar_accumulator.rs` (178L) — continuous label accumulation for reckoner training.

Depends on Phase 3's `wat-holon` decision. **Status: foggy.**

### Phase 5 — Domain (observers, broker, treasury, indicator bank)

Source: `archived/pre-wat-native/src/domain/`.

- `regime_observer.rs` (36L) — stateless middleware, `RegimeLens` only. Probably promoted ahead as a smoke test for the observer pattern.
- `market_observer.rs` (265L) — predicts Up/Down via holon Reckoner + OnlineSubspace + WindowSampler.
- `broker.rs` (170L) — binds one market + one regime observer. Gate reckoner, grace/violence counters.
- `treasury.rs` (815L) — capital allocation, papers, deadline scaling, three trigger paths.
- `lens.rs` (466L) — maps `MarketLens` / `RegimeLens` to vocab dispatch.
- `simulation.rs` (216L) — pure functions: trailing-stop mechanics, distance sweeps.
- `config.rs` (142L) — observer construction, lens choice, seeds, parameters.
- `ledger.rs` (140L) — SQL schema + dispatch. **Depends on `wat-rusqlite` sibling crate.**
- `candle_stream.rs` (136L) — Parquet source. **Depends on `wat-parquet` sibling crate.**
- `indicator_bank.rs` (2,365L) — streaming state machine over 100+ indicators. Architectural center. **Shipped 2026-04-25 via lab arc 026** (`docs/arc/2026/04/026-indicator-bank-port/`). 13 slices, ~3,300 LOC, 122 tests. ATR + AtrWindow + PhaseState arrived early via lab arc 025 slices 1-2 (the simulator's yardstick needed them); arc 026 ported the rest. **Lab arc 025** (`docs/arc/2026/04/025-paper-lifecycle-simulator/`) shipped same day — paper lifecycle simulator + Chapter-55 Thinker/Predictor split + label coordinates + cosine-vs-corners predictor + integration smoke. The yardstick is live: every Phase 4-9 port can now be measured against `:trading::sim::Aggregate` deltas.

**Status: foggy.** The remaining domain modules (observers, broker, treasury, simulation.rs trailing-stop variant, lens.rs, config.rs) sequence once Phase 4 (learning machinery — Reckoner + OnlineSubspace + WindowSampler) lands.

### Phase 6 — Services (CSP primitives)

Source: `archived/pre-wat-native/src/services/`. Queue / topic / mailbox.

**Sub-fog 6a:** audit whether wat substrate covers all three shapes. Queue is direct (`make-bounded-queue` + `send` / `recv`). Mailbox is likely `select` on receivers. Topic (one-to-many fan-out) may need a wat stdlib combinator or a spawned driver program.

**Status: foggy** until 6a resolves.

### Phase 7 — Programs (thread bodies)

Source: `archived/pre-wat-native/src/programs/`.

- `app/market_observer_program.rs` (340L)
- `app/regime_observer_program.rs` (162L)
- `app/broker_program.rs` (437L)
- `app/treasury_program.rs` (431L)
- `stdlib/cache.rs` (391L) — `wat-lru` already ships this surface; likely direct swap.
- `stdlib/database.rs` (627L) — needs `wat-rusqlite`.
- `stdlib/console.rs` (189L) — `:wat::std::program::Console` already ships this.
- `chain.rs` (55L) — `MarketChain`, `MarketRegimeChain` message types.

**Status: foggy.**

### Phase 8 — Orchestration (Post + Enterprise)

Resolve: promote to first-class wat structs, or mirror pre-wat-native's procedural-in-binary shape.

`bin/wat-vm.rs`'s Pipeline struct gets absorbed or stays.

**Status: foggy.** Decision upfront, implementation last.

### Phase 9 — Integration tests

Port 10 integration tests from `archived/pre-wat-native/tests/` — rhythm composition, incremental learning, real-data validation (652k BTC candle dataset at `data/analysis.db`).

**Status: foggy.**

---

## Cross-cutting sub-fogs

- **`wat-holon` sibling crate — ship before Phase 3?** Audit wat-rs's `:wat::algebra::*` surface first; if Atom/Bundle/Bind/Cosine/Permute/Thermometer suffice, no sibling needed. If the Reckoner + OnlineSubspace interfaces from holon-rs are not in wat-rs, ship them via `#[wat_dispatch]`.
- **`wat-rusqlite` sibling crate — ship before Phase 5 ledger / Phase 7 database?**
- **`wat-parquet` sibling crate — ship before Phase 5 candle_stream?**
- **Struct field count at Phase 1.5.** Does wat handle a ~90-field `Candle` struct cleanly? Verify before writing.
- **CLAUDE.md refresh.** After Phase 5 lands. Don't touch beforehand; treat as aspirational until the wat architecture is real.
- **Naming of `Asset` and `Ohlcv`.** `pre-wat-native` uses these; CLAUDE.md uses "RawCandle." Decide at Phase 1.3 which name stays.

---

## What this plan does NOT commit to

- Publishing `wat-holon` / `wat-rusqlite` / `wat-parquet` to crates.io. Path deps suffice for the rewrite; publishing comes later.
- A timeline. This is a backlog, not a schedule. Each phase lands when it's honestly ready.
- Touching CLAUDE.md before Phase 5.
- Retiring any Rust feature that pre-wat-native ships. Parity first; reductions only after the wat shape stabilizes.
- Porting the `experiments/` directory. Those six range/bucket files were not in the main build; they stay archived.

---

## Status at opening (2026-04-22)

Phase 0 (scaffold) and Phase 1.1 (enums) are ready to execute. Phases 1.2–1.7 obvious-in-shape once 1.1 lands. Everything past Phase 1 is scoped but foggy.

First commit: Phase 0.1 scaffold + 0.2 CONVENTIONS amendment + 1.1 enums in wat. Possibly split 0.2 into its own wat-rs commit so the amendment lands separately and the lab commit stays within the lab repo.

---

*This is the plan as we understand it today. It will change as slices land and surface what we didn't see. The arc discipline applies: when substrate gaps block an honest slice, pause, cut a cave quest (a sibling arc in wat-rs or a sibling crate), return.*

*PERSEVERARE.*
