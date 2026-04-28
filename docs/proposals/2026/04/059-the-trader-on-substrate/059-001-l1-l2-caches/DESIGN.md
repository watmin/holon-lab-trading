# 059-001 — L1/L2 caches on the new substrate

**Status:** PROPOSED 2026-04-27.
**Umbrella:** [`docs/proposals/2026/04/059-the-trader-on-substrate/`](../).
**Predecessors:**
- Substrate: arc 057 (typed HolonAST leaves), arc 058
  (`HashMap<HolonAST, V>`), arc 068 (`:wat::eval-step!`).
- Lab proposal 057 (L1/L2 cache + parallel subtree compute) —
  approved with conditions; this sub-arc executes that design on
  the new substrate.
- Proofs: 016 v4 (dual-LRU coordinate cache), 017 (fuzzy-locality
  cache via `coincident?`).
- BOOK chapters 65 (the hologram), 66 (the fuzziness), 67 (the
  spell).

**Performance contract:** ≥272 candles/sec sustained on a 10k
representative run after this slice ships.

---

## Why this slice first

The umbrella's chapter-65/66/67 claims rest on the cache being
operational. Without L1+L2 wired, the substrate's distinctive
properties (forms-as-coordinates, locality-keyed neighborhoods,
spell-shareable work) are decorative. With the cache wired, every
subsequent slice's thinker code automatically benefits from
work-sharing — both within a thinker (L1 hit on repeated thoughts)
and across thinkers (L2 hit on coincident thoughts).

The user's framing: *"the cache is required no matter what — it's an
optimization that we must deliver on — not having it is
disingenuous… the queues and services we've built are things in our
cookbook."*

Slice 1 wires the cookbook. Subsequent slices stand on it.

---

## What's already there (no change needed)

| Surface | Status |
|---------|--------|
| `wat::lru::LocalCache<K, V>` (arc 036) | Tier 2: thread-owned, zero-Mutex |
| `wat::CacheService` program | Tier 3: cross-program, message-addressed |
| `HashMap<HolonAST, V>` (arc 058) | exact-identity cache containers |
| `coincident?` (arc 023) | algebra-grid identity predicate for fuzzy lookup |
| Proof 016 v4's dual-LRU pattern | (form → next-form) + (form → terminal-value) |
| Proof 017's fuzzy-locality pattern | linear-scan + `coincident?` |
| `wat::eval-step!` (arc 068) | the stepper that fills the cache as it walks |
| Proposal 057's design | approved blueprint; this sub-arc ships it |

Nothing in the substrate needs to grow for this slice to land. The
work is wiring + lab-side cache surface area.

## What's missing (this slice)

### A — Per-thinker L1 cache

`wat::lru::LocalCache<HolonAST, Vector>` per thinker.
Thread-owned, zero-Mutex, direct lookup.

**Why dual-LRU (form → next-form + form → terminal-value):** per
proof 016 v4. The next-cache catches partial work; the terminal-
cache catches the answer. A walker mid-walk landing on a coordinate
where next is known but terminal isn't has discovered shareable
partial progress.

**Why per-thinker rather than per-process:** a Market Observer's
thoughts are largely disjoint from a Broker-Observer's. Per-thinker
L1 keeps the working set bounded and keeps the cache thread-owned.

**Capacity:** bounded by config; LRU eviction. Per Proposal 057's
sizing analysis: 4K-8K entries covers the hot set across a few
candles per thinker. Final number tunable.

### B — Shared L2 cache

`wat::CacheService` program shared across all thinkers in the
process. Queue-addressed (queues only — no topics, no mailboxes).

**Two cache modes inside the L2 service:**

1. **Exact** — `HashMap<HolonAST, Vector>`. Pure structural identity;
   O(1) lookup. Catches cross-thinker repetition of the same exact
   thought form.
2. **Fuzzy** — `Vec<(HolonAST, Vector)>` linear-scanned with
   `coincident?` per proof 017. Catches near-equivalent thoughts
   (e.g., two thinkers with slightly different scalar values that
   land in the same Thermometer neighborhood).

**The two modes coexist in one service.** A query passes through
exact first; on miss, falls through to fuzzy; on miss, returns
None. The thinker's worker computes fresh and writes back via the
service.

**Why the linear scan for fuzzy is acceptable here:** the L2's
fuzzy bucket is bounded by configuration (e.g., 256 most-recent
entries). For larger scales, future arc adds SimHash bucketing
per Chapter 55's framing; this slice doesn't ship that.

### C — Promotion + write-through protocol

- Thinker queries L1 first. Exact match → use Vector.
- L1 miss → query L2 (single request/reply queue pair).
- L2 hit (exact OR fuzzy) → response includes the Vector;
  thinker promotes to L1.
- L2 miss → thinker computes the Vector via `:wat::holon::encode`;
  writes it to L2 (request/reply queue pair); promotes to L1.

**No locks anywhere.** L1 is thread-owned; L2's HashMap and
fuzzy-Vec are owned by the CacheService program; queues do all
the synchronization.

### D — Encoding integration via `:wat::eval-step!`

Per the umbrella's FOUNDATION.md, the per-thinker dataflow is:

```
thought (HolonAST)
  ├─ L1 lookup
  │     ├─ hit → use cached Vector
  │     └─ miss → L2 lookup
  │            ├─ hit (exact or coincident?) → use; promote to L1
  │            └─ miss → encode → store at L2 → promote to L1
  └─ flow Vector to subspace + reckoner
```

