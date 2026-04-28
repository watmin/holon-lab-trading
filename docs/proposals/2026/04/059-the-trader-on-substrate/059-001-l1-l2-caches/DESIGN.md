# 059-001 — L1/L2 caches on the new substrate

**Status:** PARTIAL 2026-04-29. Cache primitives shipped; cache **integration** (thinker-side consumption + telemetry Reporter + probe-tests T4–T8) is the remaining work. See § What's done and § What remains.

**Reframe history:**
- PROPOSED 2026-04-27.
- Reframed 2026-04-27 (proof 018 → templates → coordinate cells).
- Reframed 2026-04-28 (v3) after wat-rs arc 074 + slice 2 shipped: substrate exposed `:wat::holon::Hologram` and `:wat::holon::HologramLRU`. v3 replaced the proposed `FuzzyCache<V>` primitive with the substrate-shipped LRU sibling.
- Reframed 2026-04-29 (v4) after the cache lineage shipped its tail through arcs 076 / 077 / 078. Three surface changes that this DESIGN must reflect:
  1. **Type rename.** `:wat::holon::HologramLRU` → `:wat::holon::lru::HologramCache` (arc 078 slice 1). The "LRU" qualifier moved from type name to namespace; the type name describes what the thing IS. See [`wat-rs/docs/arc/2026/04/078-service-contract/INSCRIPTION.md`](../../../../../../wat-rs/docs/arc/2026/04/078-service-contract/INSCRIPTION.md).
  2. **Service.wat lifted to substrate.** What was originally lab-specific (`:trading::cache::Service`) became the canonical service-contract substrate (`:wat::holon::lru::HologramCacheService`) under arc 078 slice 2. The lab's `wat/cache/Service.wat` is **deleted**; the lab's `wat/cache/L2-spawn.wat` now delegates spawn to the substrate type. See [`wat-rs/docs/CONVENTIONS.md`](../../../../../../wat-rs/docs/CONVENTIONS.md) "Service contract — Reporter + MetricsCadence" section.
  3. **Telemetry contract changed.** The original DESIGN had Service.wat owning counters, running `:trading::log::tick-gate` inline, and emitting `LogEntry::Telemetry` directly. The substrate's Reporter + MetricsCadence contract inverts this: substrate emits typed `Report::Metrics` events; the lab supplies a Reporter fn that match-dispatches those to whatever sink it wants (rundb, CloudWatch, stdout). § E rewritten to the new contract.

These shifts kept the *intent* of the cache architecture intact while moving the implementation seam: most of what was originally listed as lab-side work is now substrate-shared work that any consumer (this lab, future MTG / truth-engine consumers) gets for free.

## Progress (2026-04-29)

The progress accounting splits cleanly into "primitives shipped" (with substrate help) and "integration not started":

### What's done

| Surface | Path | State |
|---|---|---|
| L1 cache | `wat/cache/L1.wat` | ✅ shipped. 9 deftests green: make-empty / put-get-next / put-get-terminal / cache-isolation / len-counts-both / lookup-terminal-direct / lookup-chain-via-next / lookup-empty-returns-none / **lru-eviction-at-cap** (T6 partial — L1 eviction observable through the wrapper). |
| Walker | `wat/cache/walker.wat` | ✅ shipped. 4 deftests green: terminal-hit / chain-via-next / walk-on-already-terminal / walk-fills-cache. Visitor records each `StepResult` variant into L1. Per-step pos provenance is moot post-arc-076 (substrate routes by form structure inside Hologram). |
| L2 paired spawner | `wat/cache/L2-spawn.wat` | ✅ shipped. 2 deftests green: paired-spawn-roundtrip / caches-isolated. The lab's `:trading::cache::L2` struct (cache-next + cache-terminal under domain-meaningful field names) survives as a thin policy wrapper; spawn delegates to `:wat::holon::lru::HologramCacheService/spawn`. |
| Cache service shell | (substrate) | ✅ shipped via arc 078 slice 2 as `:wat::holon::lru::HologramCacheService` — the lab no longer owns this code. The substrate covers the full request/reply round-trip, multi-client HandlePool fan-in, LRU eviction visibility, and the Reporter + MetricsCadence telemetry contract. Six substrate-side step tests cover the equivalent of what was the lab's Service.wat suite. |
| Probe T1–T3 | wat/cache/walker tests | ✅ covered (terminal-hit / next-chain / walk-on-already-terminal). |
| Probe T6 (partial) | wat-tests/cache/L1.wat | ✅ L1-side eviction covered (`test-lru-eviction-at-cap`). L2-side eviction visibility through the service wrapper is covered by substrate's `test-step6-lru-eviction-via-service`. The cross-cutting "both layers in one test" version under thinker integration is still pending. |

