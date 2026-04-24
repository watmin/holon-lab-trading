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

**1.5** — **Shipped 2026-04-22** (`267c84a`). `:trading::types::{PhaseLabel,PhaseDirection,PhaseRecord}` from `pivot.rs` (432L). Only the three value types; `PhaseState` streaming state machine + its step / close_phase / begin_phase logic ships in Phase 5 on IndicatorBank where its callers live. Sub-fog 1.7a (from original listing — state-machine expressiveness in wat) defers to Phase 5.

**1.6** — **Shipped 2026-04-22** (`dd32fda`). `:trading::types::Candle` from `candle.rs` (243L). 73 fields (identity + raw OHLCV + 60+ indicator scalars + 5 time scalars + 4 phase-labeler fields). Sub-fog 1.5a (struct field-count limit) **resolved** — the substrate freezes a 73-field struct cleanly. Indicator values stay `:f64` bare per the archive's `rune:forge(bare-type)` note.

**1.7** — **DEFERRED to Phase 3+** (was `:trading::types::LogEntry` from `log_entry.rs` (240L)). LogEntry references `holon::kernel::vector::Vector` in its `ProposalSubmitted.composed_thought` field; `Vector` isn't `#[wat_dispatch]`'d in wat-rs today. Ships with the `wat-holon` sibling crate in Phase 3.

### Phase 2 — Vocabulary (pure functions over types)

Roughly 11 submodules under `archived/pre-wat-native/src/vocab/{market,exit,broker,shared}/`. Each is pure `encode_*_facts` functions that take a `Candle` and produce `ThoughtAST` fragments.

**Status: 2.1 + 2.2 + 2.3 + 2.4 + 2.5 + 2.6 + 2.7 + 2.8 shipped; rest foggy, open per-module.**

**Cross-sub-struct vocab signature rule (arc 008; closes task #49).** A vocab function's signature declares every sub-struct it reads, one parameter per sub-struct, ordered alphabetically by the sub-struct's type name. `Scales` is the last parameter before the return type. Emission order inside the function body is independent — each module picks its own semantic order (often preserving the archive's). The rule continues arcs 001 – 007's "vocab reads its specific sub-struct" pattern from K=1 to K≥2 sub-structs; the dispatcher (Phase 3.5) extracts each vocab's declared sub-structs at one site and calls with exactly what's declared. Full derivation + rejected alternatives in `docs/arc/2026/04/008-market-persistence-vocab/DESIGN.md`. Subsequent cross-sub-struct arcs cite this rule and ship; they do not re-derive it.

**2.1 — Shipped 2026-04-23** (lab arc 001, `docs/arc/2026/04/001-vocab-opening/`). `:trading::vocab::shared::time::*` — port of `vocab/shared/time.rs` (113L). Two defines (`encode-time-facts` + `time-facts`), two file-private helpers (`circ`, `named-bind`). Rounding rationale captured: per-site `(f64::round val 0)` is cache-key quantization (proposals 057 + 033); for time, integer quantization is the honest granularity. **Design refinement surfaced:** vocab functions take the specific Candle sub-struct (here `:trading::types::Candle::Time`), not the full Candle. Matches `candle.wat`'s own header comment. Pattern established for all subsequent vocab modules. First lab-repo arc — adopted the wat-rs arc discipline (DESIGN + BACKLOG + INSCRIPTION). Six outstanding tests green on first pass, 19 → 25 lab wat tests.

**2.2 — Shipped 2026-04-23** (lab arc 002, `docs/arc/2026/04/002-exit-time-vocab/`). `:trading::vocab::exit::time::*` — port of `vocab/exit/time.rs` (76L). One define (`encode-exit-time-facts`) — 2 leaf binds (hour + day-of-week). Strict subset of shared/time for exit observers. **Shared helpers extracted:** `wat/vocab/shared/helpers.wat` now owns `:trading::vocab::shared::circ` + `:trading::vocab::shared::named-bind`, migrated from arc 001's file-private defines. Closes arc 001's deferred "extract when second caller surfaces" note. Every future vocab module loads `shared/helpers.wat` for the pair. Arc-001 template carried over cleanly; zero substrate gaps. Four outstanding tests green on first pass, 25 → 29 lab wat tests.

**2.3 — Shipped 2026-04-23** (lab arc 005, `docs/arc/2026/04/005-market-oscillators-vocab/`). `:trading::vocab::market::oscillators::encode-oscillators-holons` — port of `vocab/market/oscillators.rs` (84L). Eight holons per candle: four scaled-linear (rsi, cci, mfi, williams-r; thread `Scales` values-up) and four ReciprocalLog 2.0 (roc-1/3/6/12; fixed reciprocal-pair bounds). Returns `(Holons, Scales)` tuple. **Cave-quested wat-rs arc 034** mid-arc for the ReciprocalLog macro after an empirical `explore-log.wat` program revealed that the archive's single-arg Log (cosine-rotation, wrap-around) doesn't translate to 058-017's Thermometer-based Log at (1e-5, 1e5) bounds. The first-principles reciprocal-pair family `(1/N, N)` emerged from the observation; N=2 is the smallest member for ratio-valued ROC atoms. **Two latent-bug fixes along the way:** file-scope loads in test files scope to the file's own dir (not CARGO_MANIFEST_DIR) — helpers moved into the make-deftest default-prelude. scaled-linear.wat didn't self-load round.wat (shipped for weeks, masked by main.wat's load order) — fixed at source per arc 027's types-self-load pattern. Five outstanding tests green on first pass; 29 → 34 lab wat tests. Market sub-tree opens; 13 remaining.

