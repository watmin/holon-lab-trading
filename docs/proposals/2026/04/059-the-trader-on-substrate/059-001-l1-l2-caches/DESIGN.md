# 059-001 — L1/L2 caches on the new substrate

**Status:** PROPOSED 2026-04-27. Reframed 2026-04-27 after study of
BOOK Ch.65–68 + proofs 015 (expansion-chain) / 016 (dual-LRU) / 017
(fuzzy-locality). v1 of this DESIGN proposed an exact+fuzzy hybrid;
v2 (this one) drops the exact bucket per the substrate's
chapter-66/67 framing — *the cache IS the algebra grid; there is no
discretization to add back*.

**Umbrella:** [`docs/proposals/2026/04/059-the-trader-on-substrate/`](../).

**Predecessors:**
- Substrate: arc 057 (typed HolonAST leaves), arc 058
  (`HashMap<HolonAST, V>`), arc 068 (`:wat::eval-step!`).
- Lab proposal 057 (L1/L2 cache + parallel subtree compute) —
  approved with conditions; this sub-arc executes that design on
  the new substrate, *with the corrected fuzzy framing*.
- Proofs: 015 (expansion-chain), 016 (dual-LRU coordinate cache —
  exact-keyed v4), 017 (fuzzy-locality cache via `coincident?` —
  v5 swapped exact for fuzzy on the terminal lookup).
- BOOK chapters 59 (the dual-LRU named), 65 (the hologram), 66
  (the fuzziness), 67 (the spell), 68 (the inscription).

**Performance contract:** ≥272 candles/sec sustained on a 10k
representative run after this slice ships.

---

## Why this slice first

The umbrella's chapter-65/66/67 claims rest on the cache being
operational. Without it, the substrate's distinctive properties
(forms-as-coordinates, locality-keyed neighborhoods, walker
cooperation) are decorative. With the cache wired, every subsequent
slice's thinker code automatically benefits from work-sharing —
both within a thinker and across thinkers.

The user's framing: *"the cache is required no matter what — it's
an optimization that we must deliver on — not having it is
disingenuous… the queues and services we've built are things in our
cookbook."*

Slice 1 wires the cookbook. Subsequent slices stand on it.

---

## What's already there (no change needed)