### What remains

The cache exists. The cache is not used. A grep for `trading::cache::*` callers outside `wat/cache/` itself returns zero — no thinker, no observer, no broker invokes the resolve-walker or holds an L1 instance. Until a hot path consumes the cache, T7 (telemetry rows in rundb) and T8 (≥272 candles/sec on a 10k run, the **acceptance gate**) cannot be measured.

The remaining work is integration, not primitives:

| Item | Owner | Notes |
|---|---|---|
| Reporter implementation | lab | Lab writes a `:wat::holon::lru::HologramCacheService::Reporter` fn that match-dispatches `Report::Metrics stats` → `:trading::log::LogEntry::Telemetry` rows + flushes via `:trading::rundb::Service/batch-log`. Replaces what was originally inline in Service.wat. |
| MetricsCadence wiring | lab | Pick a gate type. Existing `:trading::log::tick-gate` operates over `wat::time::Instant`; build a `MetricsCadence<wat::time::Instant>` wrapping it. 5000ms default still applies. |
| Stats counter set decision | lab | Substrate ships 5 counters (lookups, hits, misses, puts, cache-size). DESIGN § E originally listed 9 (added: evictions, ns_gets, ns_sets, gets_serviced, sets_drained). Three options: (a) live with 5; (b) extend substrate Stats (substrate arc — eviction is interesting cross-consumer signal); (c) wrap timing in the Reporter without touching substrate. See § E. |
| L1 telemetry path | lab | Substrate models service telemetry only. L1 is thread-owned, not a service — no substrate Reporter applies. Either build a parallel L1 metric pump in the thinker (using `:trading::log::tick-gate` + `LogEntry::Telemetry` directly) or accept L1 as silent for slice 1 and add it as a follow-up. |
| Thinker hot-path integration | lab | Wire `:trading::cache::resolve` (or its post-arc-078 successor) into the thinker so a real run exercises the cache. T4 / T5 (cross-thinker promotion) require this. |
| Probe tests T4–T8 | lab | `wat-tests-integ/059-001-l1-l2-caches/` directory exists but is **empty**. T4/T5 (cross-thinker), T7 (telemetry rows), T8 (throughput gate) all unblocked once the integration items above land. |

**Substrate finding logged in source.** `:wat::holon::lru::HologramCache`'s underlying `:wat::lru::LocalCache` is thread-owned (lives in a `ThreadOwnedCell`), so a spawned worker holding one cannot return the cache through `join-result` and have the caller invoke methods on it. Substrate's `HologramCacheService/run` wraps `loop` in a thunk that drops the cache on the worker thread and returns `:()` — the spawn-handle type is `ProgramHandle<()>`. Live state is observable only through `Get` queries during operation. This is the same shape as `:wat::lru::CacheService`; both substrate cache services follow this discipline. Record-keeping note in case follow-up work reaches for cache-as-return-value and finds it absent.

**Acceptance gate (T8 throughput) is not yet measurable** — needs the integration items above. Acceptance criteria below stand unchanged.

**Umbrella:** [`docs/proposals/2026/04/059-the-trader-on-substrate/`](../).

**Predecessors:**
- Substrate: arc 057 (typed HolonAST leaves), arc 058
  (`HashMap<HolonAST, V>`), arc 068 (`:wat::eval-step!`), arc 070
  (`:wat::eval::walk`).
- Cache lineage (the chain that produced everything this slice now
  builds on):
  - arc 074 — `Hologram` (unbounded coordinate-cell store) + `HologramLRU` (bounded sibling). The shipped abstraction.
  - arc 076 — therm-routed Hologram + filtered-argmax. Routing moved INTO the type; no caller-supplied pos.
  - arc 077 — kill the dim router. One program-d, capacity at the call site.
  - arc 078 — service contract. `HologramLRU` → `:wat::holon::lru::HologramCache`; `:wat::holon::lru::HologramCacheService` lifted from this lab's original Service.wat into substrate; canonical Reporter + MetricsCadence contract codified in CONVENTIONS.md.
- Lab proposal 057 (L1/L2 cache + parallel subtree compute) —
  approved with conditions; this sub-arc executes that design on the
  new substrate.
- Proofs: 015 (expansion-chain), 016 (dual-LRU coordinate cache —
  exact-keyed v4), 017 (fuzzy-locality cache via `coincident?`), 018
  (flat-fuzzy reference; superseded by HologramCache's coordinate-cell
  shape).
