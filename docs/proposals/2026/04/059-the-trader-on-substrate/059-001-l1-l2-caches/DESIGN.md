# 059-001 — L1/L2 caches on the new substrate

**Status:** IN PROGRESS 2026-04-28 (partial). PROPOSED 2026-04-27.
Reframed 2026-04-27 (proof 018 → templates → coordinate cells).
Reframed again 2026-04-28 after wat-rs arc 074 + 074 slice 2 shipped:
substrate now exposes `:wat::holon::Hologram` (unbounded coordinate-
cell store) and `:wat::holon::HologramLRU` (bounded sibling, wat-stdlib
composition in `crates/wat-hologram-lru/`). v3 of this DESIGN replaces
the proposed `FuzzyCache<V>` primitive with the substrate-shipped
`HologramLRU` and drops the substrate-gap section (everything the lab
needs is now in core or in wat-hologram-lru).

## Progress (2026-04-28)

Partial — request/reply Service shape proven; telemetry + L2-spawn
+ probe-tests T4–T8 still pending.

| Surface | State |
|---|---|
| `wat/cache/L1.wat` | ✅ shipped (8 deftests green: make / put-get-next / put-get-terminal / cache-isolation / len / lookup-direct / lookup-chain / lookup-empty). |
| `wat/cache/walker.wat` | ✅ shipped (4 deftests green: terminal-hit / chain-via-next / walk-on-already-terminal / walk-fills-cache). Visitor records each `StepResult` variant into L1; `pos` closed at 50.0 — per-step pos is a follow-up. |
| `wat/cache/Service.wat` | ⚙️ partial — Request enum + handle + Service/loop + Service/run wrapper + Service constructor shipped. **No telemetry yet** (counters, tick-gate, `LogEntry::Telemetry` per § E). 5 incremental deftests green (step1 spawn+join → step5 full constructor + 2-client HandlePool fan-in with Put+Get round-trip). |
| `wat/cache/L2-spawn.wat` | ❌ not started. |
| Probe tests T1–T3 | ✅ covered by walker.wat tests. |
| Probe tests T4–T8 | ❌ not started (cross-thinker, eviction, telemetry-rows, throughput gate). |

**Substrate finding logged in source.** `:wat::holon::HologramLRU`'s
underlying `:wat::lru::LocalCache` is thread-owned (lives in a
`ThreadOwnedCell`), so a spawned worker holding one cannot return
the cache through `join-result` and have the caller invoke methods
on it. The `:trading::cache::Service` constructor wraps `Service/loop`
in a `Service/run` thunk that drops the cache on the worker thread
and returns `:()` — the spawn-handle type is `ProgramHandle<()>`. Live
state is observable only through `Get` queries during operation. This
mirrors `wat::lru::CacheService`'s shape; record-keeping note in case
follow-up work reaches for cache-as-return-value and finds it absent.

**Acceptance gate (T8 throughput) is not yet measurable** — needs
`L2-spawn.wat` and a thinker that consumes the cache. Acceptance
criteria from § What ships still apply unchanged.

**Umbrella:** [`docs/proposals/2026/04/059-the-trader-on-substrate/`](../).

**Predecessors:**
- Substrate: arc 057 (typed HolonAST leaves), arc 058
  (`HashMap<HolonAST, V>`), arc 068 (`:wat::eval-step!`), arc 070
  (`:wat::eval::walk`), arc 074 + slice 2 (`Hologram` + `HologramLRU`).
- Lab proposal 057 (L1/L2 cache + parallel subtree compute) —
  approved with conditions; this sub-arc executes that design on the
  new substrate.