**2.4 — Shipped 2026-04-23** (lab arc 006, `docs/arc/2026/04/006-market-divergence-vocab/`). `:trading::vocab::market::divergence::encode-divergence-holons` — port of `vocab/market/divergence.rs` (60L). **First conditional-emission vocab module.** Three atoms (rsi-divergence-bull, rsi-divergence-bear, divergence-spread), each emitting only when its guard fires. Variable-length `Holons` (0/1/2/3 per call). File-private `maybe-scaled-linear` helper threads `(holons, scales)` values-up through each maybe-emit step — the wat translation of archive's `facts.push(...)` pattern. **Named `:trading::encoding::VocabEmission`** alias when arc 006 became the second caller to emit `(Holons, Scales)`; pairs with arc 004's `ScaleEmission`. 14-swap migration across oscillators + divergence. Six tests green on first pass covering the emission truth-table (none/bull/bear/both) + shape + no-emit-preserves-scales. 34 → 40 lab wat tests. Market sub-tree: 2 of 14 shipped; conditional-emission pattern standing for trade_atoms + others.

**2.5 — Shipped 2026-04-23** (lab arc 007, `docs/arc/2026/04/007-market-fibonacci-vocab/`). `:trading::vocab::market::fibonacci::encode-fibonacci-holons` — port of `vocab/market/fibonacci.rs` (72L). Eight scaled-linear atoms from `Candle::RateOfChange`: three raw window positions (`range-pos-12/24/48`) plus five Fibonacci retracement distances (`fib-dist-236/382/500/618/786`), each computed as `range-pos-48 - level` then `round-to-2`. Simplest vocab shape so far — oscillators' pattern minus the Log tier minus the conditional tier; single sub-struct, all scaled-linear. **Cave-quested wat-rs arc 035** mid-test-writing when `(:wat::core::length updated-scales)` tripped type-check — `length` was Vec-only. Arc 035 promoted it to polymorphic over HashMap/HashSet/Vec, mirroring arc 025's pattern. Drive-by clippy recovery in `src/fork.rs` (arc 031 drift caught). Five tests green; 40 → 45 lab wat tests. Market sub-tree: 3 of 14 shipped.