- BOOK chapters 59 (the dual-LRU named), 65 (the hologram), 66 (the
  fuzziness), 67 (the spell), 68 (the inscription), 70 (Jesus built
  my hotrod — the recognition that drove arc 074).

**Performance contract:** ≥272 candles/sec sustained on a 10k
representative run after this slice ships.

---

## Why this slice first

The umbrella's chapter-65/66/67 claims rest on the cache being
operational. Without it, the substrate's distinctive properties
(forms-as-coordinates, locality-keyed neighborhoods, walker
cooperation) are decorative. With the cache wired, every subsequent
slice's thinker code automatically benefits from work-sharing — both
within a thinker and across thinkers.

The user's framing: *"the cache is required no matter what — it's an
optimization that we must deliver on — not having it is
disingenuous… the queues and services we've built are things in our
cookbook."*

Slice 1 wires the cookbook. Subsequent slices stand on it.

---

## What's already there (substrate-provided)

| Surface | Where | Notes |
|---------|-------|-------|
| `:wat::holon::Hologram` | wat-rs core (arc 074 slice 1). | Coordinate-cell store with cosine readout. HolonAST → HolonAST. Unbounded. Routing inside the type as of arc 076 (no caller-supplied pos). |
| `:wat::holon::lru::HologramCache` | `crates/wat-holon-lru/` (arc 074 slice 2; renamed by arc 078 slice 1). | Bounded sibling. Pure-wat composition: `Hologram` + `wat::lru::LocalCache`. LRU eviction + cosine readout + cell isolation. HolonAST → HolonAST. |
| `:wat::holon::lru::HologramCacheService` | `crates/wat-holon-lru/` (arc 078 slice 2). | Queue-addressed wrapper over `HologramCache`. Owns the cache for the worker thread's lifetime; ships the canonical service contract (Reporter + MetricsCadence + null-helpers + typed Report enum). What was originally `wat/cache/Service.wat` in this DESIGN. |
| `:wat::lru::LocalCache<K, V>` | wat-lru. | Eviction-aware put returns `Option<(K, V)>`. Used by the lab's encode-cache (HolonAST → Vector — exact lookup, no fuzz). |
| `:wat::lru::CacheService<K,V>` | wat-lru. | Generic `K,V` queue-addressed cache; retrofitted to the same Reporter + MetricsCadence contract by arc 078 slice 4. Not used by this slice (the lab's caches are HolonAST → HolonAST and want fuzzy readout); listed for symmetry with the contract. |
| `:wat::holon::Hologram/coincident-get` / `present-get` | wat-stdlib convenience getters. | The lab's hot path uses these (no filter-construction at call sites). |
| `:wat::eval-step!` (arc 068) | substrate. | The stepper. The cache-aware walker calls it on miss. |
| `:wat::eval::walk` (arc 070) | substrate. | The fold over `eval-step!` — the structure the cache-aware walker mirrors. |
| `:trading::log::tick-gate` | lab `wat/io/log/rate-gate.wat`. | Values-up rate gate; one tick per loop iteration; "open" every N ms. Reused as the body of the lab's `MetricsCadence<wat::time::Instant>` tick fn. |
| `:trading::log::LogEntry::Telemetry` | lab `wat/io/log/schema.wat`. | CloudWatch-style metric variant, batched through rundb. The Reporter writes these. |
| `:trading::rundb::Service/batch-log` | lab `wat/io/RunDbService.wat`. | The metric pump destination. The Reporter flushes through it. |

**Substrate gaps all closed.** v2 listed `LocalCache::len` as a substrate prerequisite (shipped arc 036). v2 also proposed a lab-side `:trading::cache::Service`; arc 078 lifted that into substrate. The remaining work for this slice is entirely lab-side integration — no wat-rs arcs need to ship.

---

## What this slice integrates

### A — The cache primitive (substrate-provided)

`:wat::holon::lru::HologramCache` is the cache. **HolonAST → HolonAST.** Not parametric. The trader's two caches (next, terminal) both use this type directly. Every HolonAST IS its own vector (deterministically, through the substrate's encoder); HologramCache's `find-best` re-encodes candidate keys per get, no separate vector cache layer needed. The existing `:trading::sim::EncodeCache` (a `LocalCache<HolonAST, Vector>`) memoizes encoding for code paths outside HologramCache that need explicit Vectors — a separate concern; not load-bearing for this slice; stays as-is.

