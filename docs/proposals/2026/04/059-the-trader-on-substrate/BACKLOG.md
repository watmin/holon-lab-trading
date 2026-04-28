# Backlog — items to work through before / during Phase 1

**Date:** 2026-04-27. The list of outstanding items I asked about
plus the user's guidance on each. Working through these in order;
mechanical first.

---

## Now — mechanical (do these first, in order)

### B-1 — Archive `holon-lab-trading/CLAUDE.md`

**Status:** ready to do.

**User's words:** *"archive this - its way way way old - its now
toxic to us."*

**Action:** move `CLAUDE.md` to `archived/` (or equivalent path
already in use for archived material). The archive prevents
forgetting; deletion would erase context. The file's stale
guidance shouldn't load into any future Claude session and
contaminate the work. After archival, optionally write a fresh
minimal `CLAUDE.md` describing the current shape (post-arc-068
substrate, the playground plan, etc.) — but the user did NOT
explicitly ask for a replacement. Just the archive. Keep
scope tight.

---

## Soon — verifications before opening slice 1

### B-2 — Substrate key types ✅ DONE 2026-04-27

**Finding:** the two layers are correctly separated by design. No
adapter or new arc needed.

| Layer | Type | Source |
|---|---|---|
| Identity / cache | `HolonAST` | proof 016 v4 + 017 |
| Measurement / learning | `Vector` | `OnlineSubspace.update/residual`, `Reckoner.observe/predict` |
| Label naming | `HolonAST` | arc 053 — `ReckConfig::Discrete(Vec<HolonAST>)`; internal `Label` is u32 index |

The flow per thinker is `thought (HolonAST) → from-watast → encode
→ Vector → subspace/reckoner`. Cache memoizes thought identity (the
HolonAST). Subspace consumes Vector. Reckoner trains on Vector,
labels named by HolonAST. No round-trips at user level.

**Cited evidence:**
- `holon-rs/src/memory/subspace.rs:239` — `pub fn update(&mut self, x: &[f64]) -> f64`
- `holon-rs/src/memory/reckoner.rs:251` — `pub fn observe(&mut self, vec: &Vector, label: Label, weight: f64)`
- `holon-rs/src/memory/reckoner.rs:275` — `pub fn predict(&self, vec: &Vector) -> Prediction`
- `holon-rs/src/memory/reckoner.rs:465` — `pub fn label_ast(&self, label: Label) -> Option<&HolonAST>`
- `wat-rs/src/runtime.rs:2353-2376` — wat-side surface (`/update`, `/observe`, etc.)
- arc 053 docstring confirms HolonAST labels via Label index handles.

**Slice 1 implication:** proceed. The encoding step (`from-watast →
encode → Vector`) is cached from day one. **Cache is non-negotiable**
— not having it would make the substrate's chapter-65/66/67 claims
about coordinates, locality, and shared work decorative. The lab's
caching cookbook is well-rehearsed:

- **L1** — `wat::lru::LocalCache<HolonAST, Vector>` per thinker,
  thread-owned, zero-Mutex (arc 036).
- **L2** — `wat::CacheService` program, queue-addressed, shared
  across thinkers, the chapter-67 spell layer.

Both ship in slice 1. The architecture isn't "wire it; profile;
then add a cache." The cache is the architecture.

User correction logged 2026-04-27: *"the cache is required no
matter what — it's an optimization that we must deliver on —
not having it is disingenuous… the queues and services we've
built are things in our cookbook."*

### B-3 — Performance target ✅ DONE 2026-04-27

**User's tightened framing:** *"the equation is — what rate is
necessary to satisfy we can process ~650k items in 40 minutes."*

**The math:**

```
data: btc_5m_raw.parquet = 652,608 rows (5-min BTC candles)
        candles.db.candles = 652,608 rows (same data)
        Jan 2019 – Mar 2025

target: 40 minutes wall time

required throughput:
  652,608 ÷ 40 min ÷ 60 sec = 271.92 candles/sec

round number: ≥272 candles/sec sustained
```

**The target is locked: ≥272 candles/sec.** Slice 1 wires L1 + L2
caches per the cookbook; subsequent slices stay above this number
or the architecture has regressed.

**Why this number stays load-bearing:**

- 40-minute wall time on the full parquet is the user-defined
  performance contract. The lab's prior architecture cleared
  >250/s repeatedly; the new substrate's caches (proof 016 v4 +
  017) shouldn't regress it.
- Headroom for cold-cache cost: the first ~30 seconds of a run
  fill L1; the cache-hit-driven steady state runs faster than
  cold start. 272/s is the sustained rate, not the peak.
