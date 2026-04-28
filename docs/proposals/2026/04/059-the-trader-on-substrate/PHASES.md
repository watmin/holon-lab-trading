# Build plan — Proposal 056 fresh on the new substrate (v2)

**Date:** 2026-04-27. v2 supersedes v1 after the user's redirection:

- *"i'm not convinced the thoughts we were crafting are solid any more —
  they were a placeholder to prove complex things can be represented"*
- *"the representation had catastrophic flaws (the rounding issues) that
  we identified when we began to rebuild parts of it"*
- *"we can use the market reviewers as the guidance for what thoughts to
  craft... we know how to think better now and we can do it in wat"*
- **Architecture survives.** **Thoughts are dynamic.** **Wire first; iterate
  thoughts later.**
- *"one voice per subagent is the best."*

The previous plan (v1) committed to 056's specific thought encoding
(indicator-rhythm + bigrams-of-trigrams + per-indicator Thermometer ranges)
across 8 slices. The user is saying that encoding was a placeholder. v2
flips the order: build the architecture (the playground) with disposable
thoughts, then iterate the thoughts in the playground using a
designer-subagent protocol borrowed from o.g. wat (`~/work/holon/wat/.claude/skills/`).

---

## What survives, what doesn't

### Survives (do not redesign)

- **055's game.** Treasury / deadline / four gates / residue split / paper
  vs real positions / `ProposerRecord` / conservation invariant. The
  pressure dynamic ("interest → expiration") moved from 054 to 055; 055's
  game is the contract between brokers and capital.
- **056's structural three-role shape.** Market Observer (direction) →
  Regime Observer (interpretation, middleware) → Broker-Observer (action).
  Each has its own subspace. The data flow (MarketChain →
  MarketRegimeChain → broker thought) is correct.
- **The substrate primitives.** Arc 003 (TCO), arc 023 (`coincident?`),
  arc 053 (Reckoner takes HolonAST labels), arc 057 (typed leaves +
  derive-Hash), arc 058 (`HashMap<HolonAST,V>`), arc 068 (`eval-step!`),
  proof 016 v4 (dual-LRU coordinate cache), proof 017 (fuzzy-locality
  cache). All shipped; all stable.
- **The predictive geometry from BOOK Chapter 1.** Conviction curve
  (60.2% at conviction ≥ 0.22 → 70.9% at ≥ 0.25), d' = 0.734 thought-
  vector separation. The math holds. *The discriminant doesn't depend on
  which thoughts we craft; it depends on the labeled outcomes converging
  on a direction in HD space.*

### Discarded (open for redesign)

- **056's specific thought-encoding details.** The indicator-rhythm
  function. The bigram-of-trigrams structure. The per-candle delta
  fact-bundles. The 33-fact-from-current-candle photograph. These were a
  placeholder; the rebuild surfaced rounding issues and other limits.
- **The specific atom names + Thermometer ranges per indicator.** Open
  for re-derivation through the designer protocol.
- **The "what" of each thinker's vocabulary.** Specifically what RSI's
  rhythm encodes, what regime facts the regime observer extracts, what
  anxiety atoms the broker carries — these get re-derived from the
  reviewer voices.

### To-be-recovered (subagent task)

- **The labeling discipline.** BOOK chapters 45 (*The Label*), 46
  (*The Proof*), 56 (*Labels as Coordinates*), 57 (*The Continuum*),
  62 (*The Axiomatic Surface*), 65/66 — the framework for *"these
  coordinates tend toward these labels."* This is how the running
  playground tells us which thoughts produce grace vs violence. A
  subagent should distill this into a single discipline doc before
  Phase 2 starts.

---

## The o.g. wat designer protocol

Studied at `/home/watmin/work/holon/wat/.claude/skills/designers/SKILL.md`
and `propose/SKILL.md`. Convention:

- **One voice per subagent.** The o.g. wat had two designers (Hickey,
  Beckman); the lab has extended to five for trading work (Wyckoff,
  Beckman, Hickey, Seykota, Van Tharp).
- **No cross-talk.** Each designer writes its review in isolation; no
  debate within a round. The datamancer reads all reviews and synthesizes
  via RESOLUTION.md.
- **Verdicts: APPROVED / CONDITIONAL / REJECTED.** Free-form prose body;
  three discrete verdicts.