Per-cell capacity defaults to `floor(sqrt(d))` (the algebra grid's resolution limit at d). At d=10000, that's 100 cells. The global LRU cap is the per-call argument to `HologramCache/make filter cap`; a reasonable default at d=10000 is `cap=10000` (~100 entries per cell on average). Post-arc-077, d is ambient via `:wat::config::set-dim-count!`; HologramCache reads it.

### B — The two coordinate caches (lab-side policy wrappers)

The lab keeps its `:trading::cache::L1` and `:trading::cache::L2` structs as **thin policy wrappers** over the substrate primitive. The structs encode the trading-app's specific policy (pair-of-caches, named next/terminal); the cache implementation is substrate.

Both fields are `:wat::holon::lru::HologramCache`. Both keyed by HolonAST. Both HolonAST → HolonAST.

| Cache | Stored | What it serves |
|---|---|---|
| `next-cache` | `(form-h → next-h)` | "what's the next form after one rewrite?" — path edges |
| `terminal-cache` | `(form-h → terminal-h)` | "what's this form's terminal value?" — answers (Ch.59: terminals are AST coordinates) |

A walker landing on a coordinate where `next` is known but `terminal` isn't has discovered **partial work**. Fuzzy hits via cosine readout expand work-sharing across coincident neighborhoods.

### C — Two layers (L1 + L2), same primitive

**L1 (per-thinker, thread-owned):**

Each thinker owns a `:trading::cache::L1` instance — a `(next, terminal)` pair of `HologramCache`s — threaded through its tail-recursive loop. HologramCache is thread-owned mutable; the thinker holds the L1 struct directly. No Mutex, no queue, no service.

**L2 (process-wide, queue-addressed):**

`:trading::cache::L2` wraps two `:wat::holon::lru::HologramCacheService` spawns — one for next, one for terminal. Each service owns its own `HologramCache` and runs its own driver thread; clients reach them through per-cache `HandlePool<ReqTx>` instances popped from the L2 struct.

The lab does **not** ship its own service code. Spawn delegates to substrate's `:wat::holon::lru::HologramCacheService/spawn count cap reporter metrics-cadence`. The same reporter + metrics-cadence pair flows into both spawns; each service runs its own cadence-gate independently.

### D — The walker (`:trading::cache::resolve`)

`:trading::cache::resolve` is the cache-aware substitute for "encode
a form" in the thinker's hot path. Same idea as proof 018's reference,
adapted to HologramCache's coordinate-cell shape:

```
resolve(form-h, l1, l2):
  ;; 1. Terminal cache lookup. Hit ends the walk.
  on HologramCache/get(l1.terminal-cache, form-h) → Some(t):
    return t

  ;; 2. Next-form cache lookup. Hit short-circuits one or more steps.
  on HologramCache/get(l1.next-cache, form-h) → Some(next-h):
    return resolve(next-h, l1, l2)

  ;; 3. Both miss — invoke :wat::eval::walk on the form.
  ;;    The visit-fn fires once per coordinate; it RECORDS into both
  ;;    caches as the walk progresses, and returns Continue.
  case :wat::eval::walk(to-watast(form-h), l1, record-coordinate):
    Ok((terminal, l1')): return terminal
    Err(_e): fall back to eval-ast! (without caching)
```

(L1.wat as shipped exposes `:trading::cache::L1/lookup` for the cache-only chain walk and `:trading::cache::L1/get-next` / `get-terminal` for the per-cache helpers; the resolve entry point ties the L1 lookup to the walker fallback. Walker.wat as shipped writes to L1 unconditionally; L2 writes are added during milestone 3.)

The visit-fn writes per-step:
- `Next next-h` → record `(form-h → next-h)` in next-cache
- `Terminal t` → record `(form-h → t)` in terminal-cache
- `AlreadyTerminal t` → record `(t → t)` in terminal-cache (idempotent)

L1 writes happen unconditionally (cheap, thread-local). L2 writes go
through the service queue per step. (Batching L2 is a follow-up arc
if profiling demands.)

`:wat::eval::walk`'s `Skip` variant is unused here — short-circuit
logic happens in step 1 / step 2 BEFORE walk is invoked.

**`pos` provenance.** Per arc 076, routing happens INSIDE `Hologram` — the substrate inspects the key's structure (Thermometer inside → bracket-pair lookup; non-therm → slot 0). Callers don't pass `pos`. The L1.wat / walker.wat as shipped already follow this discipline. Earlier versions of this DESIGN that referenced caller-supplied `pos` predate arc 076; the surface in `wat/cache/L1.wat` is the source of truth.

### E — Telemetry (the substrate's service contract)

This section was rewritten 2026-04-29 to match the post-arc-078 reality. The original telemetry plan baked counters, the tick-gate, and `LogEntry::Telemetry` emission directly into a lab-owned Service.wat. Arc 078 lifted the service shell into substrate as `:wat::holon::lru::HologramCacheService` and replaced the inline-telemetry approach with a **callback contract**: the substrate emits typed events; the consumer dispatches them.

#### How the contract works

The substrate ships these elements (full recipe in [`wat-rs/docs/CONVENTIONS.md`](../../../../../../wat-rs/docs/CONVENTIONS.md) "Service contract — Reporter + MetricsCadence"):

- `:wat::holon::lru::HologramCacheService::Stats` — counter struct (lookups / hits / misses / puts / cache-size).
- `:wat::holon::lru::HologramCacheService::Report` — typed enum of outbound events. Slice-1 ships only `(Metrics stats)`. Future variants (Error / Evicted / Lifecycle) extend additively.
- `:wat::holon::lru::HologramCacheService::Reporter` = `:fn(Report) -> :()` — match-dispatching consumer, supplied by the lab.
- `:wat::holon::lru::HologramCacheService::MetricsCadence<G>` = `{gate :G, tick :fn(G,Stats) -> :(G,bool)}` — stateful rate gate. The user picks `G`; the substrate threads it through every loop iteration.

The substrate's loop calls `tick-window` after each request: it advances the cadence's gate, and when `tick` returns `(_, true)` it stamps `cache-size` onto the stats and calls the Reporter with `(Report::Metrics final-stats)`, then resets stats.

Both injection points are non-negotiable. Pass `:wat::holon::lru::HologramCacheService/null-reporter` and `(:wat::holon::lru::HologramCacheService/null-metrics-cadence)` for the explicit "no reporting" choice.

#### What the lab supplies

```scheme
;; The lab's Reporter — converts substrate's typed event into rundb rows.
(:wat::core::define
  (:trading::cache::reporter
    (report :wat::holon::lru::HologramCacheService::Report) -> :())
  (:wat::core::match report -> :()
    ((:wat::holon::lru::HologramCacheService::Report::Metrics stats)
      ;; Build Vec<LogEntry::Telemetry> from stats; flush via rundb.
      (:trading::cache::flush-stats-to-rundb stats))))

;; The lab's MetricsCadence — wraps :trading::log::tick-gate with G = Instant.
(:wat::holon::lru::HologramCacheService::MetricsCadence/new
  (:wat::time::now)
  (:wat::core::lambda
    ((g :wat::time::Instant) (_s :Stats) -> :(wat::time::Instant,bool))
    (:trading::log::tick-gate g 5000)))
```

The lab still owns the *destination* — `:trading::log::LogEntry::Telemetry` rows flushed via `:trading::rundb::Service/batch-log`. What changed is the seam: substrate now decides WHEN to fire (cadence) and WHAT shape to fire (typed Report); lab decides WHERE the data goes.

#### Counter set decision (open)

The substrate's `Stats` struct ships **5** counters:

| Metric | Unit | Source |
|---|---|---|
| `lookups` | Count | total `get` requests in the window |
| `hits` | Count | gets returning Some |
| `misses` | Count | gets returning :None |
| `puts` | Count | total `put` requests in the window |
| `cache-size` | Count | `HologramCache/len` at gate-fire time |

Original DESIGN listed **9** counters — the additional four (`evictions`, `ns_gets`, `ns_sets`, `gets_serviced`/`sets_drained`) are not yet shipped.

Three options for closing the gap:
1. **Live with 5 for slice 1.** Ship the integration; surface the counter-set decision when the operator actually needs the absent metrics.
2. **Extend substrate Stats.** New arc against wat-rs to add `evictions` (interesting cross-consumer signal — both substrate cache services would benefit) and possibly the timing counters. Riskier — touches the substrate Report enum's existing variant.
3. **Wrap timing in the Reporter.** The Reporter sees every `Report::Metrics` event; it can compute time-between-fires and divide work-counts by elapsed-time to derive throughput counters without substrate involvement. Doesn't help with `evictions` (substrate doesn't currently expose eviction events).