| Surface | Status |
|---------|--------|
| `wat::lru::LocalCache<K, V>` (arc 036) | Tier 2: thread-owned, zero-Mutex (the substrate's exact-keyed LRU; this slice does NOT use it for the dual-LRU coordinate cache — see below — but encoding-cache scope may revisit) |
| `wat::lru::CacheService` program (arc 036) | Tier 3: cross-program, message-addressed, generic over `<K,V>`. Shape we copy for the lab cache services — not the type we use directly because telemetry hooks aren't there. |
| `HashMap<HolonAST, V>` (arc 058) | Available but **not load-bearing here** — exact equality is the wrong primitive for this cache (see "the cache primitive"). |
| `:wat::holon::coincident?` (arc 023) | The substrate's "are these the same point on the algebra grid within sigma?" predicate. This IS the cache lookup. |
| `:wat::holon::from-watast` (arc 057) | Canonical structural lift WatAST → HolonAST. Every cache key is a HolonAST produced by this. |
| `:wat::eval-step!` (arc 068) | The stepper that fills the cache as it walks. |
| `:trading::log::tick-gate` (lab) | Values-up rate gate; one tick per loop iteration; "open" every N ms. |
| `:trading::log::LogEntry::Telemetry` (lab) | CloudWatch-style metric variant, batched through rundb. |
| `:trading::rundb::Service/batch-log` (lab) | The metric pump destination. |
| Proof 017's fuzzy walker | Reference implementation under `wat-tests-integ/experiment/021-fuzzy-locality/`. |

## What's missing (this slice)

### A — The fuzzy cache primitive

**One thing**, used everywhere:

```
FuzzyCache<V> = Vec<(HolonAST, V)>
```

Bounded by capacity. Lookup is a linear `foldl` with
`:wat::holon::coincident?` against the query key — first match
wins. Insert appends to the end; on overflow, drop the oldest
entry (FIFO). Optional move-to-front on hit (slice-1 ship
without; revisit if profiling demands).

**Why no exact bucket alongside.** BOOK Ch.66 + proof 017's v5:

- Byte-identical HolonASTs are coincident (cosine = 1). Linear scan
  with `coincident?` subsumes exact match. An exact `HashMap`
  alongside is dead weight that reintroduces the discretization
  Ch.66 specifically architected away. (BOOK lines 30508–30514:
  *"the cache is no longer a discretization of the algebra grid —
  it IS the algebra grid, with its native tolerance."*)
- The walker traverses chains whose leaves switch between F64
  (quasi-orthogonal) and Thermometer (locality-preserving)
  depending on the form's pre/post-β state. There's no clean point
  to route some queries to an exact bucket and others to fuzzy —
  the walker doesn't know in advance which depth carries the fuzz.
  *"The same `coincident?` predicate runs at every level."* (BOOK
  30461–30465.)
- The fuzzy cache **is** the algebra grid. No second store needed.

**Linear-scan complexity is honest scope.** O(N) per lookup. SimHash
bucketing (BOOK Ch.55) for sub-linear lookup is named on paper but
not shipped. Slice 1 ships linear; future arc revisits when the
benchmark surfaces a need.

**Reference implementation: proof 018.** Slice 1 lifts proof 018's
`:exp::CacheEntry` / `:exp::CoordinateCache` / `:exp::cache-empty`
/ `:exp::cache-record` / `:exp::cache-lookup` shapes verbatim from
`wat-tests-integ/experiment/022-fuzzy-on-both-stores/explore-fuzzy-on-both-stores.wat`
into `wat/cache/FuzzyCache.wat`, generalized to take `<V>` so the
EncodeCache (V = `Vector`) shares the primitive with the dual-LRU
caches (V = `HolonAST`). The proof's lookup is a `foldl`
short-circuiting via `match`-on-`(Some _)`; its insert is a
`conj`. No more, no less.

**Cap is `sqrt(d)`.** Per Q2/Q3 below: the algebra grid hosts
~`sqrt(d)` distinguishable neighborhoods at d. The cache cap is
the same number — beyond that, fuzzy lookups risk false-positive
neighborhood matches. The cache constructor reads the ambient dim
router at instantiation and computes the cap.

### B — The two coordinate caches

Both `FuzzyCache<HolonAST>`. **Both fuzzy. Both store HolonAST
values.** The terminal IS a HolonAST (Chapter 59: *42 IS an AST*) —
encoding to a `Vector` is what `coincident?` does internally during
lookup, not what the cache stores.

| Cache | Key | Value | What it serves |
|---|---|---|---|
| next-cache | `HolonAST` | `HolonAST` | "what's the next form after one rewrite?" — path edges |
| terminal-cache | `HolonAST` | `HolonAST` | "what's this form's terminal value?" — answers (Ch.59: terminals are AST coordinates) |

A walker landing on a coordinate where `next` is known but
`terminal` isn't has discovered **partial work**. Even when the
terminal misses, the next pointer moves the walker closer. Even
when both miss exactly, fuzzy match against either may hit a
neighborhood. They cooperate.

**Per the user's slice-1 directive: assume both caches are always
fuzzy.** Proof 017 only swapped the terminal lookup explicitly; the
proof session is producing reference code that fuzzes the next
lookup too. Slice 1 commits to symmetric fuzzing as the foundation.

### C — Two layers (L1 + L2), same shape

**L1 (per-thinker, thread-owned, value-up):**

Each thinker owns a `(next-cache, terminal-cache)` tuple of
`FuzzyCache<HolonAST>`. Threaded through the thinker's tail-
recursive loop. No Mutex. No queue. Direct lookup on the thinker's
own thread. (Proof 016 line 134: *"No Mutex. No thread coordination.
Just a HashMap value passed by ownership. Values up, not queues
down."* — applies identically here, with `Vec` substituting for
`HashMap`.)

**L2 (process-wide, queue-addressed):**

Two cache service programs sharing the same `:trading::cache::
Service<V>` shape (one instance per cache):

- `cache-next: Service<HolonAST>` — owns a `FuzzyCache<HolonAST>` for next-form sharing.
- `cache-terminal: Service<HolonAST>` — owns a `FuzzyCache<HolonAST>` for terminal sharing.

Same protocol shape as `wat::lru::CacheService` (request/reply via
queue + per-client reply channel) but lab-specific because the loop
needs telemetry hooks (counters + tick-gate + LogEntry emission).
Lab-side, not substrate.

### D — The walker (cache-first then `:wat::eval::walk` on miss)

`:trading::cache::resolve` is the cache-aware substitute for
"encode a form" in the thinker's hot path. Reference shape lifted
from proof 018's `wat-tests-integ/experiment/022-fuzzy-on-both-stores/explore-fuzzy-on-both-stores.wat`:

```
resolve(form-h, tier):
  ;; 1. Cache lookup BEFORE the walker. Terminal hit ends.
  on FuzzyCache.lookup(tier.terminal-cache, form-h) → Some(t):
    return (t, tier)

  ;; 2. Next-form hit short-circuits one or more steps.
  on FuzzyCache.lookup(tier.next-cache, form-h) → Some(next-h):
    return resolve(next-h, tier)

  ;; 3. Both miss — invoke the substrate walker (arc 070).
  ;;    The visit-fn fires once per coordinate with
  ;;    (acc=tier, form-w, step-result) and returns Continue:
  ;;
  ;;    AlreadyTerminal t  → record (t → t) in terminal-cache
  ;;    StepTerminal t     → record (form-h → t) in terminal-cache
  ;;    StepNext next-w    → record (form-h → next-h) in next-cache
  ;;
  ;;    The walker handles iteration; the visit-fn just records.
  case :wat::eval::walk(to-watast(form-h), tier, record-coordinate):
    Ok((terminal, tier')): return (terminal, tier')
    Err(_e): fall back to eval-ast!
```

**Skip is never used.** Proof 018's visitor returns `Continue` on
every arm; all short-circuit logic happens in step 1 / step 2
BEFORE `walk` is invoked. The arc-070 `WalkStep::Skip` variant
remains available for consumers who want a different shape, but
the cache walker doesn't need it — its short-circuit is
structurally upstream.

**The visit-fn is the lift point.** Proof 018's `record-coordinate`
(`explore-fuzzy-on-both-stores.wat:191–217`) is the canonical
shape for slice 1; reproducing it verbatim under the canonical
`:trading::cache::*` paths is the right move.

**Cache write strategy across L1 + L2:** L1 writes happen
unconditionally (cheap, thread-local). L2 writes go through the
service queue per step. The proof session noted batched L2 writes
as a follow-up arc if profiling demands; slice 1 ships per-step
and revisits on the throughput benchmark.

### E — Telemetry (mandatory)

The cache service program owns counters tracked across loop
iterations. Each iteration ticks `:trading::log::tick-gate`; on
"open" the loop packages the counters as `Vec<LogEntry::Telemetry>`,
flushes via `:trading::rundb::Service/batch-log`, resets the
window. Per the archive's `pre-wat-native/src/programs/{telemetry,
stdlib/cache}.rs` cookbook the counter set is:

| Metric | Unit | Meaning |
|---|---|---|
| `lookups` | Count | total `get` requests in the window |
| `hits` | Count | fuzzy matches found (including byte-exact) |
| `misses` | Count | scans that found no coincident entry |
| `evictions` | Count | FIFO drops from the bounded Vec |
| `size` | Count | Vec length at window close |
| `scan_depth_avg` | Count | average entries scanned before terminate |
| `ns_gets` | Microseconds | total time in lookup-side scans |
| `ns_sets` | Microseconds | total time in insert + eviction |
| `gets_serviced` | Count | requests dispatched to caller |
| `sets_drained` | Count | inserts processed |

Each metric becomes one `LogEntry::Telemetry` row. Dimensions JSON
tags the cache identity (e.g., `{"cache":"next","layer":"L2"}` /
`{"cache":"terminal","layer":"L2"}`). L1 emits the same metric set
through the thinker's own gate cadence with
`{"cache":"...","layer":"L1","thinker":"<name>"}`.

Default rate gate: 5000ms (matches the archive's
`make_rate_gate(Duration::from_secs(5))` default).

### F — `:trading::sim::EncodeCache` migration (in scope)

The lab's existing encoding hot-path cache `wat/sim/encoding-
cache.wat` is a `wat::lru::LocalCache<HolonAST, Vector>` — exact
key, no fuzz. Per the user's "everything fuzzy" mandate, this
migrates to `FuzzyCache<Vector>` in this slice. The same FuzzyCache
primitive instantiated with `V = wat::holon::Vector`. Telemetry
counters apply identically.

This migration is what guarantees ALL caches under the trader's
hot path share the same fuzzy primitive — no exact-keyed leftover
that surreptitiously routes around the algebra grid.

---

## What ships

One slice. One sub-arc. Two commits at natural boundaries: substrate
gap first, lab walker second.

### Substrate gap (commit 1)

`:wat::lru::LocalCache::len<K,V>` doesn't exist in wat-rs. We need
it for the `size` telemetry metric on the LocalCache-backed encode
cache during migration (and as a general capability). Small wat-rs
arc:

- `wat-rs/crates/wat-lru/src/lib.rs` — one-line `#[wat_dispatch]`
  shim around `LruCache::len`.
- `wat-rs/crates/wat-lru/wat/lru/LocalCache.wat` — `LocalCache::len`
  wrapper.

### Lab files (commit 2)

- `wat/cache/FuzzyCache.wat` — the primitive (`new`, `lookup`,
  `insert`, `len`, eviction). Generic over `V`. Linear-scan with
  `coincident?`.
- `wat/cache/Service.wat` — generic queue-addressed program.
  Owns a `FuzzyCache<V>`. Tracks counters. Runs the tick-gate.
  Emits `LogEntry::Telemetry` through rundb. Lifecycle mirrors
  `RunDbService` / `wat::lru::CacheService`.
- `wat/cache/L1.wat` — per-thinker dual cache helper. Two
  `FuzzyCache<HolonAST>` threaded through the thinker's loop.
- `wat/cache/walker.wat` — `:trading::cache::resolve`, the per-step
  walker per § D. Calls `:wat::eval-step!`; writes per step to L1
  and via service queues to L2.
- `wat/cache/L2-spawn.wat` — setup helper that spawns the two cache
  service drivers (`cache-next` + `cache-terminal`) and returns the
  HandlePool tuple needed by thinkers for client distribution.
- `wat/sim/encoding-cache.wat` — migrate from `LocalCache` to
  `FuzzyCache<Vector>` per § F.
- `wat-tests-integ/059-001-l1-l2-caches/` — probe tests + the
  throughput gate.

### Probe tests

| # | Probe | Acceptance |
|---|-------|------------|
| T1 | Single-thinker terminal-cache hit on a re-walked form | `coincident?` matches; cached terminal returned. |
| T2 | Single-thinker next-cache hit shortcuts the walker | next-cache lookup returns the next form; walker recurses on it; terminal stored on unwind. |
| T3 | Single-thinker fuzzy hit on coincident-but-not-byte-identical forms (Thermometer ε-perturbation) | second walk hits the first walk's cache entry. |
| T4 | Cross-thinker L2 terminal hit via promotion | thinker B's L1 misses; L2 lookup hits; B promotes to its own L1. |
| T5 | Cross-thinker L2 fuzzy hit | same as T4 but the keys differ within tolerance. |
| T6 | FIFO eviction at capacity | both buckets, both layers; oldest entry gone, newest stays. |
| T7 | Telemetry rows land in rundb at the gate cadence | window-close emits the full metric set; dimensions tag the cache identity. |
| T8 | Throughput on 10k synthetic candle-shaped forms | sustained ≥272 c/s on the test laptop class. **Acceptance gate.** |

### Acceptance criteria

- All eight probe tests pass.
- T8 throughput ≥272 candles/sec on a representative 10k-candle
  run.
- One substrate arc shipped (`LocalCache::len` only — minimal
  surface).
- No new wards filed (per BACKLOG B-5).
- `:trading::sim::EncodeCache` running on the same `FuzzyCache`
  primitive as the dual-LRU caches.

---

## Open questions

### Q1 — Where does the cache service program live? ✅ resolved (a)

Lab-side wat (`wat/cache/Service.wat`) — substrate's
`wat::lru::CacheService` doesn't have telemetry hooks; the lab's
service knows about `LogEntry::Telemetry` and `RunDbService`. Same
program shape, lab-specific concerns baked in.

### Q2 — L1 fuzzy-cache size per thinker ✅ resolved sqrt(d)

The Kanerva budget for the algebra grid at `d` is `floor(sqrt(d))`
distinguishable neighborhoods — the same number that caps a
Bundle's constituent count caps the cache's clean neighborhood
count. Beyond sqrt(d), fuzzy lookups risk returning spurious
coincident matches. Proof 018's T5 tests exactly this boundary.

**Slice-1 default: `sqrt(d)` per cache.** Under the default
router (arc 067, `DEFAULT_TIERS = [10000]`), that's 100 entries.
A consumer can override and accept neighborhood-interference
risk past sqrt(d).

The cache constructor reads the ambient router at instantiation
and computes the cap from there. No literal 100 baked in; when
a consumer reconfigures the router (`set-dim-router!` to a
different tier), the cache cap follows.

### Q3 — L2 fuzzy-cache size per service ✅ resolved sqrt(d)

Same primitive, same constraint. Defaults to `sqrt(d)` per cache
(100 at d=10000). Cross-thinker breadth doesn't license
neighborhood interference; if the working set exceeds sqrt(d),
the consumer wants SimHash bucketing (Ch.55, Q7), not a bigger
linear-scan Vec.

### Q4 — Cache invalidation

There isn't any in slice 1. A thought's terminal is deterministic
given the form + the substrate. Forms don't drift; the algebra grid
is timeless. FIFO eviction is the only "removal"; re-encountering
an evicted form re-walks from scratch.

### Q5 — Should fuzzy lookups also apply to the next-cache? ✅ yes

Proof 017 only fuzzed the terminal lookup. The user's slice-1
directive: **assume both caches are always fuzzy.** The proof
session is producing reference code; slice 1 ships symmetric
fuzzing.

### Q6 — Per-step vs batched L2 writes

Slice 1 ships per-step writes. The proof session is exploring
whether batching materially outperforms; if it does, a follow-up
arc adds a batched-write mode. Per-step is the foundation; batching
is optimization.

### Q7 — SimHash bucketing for sub-linear lookup

Out of scope for slice 1 — BOOK Ch.55 names it as future work.
Linear scan is the slice-1 substrate; the bench tells us when
sub-linear is worth shipping.

### Q8 — Networked cache (BOOK Ch.67's "Spell")

Out of scope. Single-process. Future arc when cross-machine
work-sharing matters.

---

## Slices

One slice. Two commits at natural boundaries (substrate gap →
lab walker). Pattern matches arcs 058 / 060 / 062 / 068.

If during implementation the work surfaces a natural split, fork
into sub-slices documented in the sub-arc's BACKLOG.md.

## Consumer follow-up

After this slice lands:

- `059-002-treasury-deadlines/` opens. Treasury wiring on top of
  the cache.
- The status panel's hit-rate counters get wired in
  `059-005-status-panel-and-run/`.
- A potential `059-006-simhash-bucketing` if T8 throughput
  surfaces a need.

The substrate-and-consumer cycle: this sub-arc is mostly consumer
(one minimal substrate gap for `LocalCache::len`); it builds on the
substrate's caching primitives without growing the substrate
fundamentally.

PERSEVERARE