- **Disagreement is signal, not noise.** When designers disagree, the
  tension reveals the design choice; the datamancer routes it to the next
  proposal.
- **No auto-spawn.** Designers are invoked manually by the datamancer at
  the right moment, scope-typed (algebra / structural / userland).

For the trading lab's THOUGHT CRAFTING phase, this protocol applies
directly:

- Each reviewer becomes a subagent voice that **proposes thoughts in
  their philosophical lens.**
- The thoughts are written as wat code — real forms on the new substrate.
- The trader's playground runs them; labels accumulate.
- The datamancer reads outcomes and decides which voice's thoughts deserve
  further investment.

---

## Phase 1 — The Playground (~6 weeks, May 2026)

**Goal:** A running self-organizing trader on the new substrate, with
055's full game wired in and 056's three-role architecture in place,
using PLACEHOLDER thoughts that produce signal flow but are not the
final encoding. By end of Phase 1, the trader is RUNNING — its
predictions may be only modestly above random — and the playground is
ready for thought-iteration.

### Slice 1 — Substrate baseline + L1/L2 cache wired (1 week)

**B-2 finding (2026-04-27):** the substrate is correctly layered.
HolonAST = identity (cache key); Vector = encoded measurement
(subspace/reckoner consume); HolonAST = label naming via arc 053.
No adapter or new arc needed.

The cache is non-negotiable in slice 1 — not deferred, not
"profile-first." The substrate's chapter-65/66/67 claims rest on
the cache being there. The lab's caching cookbook is well-known
(arc 001 / arc 036 + the wat-vm's queue-based program shape).
Queues do all the work the trader needs.

**Slice 1 deliverables:**

- **L1 — thread-owned local cache.** `wat::lru::LocalCache<HolonAST,
  Vector>` per thinker. Memoizes the (thought-AST → encoded-vector)
  mapping. Caches the dual-LRU coordinate pairs (form → next-form,
  form → terminal-value) per proof 016 v4. Zero-Mutex; thread owns
  it; values up.
- **L2 — queue-addressed shared cache.** `wat::CacheService`
  program. Queues are the messaging primitive across the wat-vm.
  Cross-thinker work sharing per chapter 67's spell. Each thinker
  queries L1 first; misses fall through to L2 via a request/reply
  queue pair; L2 misses fall through to fresh computation;
  results promote back to L1. The fuzzy-locality cache (proof
  017) lives at L2 — `coincident?`-keyed for cross-thinker
  neighborhood matching.
- **One probe test:** encode a placeholder thought twice; second
  encoding hits L1. Two thinkers encode coincident thoughts; second
  thinker hits L2 via `coincident?`.
- **Output:** the playground's caching infrastructure ready for
  real workloads. Subsequent slices (treasury, three-role skeleton,
  etc.) wire on top of this without re-architecting.

**Why this matters:** the talk's claim — *"cold-boot to
sustainability on a single laptop, no GPU, no cloud"* — is
load-bearing on the cache being there. The L1+L2 layered cache IS
what makes the trader fit on one laptop while the predictive
geometry holds. Without it, the trader still works but the
substrate's distinctive properties (chapter-65 coordinates,
chapter-66 neighborhoods, chapter-67 spell) aren't operational —
they're just decorations.

### Slice 2 — Treasury + deadlines (1 week)

- `Active` / `Grace { residue }` / `Violence` state machine.
- ATR-proportional deadline (`deadline = base * (median_atr / current_atr)`)
  clamped by trust to `[288, 2016]` candles.
- `PaperPosition` (always issued) and `RealPosition` (gated by
  `ProposerRecord` expectancy).
- `ProposerRecord` accumulating papers_submitted / papers_survived /
  papers_failed / total_grace_residue / total_violence_loss.
- Conservation invariant as a substrate-ward — every candle, asserted.
- Output: proof — treasury behaves correctly under deadline pressure
  with placeholder broker proposals.

### Slice 3 — Three-role observer skeleton (2 weeks)

- Market Observer struct + dataflow (consumes candle, emits MarketChain
  with placeholder rhythm).
- Regime Observer struct + dataflow (consumes MarketChain, emits
  MarketRegimeChain with placeholder regime facts).
- Broker-Observer struct + dataflow (consumes MarketRegimeChain, emits
  paper proposals + Hold/Exit gate).