Default position for slice 1: **(1)**. Defer (2) and (3) until a real telemetry consumer surfaces a concrete need.

#### L1 telemetry (open)

L1 is thread-owned, not a service — there's no substrate Reporter contract that applies. The original DESIGN expected L1 to emit "the same metric set through the thinker's own gate cadence."

Default position for slice 1: **L1 emits silently.** The thinker's own per-iteration loop is the natural place to integrate L1 metrics if/when needed; the substrate doesn't need to model it. Document if the operator wants L1 visibility post-integration — could ship as a follow-up arc using `:trading::log::tick-gate` directly inside the thinker loop.

Default rate gate: 5000ms. Dimensions JSON still tags cache identity (e.g., `{"cache":"next","layer":"L2"}`).

### F — `:trading::sim::EncodeCache` (no migration)

The lab's existing `wat/sim/encoding-cache.wat` uses
`:wat::lru::LocalCache<HolonAST, Vector>` — exact key, no fuzz.

**Stays as-is.** Encoding is deterministic: same HolonAST → same
Vector at the same encoder. There's nothing to fuzzy-match — exact
lookup is the right primitive. (Earlier reframes pushed for "all
caches fuzzy"; that turned out wrong for the deterministic encoding
case. The fuzziness is for the algebra-grid thinking caches; encoding
is just memoization.)