- L1 + L2 (slice 1's deliverables) are how we stay above this
  number under real load. The substrate's chapter-65/66/67
  primitives are operational because the cache is there.

**Acceptance:** any slice that drops sustained throughput below
272 candles/sec on a representative run (≥10k candles) is a
regression. Wards catch what they catch; this number is the
bottom-line constraint.

### B-4 — Confirm code layout for Phase 1

**User's words:** *"we'll update the code as we see fit - the
majority is still good - we archive and rebuild whatever we need
- the paths are carved and we can fork or copy - the archive
prevents us from forgetting."*

**Action:** during slice 1, write new code in existing dirs
(`src/thought/`, `src/market/`, `src/risk/`, `src/vocab/`,
`wat/`, `wat-tests-integ/`) per the carved paths. When existing
code conflicts with the new substrate's shape, **archive the
old version first** (move to `archived/<original-path>`), then
write the new. Forking and copying are explicitly OK — no
dogmatic in-place rewrite.

**Discipline:** archive before rewrite. Never delete.

---

## During the build — decisions we'll make as we slice

### B-5 — Conservation invariant: no new ward, runtime assertion only

**User's words:** *"new wards.... only if we need them.. the wards
shaped what wat-rs is and has basically removed their need
entirely...."*

**Action:** in slice 2 (treasury + deadlines), the conservation
invariant lands as a `debug_assert!` per candle in Rust, OR as a
wat-tests-integ property test that runs over N candles. NOT as a
new ward. Existing eight wards (sever / reap / scry / gaze /
forge / temper / assay / ignorant) cover the territory needed.

**Rule going forward:** new wards only when the existing eight
demonstrably miss something during real work. Don't preemptively
file them. Don't speculate.

### B-6 — Designer subagents: improvise voice prompts in Agent calls

**User's words:** *"we just riffed on the hickey/beckman
descriptions to create the market flavor ones - we can improvise
again - we did it a few dozen times - the hickman/beckman are a
guide to the improv."*

**Action:** when Phase 2 needs a designer voice (Wyckoff /
Beckman / Hickey / Seykota / Van Tharp), spawn an `Agent` tool
call with the voice's prompt embedded directly. Riff per call —
don't formalize a `.claude/skills/designers/` directory in the lab
repo. The o.g. wat designer SKILL.md serves as the template; the
Hickey + Beckman descriptions there are the seed for the trading-
reviewer voices when we need them.

**One voice per subagent. No cross-talk. Datamancer synthesizes.**

### B-7 — Phase labeler + specific thought selection: figure out as we go

**User's words:** *"no idea - we'll figure out what thoughts
matter - we need the infra to support experimenting with thoughts
- the infra layer will be constant - the learning is the thing we
need to play with."*

**Action:** Phase 1 uses `wat/encoding/phase-state.wat` as-is for
gate-1 phase triggers. Don't preemptively rewrite it. If Phase 2's
labeling reveals it's the wrong shape, revisit then. The infra is
the constant; the thoughts are the variable; the playground lets
us test which thoughts work without committing in advance.

---

## Future / deferred — flag, don't block

### B-8 — BOOK chapter for the v1→v2 recognition

The phase-1/phase-2 split is itself a recognition worth a chapter:
*"the architecture is known-good; the thoughts are dynamic; build
the playground first; iterate thoughts inside it."* Chapter 55's
bridge made operational at the build level.

**Defer until Phase 1 ships.** The chapter lands when the
playground actually runs. Premature naming would be aspirational;
post-Phase-1 naming is recognition.

### B-9 — `scratch/` is its own local-only git repo ✅ DONE 2026-04-27

`scratch/` was made into its own git repo with no remote, push.default
= nothing, denyNonFastForwards, denyDeletes. Forward-only by habit
(`git revert <hash>` on regret; never `git reset --hard`). Parent
repo's `.gitignore` excludes `scratch/`.

This umbrella's canonical docs (BACKLOG.md, PHASES.md, INDEX.md,
etc.) live IN the parent repo and get pushed. Workshop drafts that
aren't ready yet stay in `scratch/`.

**Defer until user calls it.** No urgency.

---

## How the work proceeds

After this backlog is on disk:

1. ✅ B-1 (archive CLAUDE.md) — committed a5691e6.
2. ✅ B-2 (substrate key-type check) — substrate ready as designed.
3. ✅ B-3 (performance target) — **≥272 candles/sec sustained**.
4. Open Phase 1 / slice 1.
5. B-4, B-5, B-6, B-7 are policies that apply DURING the slicing.
6. B-8, B-9, B-10 stay as flags; revisit when relevant.

The discipline: **mechanical items first**, then verifications,
then start the slicing. Each step a clean commit. The wards
catch what they catch.

PERSEVERARE
