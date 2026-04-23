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

**1.1** — `:trading::types::*` enums, from `enums.rs` (260L). 8 sum types: `Side`, `Direction`, `Outcome`, `TradePhase`, `Prediction`, `ScalarEncoding`, `MarketLens`, `RegimeLens`. Target: `wat/types/enums.wat`. **Status: ready.**

**1.2** — `:trading::types::*` newtypes, from `newtypes.rs` (149L). `TradeId`, `Price`, `Amount` as single-field wat structs (wat has no newtype sugar per 058-030; single-field struct is the idiom). Target: `wat/types/newtypes.wat`. **Status: obvious in shape.**

**1.3** — `:trading::types::Ohlcv` + `:trading::types::Asset`, from `ohlcv.rs` (119L). Target: `wat/types/ohlcv.wat`. **Status: obvious in shape.**

**1.4** — `:trading::types::Distances`, from `distances.rs` (46L). Target: `wat/types/distances.wat`. **Status: obvious in shape.**

**1.5** — `:trading::types::Candle`, from `candle.rs` (243L). Roughly 90 enriched-indicator fields. **Sub-fog 1.5a:** confirm no substrate limit on struct field count; likely fine but worth verifying before writing. Target: `wat/types/candle.wat`. **Status: obvious in shape.**

**1.6** — `:trading::types::LogEntry`, from `log_entry.rs` (240L). Seven variants, each carrying data — wat's enum-with-data form per 058-030. Target: `wat/types/log_entry.wat`. **Status: obvious in shape.**

**1.7** — `:trading::types::PhaseState` + `:trading::types::PhaseRecord`, from `pivot.rs` (432L). Streaming phase labeler (valley / peak / transition via ATR smoothing), Proposal 049. First non-trivial port — pure state-machine logic, substantive function bodies. **Sub-fog 1.7a:** verify wat's `let*` + tail-recursion handles the state machine cleanly, or surface substrate features as needed. Target: `wat/types/pivot.wat`. **Status: foggy until 1.1–1.6 land.**

### Phase 2 — Vocabulary (pure functions over types)

Roughly 11 submodules under `archived/pre-wat-native/src/vocab/{market,exit,broker,shared}/`. Each is pure `encode_*_facts` functions that take a `Candle` and produce `ThoughtAST` fragments.

First slice candidate: `vocab/market/standard.rs` (SMA20/50/200, simplest, ~80L).

Full list deferred until Phase 1 completes and the module shape is fixed. **Status: foggy.**

### Phase 3 — Encoding (AST schema)

Source: `archived/pre-wat-native/src/encoding/`.

- `thought_encoder.rs` (530L) — `ThoughtAST`, `ThoughtASTKind`, composition cache.
- `encode.rs` (302L) — dispatcher over vocab.
- `rhythm.rs` (200L) — builds rhythm ASTs from a candle window.
- `scale_tracker.rs` (142L) — tracks scale changes across windows.

**Forcing function.** This is where VSA primitives first become necessary. Resolve the `wat-holon` question before opening Phase 3.

**Status: foggy.**

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