- Per-thinker OnlineSubspace + Reckoner attached.
- **Placeholder thoughts:** simplest possible per-thinker encoding — a
  single Thermometer-wrapped Atom per indicator at the Market level; a
  single Atom for "regime-name" at Regime level; a Bundle of those at
  Broker. This is intentionally bad; it just produces signal flow.
- Output: the three-role architecture wired; data flows end-to-end on
  the substrate.

### Slice 4 — The four gates + retroactive labeling (1 week)

- Gate 1: phase trigger detection (placeholder phase labeler).
- Gate 2: market direction prediction (Market Observer's reckoner).
- Gate 3: residue math (treasury arithmetic).
- Gate 4: position observer Hold/Exit reckoner.
- Trigger trail: each broker maintains the list of triggers it took
  during a paper's life.
- At paper resolution: walk the trail; label each trigger Exit / Hold
  / should-have-Exit'd; feed reckoner via arc 053's HolonAST-label API.
- Output: proof — labels propagate; reckoner discriminant moves
  measurably after N labels are fed.

### Slice 5 — Status panel + 6-year run (1 week)

- Terminal-rendered status panel — glanceable: candles processed,
  throughput, equity, conviction-bucketed win rates, cumulative Grace
  vs Violence, observers' experience, L1/L2 hit rates.
- Conviction-bucketed win-rate display.
- Cache hit-rate display (L1 / L2 / miss).
- Run 6 years of 5-min BTC candles cold start.
- Output: a runnable playground. The numbers will be MEDIOCRE because
  the placeholder thoughts are bad — that's the point. The PLATFORM is
  what Phase 1 ships.

### What Phase 1 deliberately doesn't do

- Does not optimize predictions. Placeholder thoughts produce mediocre
  signal; that's expected. The playground is the deliverable.
- Does not commit to specific indicator vocabularies, atom names,
  Thermometer ranges, regime fact lists. Those are Phase 2 territory.
- Does not finalize the Broker-Observer's anxiety atoms. Those need
  designer voices.

---

## Phase 2 — The Thoughts (~6 weeks, June–early July 2026)

**Goal:** Iterate thoughts through the designer-subagent protocol,
running each candidate against the Phase 1 playground, watching labels
accumulate at coordinates, and using grace/violence label distributions
to choose which thoughts advance.

### Pre-step — Recover the labeling discipline (subagent task)

Before Phase 2 starts, spawn a subagent to read BOOK chapters 45 (*The
Label*), 46 (*The Proof*), 55 (*The Bridge*), 56 (*Labels as
Coordinates*), 57 (*The Continuum*), 62 (*The Axiomatic Surface*), 65
(*The Hologram of a Form*), 66 (*The Fuzziness*) and produce a single
distillation document: **"How the lab labels coordinates."** This
captures the discipline that's been built up across the chapters and
makes it the operational guide for Phase 2.

Output: `scratch/LABELING-DISCIPLINE.md`.

### Designer-subagent protocol for thought crafting

For each thinker (Market / Regime / Broker — and possibly per-indicator
within Market), invoke designer subagents in their voice. The protocol
mirrors o.g. wat:

- **One voice per subagent.** No cross-talk during a round.
- **The voice's job:** propose a thought in wat — a real form, on the
  new substrate, expressible as a HolonAST that the cache can key.
- **Voices and their lenses:**
  - **Wyckoff** — accumulation/distribution, volume on rallies vs
    declines, springs/upthrusts, climactic action. *"What is this market
    accumulating right now?"*
  - **Seykota** — trend persistence, selection over prediction, "let
    your winners run." *"Is the market in a trend strong enough to
    follow?"*
  - **Van Tharp** — expectancy, R-multiples, position sizing. *"Is the
    risk-reward worth taking?"*
  - **Hickey** — simplicity, values-not-places, composition integrity.
    *"Is this thought composing cleanly without complecting concerns?"*
  - **Beckman** — monoidal coherence, algebraic closure, functor
    relationships. *"Is this thought algebraically sound — does it
    compose with itself and its siblings under bind/bundle?"*
- **Output of each subagent:** a wat code snippet defining the thought
  (a HolonAST-producing function), plus prose explaining why this
  thought belongs in their philosophical lens.
- **Datamancer's job:** read all voices' contributions; pick which
  thoughts to wire into the playground; run them; watch labels
  accumulate; iterate.

### The iteration loop

For each thinker:

1. **Spawn designer subagents** with a question scoped to that thinker
   (e.g., "what should a Market Observer think about?").
2. **Each designer returns a wat-coded thought** in their voice.
3. **Wire candidate thoughts into the playground.** Replace the
   placeholder thought; run a backtest segment.
4. **Read the labels.** Where do this thought's coordinates accumulate
   grace? Where do they accumulate violence? Are the grace coordinates
   meaningfully separable from violence coordinates?
5. **Decide.** Keep the thought, drop it, or hand it back to the
   designer for revision.
6. **Compose** — once individual thinkers' thoughts are stable, verify
   that the broker's outer bundle (composition of market + regime +
   anxiety + phase rhythms) doesn't blow Kanerva capacity and that the
   reckoner's discriminant geometry holds.