**2.6 — Shipped 2026-04-23** (lab arc 008, `docs/arc/2026/04/008-market-persistence-vocab/`). `:trading::vocab::market::persistence::encode-persistence-holons` — port of `vocab/market/persistence.rs` (36L). **First cross-sub-struct vocab module.** Three scaled-linear atoms from two sub-structs: `hurst` + `autocorrelation` from `Candle::Persistence`, `adx` (normalized `/100.0`) from `Candle::Momentum`. **Names and exercises the cross-sub-struct signature rule** (closes task #49) — see the top-of-Phase-2 note above for the rule itself. Signature is `(m :Momentum) (p :Persistence) (scales :Scales) → :VocabEmission` — alphabetical by sub-struct type. 4/5 tests green on first pass; test #5 (different-candles-differ) surfaced a **scale-collision footnote**: first-call ScaleTracker rounding maps values in roughly [0.25, 0.75] to the same scale of 0.01, so same-scale inputs saturate identically in Thermometer encoding and coincide. Fix: pick values across the scale-rounding boundary (A=0.1 floors to 0.001, B=0.9 rounds to 0.02). Durable caveat for every future vocab arc with a "different candles differ" test. 45 → 50 lab wat tests. Market sub-tree: 4 of 14 shipped.

**2.7 — Shipped 2026-04-23** (lab arc 009, `docs/arc/2026/04/009-market-stochastic-vocab/`). `:trading::vocab::market::stochastic::encode-stochastic-holons` — port of `vocab/market/stochastic.rs` (36L). Second cross-sub-struct vocab; first module to ship entirely under arc 008's signature rule with no re-derivation. Four scaled-linear atoms: `stoch-k` + `stoch-d` (normalized `/100.0`) and `stoch-kd-spread` (computed) from `Candle::Momentum`; `stoch-cross-delta` (clamped to `[-1, 1]`) from `Candle::Divergence`. Signature `(d :Divergence) (m :Momentum) (scales)` — alphabetical. **Introduces the inline-clamp shape** for `.max(-1.0).min(1.0)` values via nested `if`; kept inline per stdlib-as-blueprint (single use). Extraction to `shared/helpers.wat` deferred until a second clamp caller surfaces (candidates: price_action, possibly regime's `variance_ratio.max(0.001)` though that's a one-sided floor). Arc 008's scale-collision footnote held on first try — test values chosen across scale boundary from the start. Five tests green on first pass. 50 → 55 lab wat tests. Market sub-tree: 5 of 14 shipped.

**2.8 — Shipped 2026-04-23** (lab arc 010, `docs/arc/2026/04/010-market-regime-vocab/`). `:trading::vocab::market::regime::encode-regime-holons` — port of `vocab/market/regime.rs` (83L). Single sub-struct (`Candle::Regime`, K=1). Eight atoms: seven scaled-linear (`kama-er`, `choppiness`, `dfa-alpha`, `entropy-rate`, `aroon-up`, `aroon-down`, `fractal-dim`) plus one ReciprocalLog for `variance-ratio`. **First non-N=2 use of arc 034's ReciprocalLog family**: N=10 bounds `(0.1, 10)` picked via empirical observation program `explore-log.wat` (on disk alongside DESIGN) — tabulated cosine-vs-reference-1.0 at N=2/3/10 for values 0.1-20. N=10 preserves the full variance-ratio financial range (mean-reverting ≤ 0.5 through trending ≥ 2.0 stay distinguishable) while collapsing noise near 1.0. Arc 005's N=2 was per-1%-near-1.0 for ROC; regime's domain is the mirror image (coarse-near-1, fine-across-range). **Confirms Chapter 35's observation reflex as permanent standing practice** — same pattern, different domain, landed the right answer first pass. Variance-ratio one-sided floor at 0.001 preserved via inline one-arm `if` (defensive marker; operationally moot at N=10's bounds). Six tests green on first pass including an explicit floor-behavior test. 55 → 61 lab wat tests. Market sub-tree: 6 of 14 shipped.

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

**Status: 3.1–3.4 shipped; 3.5 foggy.**

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
- `indicator_bank.rs` (2,365L) — streaming state machine over 100+ indicators. Architectural center. The monster.

**Status: foggy.** Sequence once Phase 4 lands. `indicator_bank.rs` may warrant its own sub-phase.

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
