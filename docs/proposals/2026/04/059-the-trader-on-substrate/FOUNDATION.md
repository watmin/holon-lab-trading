# 059 — Foundation (what's known good)

This umbrella stands on a stack of shipped primitives, approved
proposals, and verified proofs. None of these need redesign;
slice work calls into them as services.

## Substrate primitives (`wat-rs`)

| Arc | What it ships | Used by |
|-----|---------------|---------|
| **003** | TCO trampoline | tail-recursive walkers in any thinker |
| **023** | `coincident?` predicate | fuzzy-locality cache lookup; gate-1 trigger detection |
| **053** | Reckoner accepts HolonAST labels | label registry per thinker |
| **057** | Typed HolonAST leaves; algebra closed under itself | every thought is a HolonAST |
| **058** | `HashMap<HolonAST, V>` at user level | exact-identity cache containers |
| **068** | `:wat::eval-step!` (incremental evaluator) | step-driven thought walks; dual-LRU cache fills as we walk |

## Substrate proofs

| Proof | What it proved | Used by |
|-------|---------------|---------|
| **016 v4** | Dual-LRU coordinate cache (form → next-form, form → terminal-value) keyed by HolonAST identity | the cache architecture for slice 1 |
| **017** | Fuzzy-locality cache via `coincident?` over Thermometer-encoded leaves | cross-thinker work-sharing at the L2 layer |

## Predecessor lab proposals

| Proposal | What's approved | Used by |
|----------|-----------------|---------|
| **055** | Treasury-driven resolution: `Active`/`Grace`/`Violence` state machine; ATR-proportional deadlines clamped by trust to [288, 2016]; four gates at trigger points; 50/50 residue split; conservation invariant; retroactive labeling at paper resolution | `059-002-treasury-deadlines/`, `059-004-four-gates-and-trail/` |
| **056** | Three-thinker thought architecture: Market (direction) / Regime (middleware) / Broker (action). One OnlineSubspace per thinker. Anomaly filtering between thinkers. **The specific thought encoding from 056 is a placeholder; Phase 2 re-derives via designer subagents.** | `059-003-three-role-skeleton/` (architecture only); Phase 2 sub-arcs (thoughts) |
| **057** | L1 per-entity local cache + L2 queue-addressed shared cache + parallel subtree compute via rayon | `059-001-l1-l2-caches/` |

## BOOK chapter citations

| Chapter | What it documents | Why we cite it here |
|---------|-------------------|---------------------|
| **1** | Conviction curve: 60.2% at conviction ≥ 0.22 → 65.9% at ≥ 0.24 → 70.9% at ≥ 0.25; d' = 0.734 thought-vector separation | Phase 3's acceptance numbers |
| **55** | The bridge: thinkers express; substrate measures; labels arrive over time | Phase 2's iteration shape |
| **65** | The hologram of a form: every step is a coordinate; the path is shareable; the terminal is an axiom | The dual-LRU cache's load-bearing claim |
| **66** | The fuzziness: every coordinate has a neighborhood; the substrate's per-leaf encoding picks the depth at which fuzziness emerges | The fuzzy-locality cache (proof 017) consumed by L2 |
| **67** | The spell: the cache is networkable; possession is not capability; seed is membership | Why L2 generalizes naturally to cross-thinker work-sharing |

## Performance contract

**≥272 candles/sec sustained** processes 652,608 5-min BTC
candles in 40 minutes wall time. Below 272/s on a representative
≥10k-candle run is a regression.

## What does NOT survive into this umbrella

- **056's specific indicator-rhythm encoding** (bigrams of trigrams,
  per-indicator atom wrapping, the per-candle delta fact bundles).
  These were placeholder; the rebuild surfaced flaws beyond the
  rounding issue 056 fixed. Phase 2 re-derives from the
  designer-subagent protocol.
- **The pre-substrate ad-hoc cache surface.** Replaced by the
  L1+L2 cookbook on top of arcs 057+058 + proofs 016 v4 + 017.
- **Anything in the archived `CLAUDE-20260427.md`.** It described
  pre-wat-vm architecture; references would mislead.