The encode step is where `:wat::eval-step!` may help — if a
thought's HolonAST has shared subtrees with previously-seen
thoughts, `eval-step!`'s walk produces intermediate coordinates
the cache can also catch. This sub-arc's slice keeps this simple:
encode the WHOLE thought once, cache the (whole-thought → vector)
mapping; later sub-arcs may instrument the per-step cache fill if
profiling shows benefit.

---

## Decisions to resolve

### Q1 — Where does the CacheService program live?

Two options:

- **(a)** As a wat program in `wat/services/cache_service.wat` —
  pure wat consumer using existing `wat::CacheService`-shaped
  primitives.
- **(b)** As a Rust struct in `src/cache/service.rs` — Rust-side
  implementation with a wat-side wrapper for thinker queries.

**Recommended: (a) wat first, with the option to move to Rust if
profiling demands.** The wat-vm's program shape supports this; the
existing `wat::CacheService` from the substrate is the right shape
to start with. If throughput at slice-5's 10k benchmark falls
below 272/s, profile, decide.

### Q2 — L1 cache size per thinker

Proposal 057 estimated 4K-8K entries cover the working set. Phase 1
ships with 4096 entries per thinker; tunable via config.

### Q3 — L2 fuzzy bucket size

Chapter 67's spell scales the cache across machines; this slice
runs single-process. Bounded by config; ship at 256 entries; tune
based on hit-rate observability.

### Q4 — Cache invalidation

**There isn't any in slice 1.** A thought's Vector is deterministic
given the form + the encoder + the seed. Forms don't drift; the
algebra grid is timeless. LRU eviction is the only "removal";
re-encountering an evicted form re-encodes from scratch.

### Q5 — Where does `coincident?` live for L2 fuzzy lookup?

Per the substrate (arc 023), `:wat::holon::coincident?` is a
runtime primitive callable from any wat program. The L2 fuzzy
bucket scan calls it per entry. **Reuse the existing primitive.**

### Q6 — Thread count

Phase 1 doesn't specialize. The wat-vm's existing thread pool
shape (per CLAUDE.md's archived description) handles the broker
grid's parallelism. L1 is thread-owned (one cache per thinker
thread); L2 is one program (one thread). Thread counts stay at
the wat-vm defaults.

---

## What ships

One slice. Single sub-arc. Pattern matches the substrate arcs
(068's shape).

### Files touched (probable layout — confirm at write time)

- `wat/services/cache_service.wat` (new) — the L2 program
- `wat/cache/local.wat` (new) — the L1 wrapper around
  `wat::lru::LocalCache`
- `wat/cache/dual_lru.wat` (new) — proof 016 v4's dual-LRU pattern
  expressed for thinker reuse
- `wat/cache/fuzzy_lookup.wat` (new) — proof 017's fuzzy-locality
  pattern for the L2 fuzzy bucket
- `wat-tests-integ/059-001-l1-l2-caches/` (new) — probe tests

### Probe tests

- T1 — single-thinker exact hit. Encode thought twice; second
  encoding hits L1.
- T2 — single-thinker dual-LRU. Walk a multi-step form; cache
  both (form → next) and (form → terminal); subsequent walk
  short-circuits at the first cache hit.
- T3 — cross-thinker exact hit. Two thinkers encode the same
  exact thought; second thinker's L1 misses but L2 exact-bucket
  hits.
- T4 — cross-thinker fuzzy hit. Two thinkers encode coincident
  but not byte-identical thoughts (one Thermometer's value
  differs by ε within tolerance); second thinker's L2 fuzzy
  bucket hits.
- T5 — capacity probe. Fill L1 past its bound; verify LRU
  eviction; oldest entry is gone; newest stays. Same for L2's
  fuzzy bucket.
- T6 — throughput baseline. With 10k synthetic candle-shaped
  thought encodings, sustained throughput stays above 272
  candles/sec on the test laptop class. The number is the
  acceptance gate for this slice.

### Acceptance criteria

- All six probe tests pass.
- T6 throughput ≥272 candles/sec on a representative
  10k-candle run.
- No new substrate arcs needed (this is a pure consumer
  slice).
- No new wards filed (per BACKLOG B-5: *new wards only if we
  need them*).

---

## Open questions (defer to inscription)

- **L1 + L2 hit-rate observability.** Slice 5's status panel
  reads this. Slice 1 needs to expose hit/miss counters per
  cache; the API surface for the panel can land in slice 5,
  but the counters land here.
- **Whether the L2's two cache modes (exact + fuzzy) should
  be separate services or one service.** Default: one service,
  two internal stores. If profiling shows contention, split.
- **Whether `:wat::eval-step!`'s per-step caches go into L1, L2,
  or both.** Default: per-step coordinates land in L1 only;
  L2 holds whole-thought → Vector mappings. Revisit if
  cross-thinker per-step sharing surfaces value.

---

## Slices

One slice in this sub-arc. Single commit. Pattern matches
arcs 058–068.

If during implementation the work surfaces a natural split, fork
into sub-slices documented in the sub-arc's BACKLOG.md.

## Consumer follow-up

After this slice lands:

- `059-002-treasury-deadlines/` opens. Treasury wiring on top of
  the cache.
- The status panel's hit-rate counters get wired in
  `059-005-status-panel-and-run/`.

The substrate-and-consumer cycle: this sub-arc is pure
consumer; it builds on the substrate's caching primitives
without growing the substrate itself.

PERSEVERARE