After the wat-lru eviction-aware-put change (slice-2 prep), the
encoding cache automatically gets eviction visibility — the slice 1
work doesn't need to touch this file beyond the type-annotation
sweep that already shipped at commit a42c576 (lab repo).

---

## What ships

The slice was originally one commit; it became three milestones because the substrate work surfaced from inside it. As of 2026-04-29 the first two milestones are shipped.

### Milestone 1 — Lab cache primitives (✅ shipped)

| File | Status |
|---|---|
| `wat/cache/L1.wat` | ✅ shipped (9 deftests). Per-thinker dual cache struct + helpers. Two `HologramCache` instances threaded through the thinker's loop. |
| `wat/cache/walker.wat` | ✅ shipped (4 deftests). `:trading::cache::resolve` per § D. Calls `:wat::eval::walk`; visitor writes per step to L1. (L2 writes are deferred until milestone 3 — see thinker integration below.) |
| `wat/cache/L2-spawn.wat` | ✅ shipped (2 deftests). Spawns the two cache service drivers (cache-next + cache-terminal) by delegating to `:wat::holon::lru::HologramCacheService/spawn`. |

### Milestone 2 — Substrate uplift (✅ shipped via arcs 074 / 076 / 077 / 078)

What used to ship as `wat/cache/Service.wat` in this DESIGN became substrate machinery. Lab no longer owns the service code:

- `:wat::holon::lru::HologramCache` — the cache primitive (arc 074 slice 2 + arc 076 routing + arc 078 rename).
- `:wat::holon::lru::HologramCacheService` — the queue-addressed wrapper with the Reporter + MetricsCadence contract (arc 078 slice 2).
- `:wat::lru::CacheService<K,V>` retrofitted to the same contract (arc 078 slice 4).
- `wat-rs/docs/CONVENTIONS.md` "Service contract" section — the canonical recipe for any future service (arc 078 slice 5).

The substrate-test progression covers the equivalent of what was Service.wat's six-step suite: spawn+join, counted recv, Put-only, Put+Get round-trip, multi-client constructor, LRU eviction visible through the service.

### Milestone 3 — Thinker integration (❌ not started)

This is the remaining work to satisfy the slice's acceptance gate. All lab-side; no substrate work needed.

| Item | Notes |
|---|---|
| `wat/cache/reporter.wat` (or co-located in L2-spawn) | Lab Reporter fn that match-dispatches `Report::Metrics stats` → `Vec<LogEntry::Telemetry>` rows + flushes via `:trading::rundb::Service/batch-log`. |
| `wat/cache/cadence.wat` | `MetricsCadence<wat::time::Instant>` wrapping `:trading::log::tick-gate` at 5000ms. |
| Thinker hot-path call site | The thinker (or whichever observer wants work-sharing first) holds an L1 instance, pops a per-thinker `(next-tx, terminal-tx)` pair from L2's HandlePools at startup, and calls `:trading::cache::resolve` (or its successor) inside its per-candle hot path. Walker visitor extended to also write to L2 per step. |
| `wat-tests-integ/059-001-l1-l2-caches/*.rs` | Probe tests T4–T8. Currently the directory exists but is empty. |

### Probe tests