### What "labels accumulate at coordinates" looks like operationally

The Phase 1 playground emits, per resolved paper:

- The set of (form-coordinate, label) pairs from the trigger trail,
  where label ∈ {Exit, Hold, should-have-Exit'd}.
- The paper's resolution (Grace { residue } | Violence).
- The broker's composed thought-coordinate at each gate.

Phase 2 reads these and asks:

- *Which coordinates tend toward Grace?* — direction-on-the-sphere
  that grace-resolved papers' trigger coordinates point in.
- *Which coordinates tend toward Violence?* — same for violence
  papers.
- *Are they separable?* — d' between the two distributions; if it's
  approaching BOOK Ch.1's documented 0.734, the thought is good.
- *Does conviction filter help?* — the conviction curve from Ch.1 is
  the test: at conviction ≥ 0.22, do the predictions hit 60%? At
  ≥ 0.25, 70%?

When a thought reproduces (or beats) the Ch.1 numbers, it's good. When
it doesn't, the designer subagent revises. **The labeling tells us
which thoughts work; the playground tells us by running them.**

### Phase 2 doesn't have predetermined slices

The iteration is open-ended. We start with one thinker (probably
Market Observer, because Ch.1's documented numbers are at the Market
prediction level) and iterate until its thought is stable. Then move
to Regime, then Broker. The pace is set by what the labeling reveals.

---

## Phase 3 — Sustained run (~1 week)

**Goal:** End-to-end 6-year backtest with the iterated Phase 2
thoughts. Confirm the sustained-state numbers.

- 6 years of 5-min BTC candles processed cold start (652,608 rows
  in `data/btc_5m_raw.parquet`).
- Throughput sustained ≥272 candles/sec.
- Memory peak ≤30 GB.
- Conviction-filtered win rate confirmed in the 60–71% range at
  the appropriate filter levels (matches BOOK Chapter 1's documented
  numbers — 60.2% at conviction ≥ 0.22, 65.9% at ≥ 0.24, 70.9% at
  ≥ 0.25).
- Cumulative Grace > cumulative Violence under venue costs (0.35%
  per swap; conviction filter clears the threshold per
  `project_venue_costs`).

If Phase 2's iteration produced thoughts that beat the placeholder
substantially, the headline numbers come from this run. If not, the
phase reports the cold-boot LEARNING shape (rather than PROFITABILITY)
honestly — the wards exist explicitly to prevent overclaim.

---

## Open question — the BOOK chapter for this recognition

The phase-1/phase-2 split is itself a recognition worth a chapter:
*"the architecture is known-good; the thoughts are dynamic; build the
playground first; iterate thoughts inside it."* This is the BOOK
Chapter 55 bridge made operational at the build level — *thinkers
express; substrate measures; labels arrive over time; the lab gets
better not by editing prose but by accumulating evidence.*

Possible chapter title (defer to /gaze): *"The Playground"* or *"The
Iteration"* or *"The Labels Arrive."*

This chapter probably wants writing AFTER Phase 1 ships, not before —
the recognition lands when the playground actually runs.

---

## Calendar

- **Phase 1 (~6 weeks)** — 5 slices. Playground ships. Trader runs
  end-to-end with placeholder thoughts on the new substrate.
- **Phase 2 (~6 weeks)** — Recover labeling discipline (1-day
  subagent task → `LABELING-DISCIPLINE.md` in this umbrella).
  Iterate Market Observer thoughts. Then Regime. Then Broker.
  Open-ended; pace set by what the labeling reveals.
- **Phase 3 (~1 week)** — Sustained-run backtest. Headline numbers
  captured.

PERSEVERARE