- Proofs: 015 (expansion-chain), 016 (dual-LRU coordinate cache —
  exact-keyed v4), 017 (fuzzy-locality cache via `coincident?`), 018
  (flat-fuzzy reference; superseded by HologramLRU's coordinate-cell
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

## What's already there (no change needed)

| Surface | Status |
|---------|--------|
| `:wat::holon::Hologram` | wat-rs core (arc 074 slice 1). Coordinate-cell store with cosine readout. HolonAST → HolonAST. Unbounded. |
| `:wat::holon::HologramLRU` | `crates/wat-hologram-lru/` (arc 074 slice 2). Bounded sibling. Pure-wat composition: `Hologram` + `wat::lru::LocalCache`. LRU eviction + cosine readout + cell isolation. HolonAST → HolonAST. |
| `:wat::holon::Hologram/coincident-get` / `present-get` | wat-stdlib convenience getters. The lab's hot path uses these (no filter-construction at call sites). |
| `:wat::lru::LocalCache<K, V>` | wat-lru. Eviction-aware put returns `Option<(K, V)>` (after the slice-2 prep commit). Used here for the encode-cache (HolonAST → Vector — exact lookup, no fuzz). |
| `:wat::lru::CacheService` program | Reference shape for the L2 cache services. Lab-side L2 has telemetry hooks; same protocol skeleton. |
| `:wat::eval-step!` (arc 068) | The stepper. The cache-aware walker calls it on miss. |
| `:wat::eval::walk` (arc 070) | The fold over `eval-step!` — the structure the cache-aware walker mirrors. |
| `:trading::log::tick-gate` | Values-up rate gate; one tick per loop iteration; "open" every N ms. |
| `:trading::log::LogEntry::Telemetry` | CloudWatch-style metric variant, batched through rundb. |
| `:trading::rundb::Service/batch-log` | The metric pump destination. |

**Substrate gap closed.** v2 of this DESIGN listed a `LocalCache::len`
addition as a substrate prerequisite. That shipped in arc 036; the
slice-2 prep commit on wat-lru also added eviction-aware put. There's
no remaining wat-rs work for slice 1.

---

## What's missing (this slice — all lab-side)

### A — The cache primitive (substrate-provided)

`:wat::holon::HologramLRU` is the cache. **HolonAST → HolonAST.** Not
parametric. The trader's two caches (next, terminal) both use this
type directly. Every HolonAST IS its own vector (deterministically,
through the substrate's encoder); HologramLRU's `find-best` re-encodes
candidate keys per get, no separate vector cache layer needed. The
existing `:trading::sim::EncodeCache` (a `LocalCache<HolonAST, Vector>`)
memoizes encoding for code paths outside HologramLRU that need
explicit Vectors — a separate concern; not load-bearing for this
slice; stays as-is.

Per-cell capacity defaults to `sqrt(d)` (the algebra grid's resolution
limit at d). At d=10000, that's 100 entries per cell, with ~100 cells
across the spread — total cap ~10k entries per HologramLRU instance.
Consumers tune via `HologramLRU/make d cap`.

### B — The two coordinate caches (lab-side wrappers)

Both `:wat::holon::HologramLRU`. Both keyed by HolonAST. Both
HolonAST → HolonAST.

| Cache | Stored | What it serves |
|---|---|---|
| `next-cache` | `(form-h → next-h)` | "what's the next form after one rewrite?" — path edges |
| `terminal-cache` | `(form-h → terminal-h)` | "what's this form's terminal value?" — answers (Ch.59: terminals are AST coordinates) |

A walker landing on a coordinate where `next` is known but `terminal`
isn't has discovered **partial work**. Fuzzy hits via cosine readout
expand work-sharing across coincident neighborhoods.

### C — Two layers (L1 + L2), same primitive

**L1 (per-thinker, thread-owned):**

Each thinker owns a `(next-cache, terminal-cache)` pair of
`HologramLRU` instances threaded through its tail-recursive loop.
HologramLRU is thread-owned mutable; the thinker holds it directly.
No Mutex, no queue, no service.

**L2 (process-wide, queue-addressed):**

Two cache service programs sharing the same lab-side `:trading::
cache::Service` shape (one instance per cache):

- `cache-next: Service` — owns a `HologramLRU` for next-form sharing.
- `cache-terminal: Service` — owns a `HologramLRU` for terminal sharing.

Same protocol shape as `:wat::lru::CacheService` (request/reply via
queue + per-client reply channel) but lab-specific because the loop
needs telemetry hooks (counters + tick-gate + LogEntry emission).

### D — The walker (`:trading::cache::resolve`)

`:trading::cache::resolve` is the cache-aware substitute for "encode
a form" in the thinker's hot path. Same idea as proof 018's reference,
adapted to HologramLRU's coordinate-cell shape:

```
resolve(form-h, pos, l1, l2):
  ;; 1. Terminal cache lookup. Hit ends the walk.
  on HologramLRU/coincident-get(l1.terminal-cache, pos, form-h) → Some(t):
    return t

  ;; 2. Next-form cache lookup. Hit short-circuits one or more steps.
  on HologramLRU/coincident-get(l1.next-cache, pos, form-h) → Some(next-h):
    return resolve(next-h, pos, l1, l2)

  ;; 3. Both miss — invoke :wat::eval::walk on the form.
  ;;    The visit-fn fires once per coordinate; it RECORDS into both
  ;;    caches as the walk progresses, and returns Continue.
  case :wat::eval::walk(to-watast(form-h), l1, record-coordinate):
    Ok((terminal, l1')): return terminal
    Err(_e): fall back to eval-ast! (without caching)
```

The visit-fn writes per-step:
- `Next next-h` → record `(form-h → next-h)` in next-cache
- `Terminal t` → record `(form-h → t)` in terminal-cache
- `AlreadyTerminal t` → record `(t → t)` in terminal-cache (idempotent)

L1 writes happen unconditionally (cheap, thread-local). L2 writes go
through the service queue per step. (Batching L2 is a follow-up arc
if profiling demands.)

`:wat::eval::walk`'s `Skip` variant is unused here — short-circuit
logic happens in step 1 / step 2 BEFORE walk is invoked.

**`pos` provenance.** Each form's `pos` is computed once before
entering `resolve` — typically by the trader's coordinate function
(cosine readout against a reference, SimHash bucket, or domain
projection). The lab can keep using its existing pos discipline; this
arc doesn't pick a default.

### E — Telemetry (mandatory)

The cache service program owns counters tracked across loop
iterations. Each iteration ticks `:trading::log::tick-gate`; on
"open" the loop packages the counters as `Vec<LogEntry::Telemetry>`,
flushes via `:trading::rundb::Service/batch-log`, resets the window.

Counter set (per-cache):

| Metric | Unit | Meaning |
|---|---|---|
| `lookups` | Count | total `get` requests in the window |
| `hits` | Count | matches accepted by the filter (incl. self-cosine) |
| `misses` | Count | filter rejected or candidates empty |
| `evictions` | Count | LRU evictions (visible via `LocalCache::put`'s return) |
| `size` | Count | `HologramLRU/len` at window close |
| `ns_gets` | Microseconds | total time in lookup-side scans |
| `ns_sets` | Microseconds | total time in put + cell-cleanup |
| `gets_serviced` | Count | requests dispatched to caller |
| `sets_drained` | Count | inserts processed |

Each metric becomes one `LogEntry::Telemetry` row. Dimensions JSON
tags the cache identity (e.g., `{"cache":"next","layer":"L2"}`). L1
emits the same metric set through the thinker's own gate cadence
with `{"cache":"...","layer":"L1","thinker":"<name>"}`.

Default rate gate: 5000ms.

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

One slice. Lab-only — substrate work was finished by arc 074 + slice 2.

### Lab files

- `wat/cache/L1.wat` — per-thinker dual cache struct + helpers.
  Two `HologramLRU` instances threaded through the thinker's loop.
- `wat/cache/Service.wat` — generic queue-addressed program. Owns a
  `HologramLRU`. Tracks counters. Runs the tick-gate. Emits
  `LogEntry::Telemetry` through rundb. Lifecycle mirrors
  `RunDbService` and `:wat::lru::CacheService`.
- `wat/cache/walker.wat` — `:trading::cache::resolve`, the per-step
  cache-aware walker per § D. Calls `:wat::eval::walk`; writes per
  step to L1 and via service queues to L2.
- `wat/cache/L2-spawn.wat` — setup helper that spawns the two cache
  service drivers (`cache-next` + `cache-terminal`) and returns the
  HandlePool tuple needed by thinkers for client distribution.
- `wat-tests-integ/059-001-l1-l2-caches/` — probe tests + the
  throughput gate.

### Probe tests

| # | Probe | Acceptance |
|---|-------|------------|
| T1 | Single-thinker terminal-cache hit on a re-walked form | `coincident-get` matches; cached terminal returned. |
| T2 | Single-thinker next-cache hit shortcuts the walker | next-cache lookup returns the next form; walker recurses on it; terminal stored on unwind. |
| T3 | Single-thinker fuzzy hit on coincident-but-not-byte-identical forms (Thermometer ε-perturbation) | second walk hits the first walk's cache entry. |
| T4 | Cross-thinker L2 terminal hit via promotion | thinker B's L1 misses; L2 lookup hits; B promotes to its own L1. |
| T5 | Cross-thinker L2 fuzzy hit | same as T4 but the keys differ within tolerance. |
| T6 | LRU eviction at capacity, both layers | filling past cap drops the oldest-by-retrieval-rate entry; gone from BOTH the LRU sidecar AND the underlying Hologram cell. |
| T7 | Telemetry rows land in rundb at the gate cadence | window-close emits the full metric set; dimensions tag the cache identity. |
| T8 | Throughput on 10k synthetic candle-shaped forms | sustained ≥272 c/s on the test laptop class. **Acceptance gate.** |

### Acceptance criteria

- All eight probe tests pass.
- T8 throughput ≥272 candles/sec on a representative 10k-candle run.
- Zero substrate arcs needed (everything's there already).
- No new wards filed.
- `:trading::sim::EncodeCache` unchanged structurally; works through
  the eviction-aware-put surface change.

---

## Open questions

### Q1 — Where does the cache service program live? ✅ resolved (a)

Lab-side wat (`wat/cache/Service.wat`) — substrate's
`:wat::lru::CacheService` doesn't have telemetry hooks; the lab's
service knows about `LogEntry::Telemetry` and `RunDbService`. Same
program shape, lab-specific concerns baked in.

### Q2 — L1 cache size per thinker ✅ resolved sqrt(d)

The Kanerva budget for the algebra grid at `d` is `floor(sqrt(d))`
distinguishable neighborhoods — the same number that caps a Bundle's
constituent count caps the cache's clean neighborhood count. Beyond
sqrt(d), the LRU evicts old entries automatically.

**Slice-1 default: `cap = sqrt(d) × sqrt(d) = d`** for the global LRU
(at d=10000: 10000 entries total, ~100 per cell). The HologramLRU
internally bounds per-cell behavior through its global LRU + the
substrate's sqrt(d) cell count. Consumers tune via `HologramLRU/make`.

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
symmetric fuzzing — both caches use `HologramLRU/coincident-get`
which applies the same cosine + filter machinery on both
directions.

### Q6 — Per-step vs batched L2 writes

Slice 1 ships per-step writes. Batched writes ship as a follow-up
arc if the throughput benchmark demands it.

### Q7 — SimHash bucketing for sub-linear lookup

Out of scope for slice 1. HologramLRU's coordinate-cell pre-filter
already gives O(2 × cell_size) instead of O(N) — that's structurally
sub-linear under typical pos distributions. SimHash adds another
layer and ships when consumers surface a need.

### Q8 — Networked cache (BOOK Ch.67's "Spell")

Out of scope. Single-process. Future arc.

---

## Slice plan

One slice. One commit at the natural boundary: lab walker + tests +
docs.

If during implementation the work surfaces a natural split, fork into
sub-slices documented in the sub-arc's BACKLOG.md.

---

## Differences from v2

For readers landing on v3:

- v2 proposed `FuzzyCache<V>` as a new primitive lifted from proof
  018. **v3 uses `:wat::holon::HologramLRU` instead** — substrate
  shipped this in arc 074 + slice 2. HologramLRU is a coordinate-cell
  store with cosine readout AND LRU eviction; v2's FuzzyCache was
  flat-fuzzy linear scan.
- v2 listed `LocalCache::len` as a substrate-gap commit. **v3 drops
  it** — already shipped, plus the eviction-aware put under
  slice-2 prep.
- v2 proposed migrating EncodeCache to FuzzyCache for "everything
  fuzzy." **v3 keeps EncodeCache on LocalCache** — encoding is
  deterministic, no fuzz needed.
- v2 had `<V>` parametric framing throughout. **v3 drops it** —
  Hologram and HologramLRU are concrete HolonAST → HolonAST. The
  encode-cache uses parametric LocalCache because it ALSO carries
  Vector values.
- v2 referenced proof 018's `FuzzyCache` shape verbatim. **v3
  references arc 074 / slice 2** — the substrate-blessed primitive
  that subsumed and replaced proof 018's flat-fuzzy approach.