| # | Probe | State | Acceptance |
|---|-------|-------|------------|
| T1 | Single-thinker terminal-cache hit on a re-walked form | ✅ covered (`wat-tests/cache/walker.wat::test-terminal-hit`) | `coincident-get` matches; cached terminal returned. |
| T2 | Single-thinker next-cache hit shortcuts the walker | ✅ covered (`...test-chain-via-next`) | next-cache lookup returns the next form; walker recurses on it; terminal stored on unwind. |
| T3 | Single-thinker fuzzy hit on coincident-but-not-byte-identical forms (Thermometer ε-perturbation) | ✅ partial (covered by walker tests' walk-on-already-terminal + walk-fills-cache; full ε-perturbation under integration) | second walk hits the first walk's cache entry. |
| T4 | Cross-thinker L2 terminal hit via promotion | ❌ pending milestone 3 | thinker B's L1 misses; L2 lookup hits; B promotes to its own L1. |
| T5 | Cross-thinker L2 fuzzy hit | ❌ pending milestone 3 | same as T4 but the keys differ within tolerance. |
| T6 | LRU eviction at capacity, both layers | ✅ partial (L1: `wat-tests/cache/L1.wat::test-lru-eviction-at-cap`; L2-via-service: substrate's `test-step6-lru-eviction-via-service`). Both-layers-in-one-test still pending milestone 3. | filling past cap drops the oldest-by-retrieval-rate entry; gone from BOTH the LRU sidecar AND the underlying Hologram cell. |
| T7 | Telemetry rows land in rundb at the gate cadence | ❌ pending milestone 3 | window-close emits the full metric set; dimensions tag the cache identity. |
| T8 | Throughput on 10k synthetic candle-shaped forms | ❌ pending milestone 3 | sustained ≥272 c/s on the test laptop class. **Acceptance gate.** |

### Acceptance criteria

- All eight probe tests pass.
- T8 throughput ≥272 candles/sec on a representative 10k-candle run.
- Zero remaining substrate arcs (the cache lineage 074/076/077/078 is the substrate completion; this slice runs entirely on top).
- No new wards filed.
- `:trading::sim::EncodeCache` unchanged structurally; works through the eviction-aware-put surface change.

---

## Open questions

### Q1 — Where does the cache service program live? ✅ re-resolved 2026-04-29 (substrate)

Originally resolved (2026-04-28) as **lab-side** under `wat/cache/Service.wat` because substrate's `:wat::lru::CacheService` lacked telemetry hooks. The lab built its own service with telemetry baked in.

**Re-resolved 2026-04-29 as substrate.** Building the lab-side telemetry surfaced the recognition (mid-build) that the Reporter + MetricsCadence pattern is generic — the trader had no business owning the service shell when every future consumer (MTG, truth-engine) would need the same shape. Arc 078 lifted the lab's machinery into substrate as `:wat::holon::lru::HologramCacheService`, codified the contract in CONVENTIONS.md, and retrofitted `:wat::lru::CacheService<K,V>` to the same shape for symmetry.

The lab still owns:
- The L1 + L2 policy structs (paired-cache wrapping, named next/terminal fields).
- The Reporter implementation (where telemetry actually lands — `LogEntry::Telemetry` rows into rundb).
- The MetricsCadence wiring (gate type + tick body wrapping `:trading::log::tick-gate`).

What moved to substrate is the parts of the contract that aren't trader-specific.

### Q2 — L1 cache size per thinker ✅ resolved sqrt(d)

The Kanerva budget for the algebra grid at `d` is `floor(sqrt(d))`
distinguishable neighborhoods — the same number that caps a Bundle's
constituent count caps the cache's clean neighborhood count. Beyond
sqrt(d), the LRU evicts old entries automatically.

**Slice-1 default: `cap = sqrt(d) × sqrt(d) = d`** for the global LRU
(at d=10000: 10000 entries total, ~100 per cell). The HologramCache
internally bounds per-cell behavior through its global LRU + the
substrate's sqrt(d) cell count. Consumers tune via `HologramCache/make`.

### Q3 — L2 cache size per service ✅ resolved sqrt(d)

Same primitive, same sizing. Cross-thinker breadth doesn't license
neighborhood interference; if the working set exceeds the cap, the
LRU evicts cold entries. SimHash bucketing for sub-linear lookup
(Ch.55) remains future work.

### Q4 — Cache invalidation

There isn't any in slice 1. A thought's terminal is deterministic
given the form + the substrate. Forms don't drift; the algebra grid
is timeless. LRU eviction is the only "removal"; re-encountering an
evicted form re-walks from scratch.

### Q5 — Both caches always fuzzy ✅ yes

Proof 017 only fuzzed the terminal lookup. Slice 1 commits to
symmetric fuzzing — both caches use `HologramCache/coincident-get`
which applies the same cosine + filter machinery on both
directions.

### Q6 — Per-step vs batched L2 writes

Slice 1 ships per-step writes. Batched writes ship as a follow-up
arc if the throughput benchmark demands it.

### Q7 — SimHash bucketing for sub-linear lookup

Out of scope for slice 1. HologramCache's coordinate-cell pre-filter
already gives O(2 × cell_size) instead of O(N) — that's structurally
sub-linear under typical pos distributions. SimHash adds another
layer and ships when consumers surface a need.

### Q8 — Networked cache (BOOK Ch.67's "Spell")

Out of scope. Single-process. Future arc.

---

## Slice plan

What was originally one slice fractured into three milestones during the build because the substrate work surfaced from inside it. Milestones 1 and 2 are shipped; milestone 3 is the remaining work.

- **Milestone 1 — lab cache primitives.** L1.wat + walker.wat + L2-spawn.wat. ✅ shipped.
- **Milestone 2 — substrate uplift.** Cache lineage arcs 074 / 076 / 077 / 078. The lab's original Service.wat became `:wat::holon::lru::HologramCacheService`; the canonical service contract was codified in CONVENTIONS.md. ✅ shipped.
- **Milestone 3 — thinker integration.** Reporter implementation, MetricsCadence wiring, hot-path call site, probe tests T4–T8. ❌ remaining.

If during milestone 3 the work surfaces a natural split, fork into sub-slices documented in the sub-arc's BACKLOG.md.

---

## Differences from v2

For readers landing on v3:

- v2 proposed `FuzzyCache<V>` as a new primitive lifted from proof
  018. **v3 uses `:wat::holon::lru::HologramCache` instead** — substrate
  shipped this in arc 074 + slice 2. HologramCache is a coordinate-cell
  store with cosine readout AND LRU eviction; v2's FuzzyCache was
  flat-fuzzy linear scan.
- v2 listed `LocalCache::len` as a substrate-gap commit. **v3 drops
  it** — already shipped, plus the eviction-aware put under
  slice-2 prep.
- v2 proposed migrating EncodeCache to FuzzyCache for "everything
  fuzzy." **v3 keeps EncodeCache on LocalCache** — encoding is
  deterministic, no fuzz needed.
- v2 had `<V>` parametric framing throughout. **v3 drops it** —
  Hologram and HologramCache are concrete HolonAST → HolonAST. The
  encode-cache uses parametric LocalCache because it ALSO carries
  Vector values.
- v2 referenced proof 018's `FuzzyCache` shape verbatim. **v3
  references arc 074 / slice 2** — the substrate-blessed primitive
  that subsumed and replaced proof 018's flat-fuzzy approach.

## Differences from v3

For readers landing on v4:

- v3 proposed lab-side `wat/cache/Service.wat` with telemetry
  baked in (counters + tick-gate + LogEntry::Telemetry emission
  inline). **v4 uses substrate's `:wat::holon::lru::HologramCacheService`**
  — arc 078 lifted what was lab-side into substrate as a generic
  service contract (Reporter + MetricsCadence + null-helpers +
  typed Report enum). The lab's Service.wat is deleted; the lab
  ships only the Reporter implementation + the L1/L2 policy
  wrappers.
- v3 referred to `:wat::holon::lru::HologramCache` under its
  earlier name `:wat::holon::HologramLRU`. **v4 uses the renamed
  surface** — arc 078 slice 1 moved the "LRU" qualifier from the
  type name into the namespace path; the type name now describes
  what the thing IS (a hologram-backed cache).
- v3's § E telemetry section had the lab owning counter
  bookkeeping in-loop. **v4's § E describes the substrate's
  callback contract** — the lab supplies a Reporter fn that
  match-dispatches typed Report variants; substrate decides when
  to fire (via the lab's MetricsCadence).
- v3's § C said the L2 services were "lab-specific because the
  loop needs telemetry hooks." **v4 says the opposite** — the loop
  IS substrate; telemetry hooks are universal, not trader-specific.
  The lab owns only the per-domain telemetry destination and the
  policy struct around the spawn pair.
- v3 listed Service.wat among the files that ship in this slice.
  **v4 splits the slice into three milestones** — primitives
  (shipped), substrate uplift (shipped via cache-lineage arcs),
  thinker integration (remaining). § What ships and § Slice plan
  reflect this.
- v3's Q1 resolved "lab-side" for the cache service program. **v4
  re-resolves to substrate** — the recognition that drove arc 078.
- v3's per-step pos provenance note is now moot — arc 076 moved
  routing INTO Hologram (caller doesn't pass pos). § D no longer
  references per-step pos.
