# 059 — The trader on the substrate (umbrella)

**Status:** opened 2026-04-27. Multi-sub-arc umbrella; modeled on 058's
shape. Each sub-arc is focused and shippable independently; the umbrella
holds the foundation, vision, open questions, and cross-cutting work.

## What this umbrella is

The substrate has matured (arcs 003 / 023 / 053 / 057 / 058 / 068 + proofs
016 v4 + 017). Three lab proposals are unanimously approved (055 — treasury
+ deadlines, 056 — three-thinker thought architecture, 057 — L1/L2 cache).
This umbrella ships the trader that executes 055+056+057 on the new
substrate, in three phases, with each phase's slices implemented as focused
sub-arcs colocated here.

**Performance target:** ≥272 candles/sec sustained — processes the 652,608-
row BTC parquet (`data/btc_5m_raw.parquet`, Jan 2019 – Mar 2025) in 40
minutes wall time on 14 cores / 54 GB RAM / no GPU. The substrate's
chapter-65/66/67 cache primitives are how this fits.

## Files at the umbrella level

- `INDEX.md` — this file. Table of contents.
- `VISION.md` — what we're building and why; the demo arc.
- `FOUNDATION.md` — predecessor proposals + substrate primitives that
  this umbrella stands on.
- `OPEN-QUESTIONS.md` — the questions we'll answer empirically through
  the playground. Includes the labeling discipline that needs recovery
  from BOOK chapters before Phase 2.
- `PHASES.md` — the three-phase plan (Phase 1 = playground; Phase 2 =
  thoughts; Phase 3 = sustained-run backtest). Promoted from
  `scratch/BUILD-PLAN-056.md`.
- `BACKLOG.md` — work tracker. Items resolved before / during the build.
  Promoted from `scratch/BACKLOG.md`.

## Sub-arcs

Phase 1 — the playground:

- `059-001-l1-l2-caches/` — L1 thread-owned + L2 queue-addressed shared
  cache, wired before any thinker code. Cache is non-negotiable.
- `059-002-treasury-deadlines/` (next) — `Active`/`Grace`/`Violence`
  state machine, ATR-proportional deadlines, `ProposerRecord`,
  conservation invariant.
- `059-003-three-role-skeleton/` (next) — Market / Regime / Broker
  observers wired with placeholder thoughts; data flows end-to-end.
- `059-004-four-gates-and-trail/` (next) — the four 055 gates +
  retroactive labeling at paper resolution.
- `059-005-status-panel-and-run/` (next) — terminal status panel +
  cold-start 6-year backtest.

Phase 2 — the thoughts (sub-arcs emerge from the iteration; not
predetermined):

- `059-2xx-...` — designer-subagent passes. Each round = one or more
  thinkers' thoughts crafted in wat through the o.g.-wat designer
  protocol; tested against the playground; labels accumulated; iterated.

Phase 3 — sustained run:

- `059-3xx-full-backtest` — end-to-end 6-year backtest with the
  iterated Phase-2 thoughts; sustained ≥272 c/s; conviction-filtered
  win rate confirmed in the 60-71% range; cumulative Grace > Violence
  under venue costs.

## How sub-arcs ship

Each sub-arc has the shape that arc 068 used (`docs/arc/2026/04/068-eval-step/`):

- `DESIGN.md` — pre-implementation reasoning artifact. Predecessor list,
  user direction quotes, what's already there, what's missing, decisions
  to resolve, what ships.
- `BACKLOG.md` — concrete work plan (slice list, files touched, tests).
- `INSCRIPTION.md` — post-ship record. Written when the slice lands.

The infra session reads `DESIGN.md`, ships the slice, writes
`INSCRIPTION.md`. The lab session opens the next sub-arc.

## Predecessors

- **Proposal 055** — Treasury-Driven Resolution (the game).
- **Proposal 056** — Thought Architecture (three thinkers; rhythms;
  subspace). Note: 056's specific thought encoding was a placeholder;
  Phase 2 re-derives thoughts via the designer-subagent protocol.
- **Proposal 057** — L1/L2 Cache with Parallel Subtree Compute. This
  umbrella's `059-001-l1-l2-caches` ships 057's design on the new
  substrate.
- **Substrate arcs:** 003 (TCO), 023 (`coincident?`), 053 (Reckoner +
  HolonAST labels), 057 (typed leaves), 058 (`HashMap<HolonAST,V>`),
  068 (`eval-step!`).
- **Proofs:** 016 v4 (dual-LRU coordinate cache), 017 (fuzzy-locality
  cache via `coincident?`).
- **BOOK chapters:** 1 (the prediction-rate citations), 55 (the bridge),
  65 (the hologram), 66 (the fuzziness), 67 (the spell), 68 (the
  inscription).
