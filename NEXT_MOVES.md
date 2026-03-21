# Next Moves — Holon BTC Trader

## Current Baseline (Run: 2026-03-20)

Walk-forward over 652k 5-min BTC candles (2019-2025) at 10kD.
Single pair of decaying accumulators (decay=0.999), four-case algebraic correction
(resonance/negate/grover_amplify), discriminative recalibration every 500 updates.

Key observation: rolling accuracy oscillates between ~32-61%, recovering from
regime-change dips within ~1000 labeled updates. The model adapts — this is
fundamentally different from the static 50-53% we saw with fixed prototypes.

---

## Technique Candidates

### 1. Multi-Timescale Accumulators

Run 3 accumulator pairs per class at different decay rates:
- **Fast** (decay=0.99, ~100 sample memory) — catches regime shifts immediately
- **Medium** (decay=0.999, ~1000 samples) — current baseline
- **Slow** (decay=0.9999, ~10000 samples) — structural long-term patterns

Prediction: compute similarity against all three, combine via voting or
`resonance` across prototypes to find cross-timescale agreement. When fast
and slow disagree, the market is transitioning — that's actionable information.

**Cost**: Minimal code change. 3x accumulator memory. Same encoding pipeline.

**TESTED (2026-03-21) — RULED OUT.** Three variants tested at 50k candles:

| Variant | Return | Win Rate | j_acc Overall |
|---------|--------|----------|---------------|
| Baseline (single decay=0.999) | +0.04% | 50.0% | 50.1% |
| Weighted avg (fast×0.5 + med×1.0 + slow×0.5) | -7.42% | 46.7% | 46.8% |
| Max similarity (best of three timescales) | -1.47% | 49.0% | 49.4% |
| Med-only prediction, multi-timescale learning | -7.42% | 46.7% | 46.8% |

Key finding: multi-timescale observe() corrupts accumulator state. The
confuser counts become wildly imbalanced (49 buy_confuser vs 15,861
sell_confuser vs baseline's balanced 7,327/7,585). Adding the same vector
to three accumulators at different decay rates and then applying algebraic
corrections computed from the medium prototype to all three timescales
destabilizes the prototypes. The correction is regime-dependent and only
valid for the timescale it was computed from — applying a medium-timescale
correction to a fast accumulator pushes it in a direction that's wrong for
its short-term view, and vice versa for the slow accumulator.

The weighted-average and med-only variants produced identical results,
confirming the damage comes from multi-timescale learning, not prediction.
Agreement-based conviction scaling was also a no-op (conviction is only
used as a binary >0 gate, scaling doesn't change the sign).

**Follow-up (per-timescale corrections)**: Fixed two bugs: (1) predict()
wasn't using discriminative prototypes (buy_disc/sell_disc), classifying
against raw prototypes with cos=0.90 instead of disc protos with cos=0.0;
(2) algebraic corrections now computed independently per timescale using
each timescale's own prototypes. With both fixes, confuser balance
restored (7,191/8,131). However, reading from multiple timescales (max
of per-timescale disc proto similarities) still degrades accuracy vs
baseline (-4.14% vs +0.04%). Using medium-only disc protos with
multi-timescale learning matches baseline exactly. Conclusion: the extra
timescales don't contribute useful signal for prediction. Moving on.

### 2. Engram Library — Sub-Pattern Clustering

Maintain separate prototypes for distinct sub-patterns within each class.
A breakout-buy looks nothing like a dip-buy; superimposing them destroys both.

When a new viewport arrives, check similarity against all engrams. If close
to one, reinforce it. If not close to any, create a new engram. Classification
becomes: "closer to *any* buy engram than *any* sell engram?"

**Cost**: Moderate. Engram management (creation, merging, pruning). The Rust
crate has `EngramLibrary` but it stores `OnlineSubspace` snapshots — we may
want accumulator-based engrams instead.

### 3. Regime Detection via Resonance

`resonance(viewport_t, viewport_t-1)` measures how much the current market
state shares with the previous one. Sharp drops indicate regime shifts.

Use this to gate learning: during stable regimes, trust accumulators (lower
correction weight). During transitions, increase correction weight and decay
temporarily. The model becomes self-aware of its own uncertainty.

**Cost**: Cheap. One extra resonance call per step + gating logic.

### 4. Temporal Binding — Sequences, Not Snapshots

Each viewport is currently independent. `bind(viewport_t, viewport_t-1)`
creates a transition vector capturing "where we were AND where we are."
Chaining 3-5 viewports captures momentum trajectories.

Maintain separate accumulators for single-viewport and transition-vector
classification, then combine signals.

**Cost**: Moderate. Extra encoding per step (bind operations). Additional
accumulator pairs. Increases the "what" the model sees.

### 5. Subspace Classification (OnlineSubspace)

Instead of a single prototype per class, maintain an `OnlineSubspace` that
captures the principal directions of variation. Classification via subspace
projection captures more nuance than cosine similarity against a single vector.

The Rust crate has `OnlineSubspace` with gated updates. Can run alongside
accumulators as a second opinion.

**Cost**: Moderate. CCIPCA updates are cheap. Adds a parallel classification
channel.

### 6. Contrastive Sharpening via Difference

Currently `recalibrate()` uses `resonance` to find shared signal and `negate`
to remove it. Go further: `difference(buy_proto, sell_proto)` produces a
change vector highlighting what's exclusively buy-like. Use as an additional
discriminative feature.

**Cost**: Cheap. One extra operation during recalibration.

---

### 7. Confidence-Gated Learning

Scale reward/correction weights by prediction confidence (the similarity gap).
Coin-flip predictions (gap ~0.01) get gentle updates. High-confidence wrongs
get aggressive surgery. Prevents the model from over-reinforcing noise.

    gap = abs(buy_sim - sell_sim)
    effective_weight = base_weight * gap.clamp(min_gate, 1.0)

**Cost**: Trivial. One multiply per update.

**TESTED (2026-03-21) — CONFIRMED.** gate = conviction.abs().clamp(0.3, 1.0).
At 100k candles: equity $10,250 (+2.50%) vs baseline $10,004 (+0.04%).
62x better return. Model stays CONFIDENT for 80k straight candles vs
baseline's ~20k streaks. The gating stabilizes prototypes by reducing
update weight for ambiguous predictions, preventing prototype smearing.
Win rate slightly lower (49.6% vs 50.0%) but position sizing is much
better due to sustained CONFIDENT phase.

### 8. Layered Resonance Filtering

Run vectors through multiple rounds of resonance before accumulation:
`resonance(resonance(vec, proto), proto)` — progressive distillation.
Each pass strips noise, keeps deeply aligned signal. For wrong predictions,
multiple rounds of `negate` peel away layers of misleading features.

**Cost**: Low. Extra resonance calls per update. Tunable depth (2-3 passes).

### 9. Cross-Class Surgical Feedback

When BUY predicted but SELL actual:
1. `resonance(vec, sell_proto)` extracts what fooled us
2. `negate(vec, fooled)` strips it -> cleaned vector -> add to buy accumulator
3. The fooled signal ALSO feeds the sell accumulator — it's evidence of hidden
   sell-like features

One wrong prediction feeds *both* classes simultaneously.

**Cost**: Low. Two extra primitive calls per wrong prediction.

**TESTED (2026-03-21) — RULED OUT.** Stacked on #7+#10. Accumulator
counts jumped from 68k to 85k due to double-feeding on wrong predictions.
Equity dropped from +3.31% to +0.14%. Rolling j_acc ended at 46.6%
(worst of all variants). The extra add_weighted per wrong prediction
smears prototypes. The correction path already handles wrong predictions
adequately — adding more material is counterproductive.

### 10. Recognition Rejection (Ambiguity Pruning)

Not every sample should be learned from. If `max(buy_sim, sell_sim) < threshold`,
the market is doing something the model has never seen. Skip the update entirely.
Only learn from clear signals. Prevents poisoning accumulators with ambiguous noise.

**Cost**: Trivial. One comparison per update.

### 11. Negative Prototyping (Confuser Tracking)

Maintain a third accumulator per class: "things that looked like BUY but were
SELL" — a confuser accumulator. Before predicting, check similarity against
confusers. If a vector matches a known confuser pattern, downweight or flip
the prediction. Explicitly tracks failure modes.

**Cost**: Low-moderate. Two extra accumulators + similarity checks.

### 12. Iterative Grover Amplification

`grover_amplify(signal, background, iterations)` — currently using iterations=1.
Scale iterations by prediction error magnitude. Barely-wrong: 1 iteration.
Wildly-wrong: 3 iterations. More aggressive correction for bigger mistakes.

**Cost**: Trivial. Already have the primitive, just vary the parameter.

### 13. Soft-then-Hard Filtering (Attend + Resonance Chain)

`attend(vec, proto, alpha, Soft)` for broad feature weighting, then
`resonance(attended, proto)` for sharp filtering. Two-stage pipeline:
soft focus first, hard focus second. Captures more nuance than either alone.

**Cost**: Low. One extra primitive call per update path.

### 14. Analogy-Based Correction

Replace the resonance/negate/amplify correction chain with `analogy`:

    analogy(buy_proto, sell_proto, vec)
    = vec + difference(sell_proto, buy_proto)
    = "transform this misidentified vector from buy-space to sell-space"

Feed the result to sell_good. One clean operation, same total weight as
current correction, no double-feeding. Uses the structural relationship
between the two classes to re-map the vector rather than surgically
stripping features. Preserves information (transformative) vs current
approach (subtractive via negate).

Two variants to test:
- Additive analogy: `analogy(wrong_proto, correct_proto, vec)` (primer definition)
- Multiplicative analogy: `bind(vec, bind(buy_proto, sell_proto))` (VSA self-inverse)

**Cost**: Trivial. One primitive call replaces three.

### 15. Blend-Based Gentle Correction

Instead of add_weighted with a corrected vector, use `blend(vec, correct_proto, alpha)`
to gently nudge the misidentified vector toward the correct class. Alpha controls
how aggressive the correction is. Less surgical than resonance/negate but also
less destructive.

**Cost**: Trivial. One blend call.

### 16. Complexity-Gated Learning

Use `complexity(vec)` to measure how "mixed" a vector is before learning.
High complexity = dense superposition of many patterns = ambiguous sample.
More principled version of recognition rejection — instead of a fixed
similarity threshold, use the vector's own information content to decide
whether to learn from it.

**Cost**: Trivial. One complexity call per update.

### 17. Reject-Based Class Isolation (OnlineSubspace)

Maintain per-class `OnlineSubspace` instances. `reject(vec, buy_subspace)`
isolates what's NOT buy-like — that remainder is, by definition, the sell
signal. Classification via subspace residual rather than prototype cosine.
Richer than single-prototype comparison.

Requires technique #5 (Subspace Classification) as foundation.

**Cost**: Medium. OnlineSubspace per class + residual scoring.

### 18. Similarity Profile Targeted Correction

Use `similarity_profile(vec, proto)` for dimension-wise agreement instead
of scalar cosine. Enables targeted corrections on specific dimensions
where the prediction went wrong, rather than correcting the entire vector.
Surgical at the dimension level rather than the vector level.

**Cost**: Low. One similarity_profile call + selective update.

---

## Priority Assessment

| # | Technique | Impact | Complexity | Category | Status |
|---|-----------|--------|------------|----------|--------|
| 7 | Confidence-gated learning | High | Trivial | Reinforcement | **CONFIRMED** |
| 10 | Recognition rejection | High | Trivial | Pruning | **CONFIRMED** |
| 14 | Analogy-based correction | High | Trivial | Reinforcement | Queued |
| 12 | Iterative grover amplification | Medium | Trivial | Reinforcement | Queued |
| 16 | Complexity-gated learning | Medium | Trivial | Pruning | Queued |
| 15 | Blend-based gentle correction | Medium | Trivial | Reinforcement | Queued |
| 8 | Layered resonance filtering | Medium | Low | Reinforcement | Queued |
| 13 | Soft-then-hard filtering | Medium | Low | Reinforcement | Queued |
| 18 | Similarity profile correction | Medium | Low | Reinforcement | Queued |
| 3 | Regime detection | Medium | Low | Architecture | Queued |
| 11 | Negative prototyping | Medium | Low-Med | Pruning | Already impl (confusers) |
| 2 | Engram library | High | Medium | Architecture | Queued |
| 17 | Reject-based class isolation | High | Medium | Architecture | Queued |
| 4 | Temporal binding | Medium | Medium | Encoding | Queued |
| 5 | Subspace classification | Medium | Medium | Architecture | Queued |
| 6 | Contrastive sharpening | Low | Low | Reinforcement | Queued |
| 9 | Cross-class surgical feedback | Low | Low | Reinforcement | **RULED OUT** |
| 1 | Multi-timescale accumulators | Low | Low | Architecture | **RULED OUT** |

---

## Two-Agent Self-Supervised Trader

Academic benchmark: 52% prediction accuracy is state of the art for non-bogus
BTC forecasting research. Our baseline oscillates 32-61%, settling ~50%.
Goal: sustained 52%+ with proper walk-forward AND profitable P&L through
position sizing.

### Architecture: Journaler + Trader

Two agents with different roles, sharing the same viewport encoding pipeline.

**The Journaler (always learning, never trading)**

Evaluates EVERY candle. For each candle at time t, waits 36 candles (3 hours)
and measures the outcome from raw price action:

    outcome = (close[t+36] - close[t]) / close[t]
    if outcome > 0.005 (+0.5%)  -> self-label "BUY_OPPORTUNITY"
    if outcome < -0.005 (-0.5%) -> self-label "SELL_OPPORTUNITY"
    else                        -> "NOISE" (skip)

No pre-computed oracle labels. The system discovers what BUY/SELL mean.

The journaler maintains:
- buy_accum / sell_accum: what patterns precede price rises/falls
- buy_confuser / sell_confuser: patterns that LOOKED like buys but preceded
  drops (and vice versa) — explicit failure mode memory
- All with decay for regime adaptation

The journaler sees the ENTIRE market. No survivorship bias. Its job is to
build a comprehensive map of market microstructure over time.

**The Trader (acts on conviction, sized by confidence)**

Consults the journaler before acting. Decision process:

    1. Encode current viewport
    2. Ask journaler: similarity to known-good buy/sell patterns?
    3. Ask journaler: similarity to known CONFUSER patterns?
    4. conviction = good_similarity - confuser_similarity
    5. confidence = f(rolling_track_record)
    6. position_size = base_allocation * conviction * confidence_modifier
    7. If position_size > min_threshold -> act, else sit out

The trader learns from its OWN trades only. When a trade resolves:
- Profitable: reinforce (resonance + amplify the aligned signal)
- Unprofitable: correct (negate misleading features, amplify residual)

This creates a feedback loop specific to trades actually taken.

### Self-Labeling from Outcomes

The journaler replaces all oracle label columns. For every candle:

    horizon = 36 candles (3 hours at 5-min bars)
    move_threshold = 0.005 (0.5%)

    price_at_entry = close[t]
    price_at_exit  = close[t + horizon]
    pct_change     = (price_at_exit - price_at_entry) / price_at_entry

    if pct_change > move_threshold  -> BUY_OPPORTUNITY
    if pct_change < -move_threshold -> SELL_OPPORTUNITY
    else                            -> NOISE (no clear signal, skip)

This runs continuously. The journaler never stops learning.

### Risk Management & Position Sizing

Position sizing based on confidence with overconfidence penalty:

    confidence = rolling_accuracy - 0.50  (range: -0.5 to 0.5)

    if confidence < 0.00 -> position_size = 0%   (worse than random, sit out)
    if confidence < 0.05 -> position_size = 0.5% (tentative)
    if confidence < 0.10 -> position_size = 1.0% (moderate)
    else                 -> position_size = min(2.0%, confidence * 10%)

The cap (2%) is the overconfidence penalty. No matter how good the model
thinks it is, it never risks more than 2% per trade. Kelly criterion adapted
for uncertain edge.

P&L tracking transforms the objective from "prediction accuracy" to "equity
curve." A 52% accurate system with good sizing massively outperforms 55%
with flat sizing.

### Progressive Confidence Phases

    OBSERVE -> TENTATIVE -> CONFIDENT -> (back to TENTATIVE on regime break)

**OBSERVE** (cold start, first N outcome observations):
No predictions. Journaler watches outcomes, builds initial accumulators
from pure observation. Zero risk. System is learning what the world looks
like before price moves.

**TENTATIVE** (track record building):
Start predicting with minimum position sizes. Track rolling hit rate.
High correction_weight, low reward_weight — learn aggressively.
Promote to CONFIDENT when rolling accuracy > 52% for 500+ predictions.

**CONFIDENT** (proven edge):
Full position sizing per confidence curve. Lower correction, higher reward.
Demote to TENTATIVE when rolling accuracy drops below 50% for 200+
predictions. Self-regulating.

Continuous form (applied within TENTATIVE and CONFIDENT):

    correction_weight = base_correction * (1.0 - confidence)
    reward_weight = base_reward * (0.5 + confidence)

Doing well -> reinforce more, correct less.
Struggling -> correct aggressively, reinforce gently.

### Four-Accumulator Outcome Memory (Journaler)

    buy_good     — patterns preceding confirmed price rises
    buy_confuser — patterns that looked buy-like but preceded drops
    sell_good    — patterns preceding confirmed price falls
    sell_confuser— patterns that looked sell-like but preceded rises

Before the trader acts, confuser check:

    if cos(vec, buy_confuser) > cos(vec, buy_good) -> DON'T BUY (trap pattern)
    if cos(vec, sell_confuser) > cos(vec, sell_good) -> DON'T SELL (trap pattern)

The system remembers its mistakes and learns to avoid repeating them.

### Stop-Loss / Early Exit (Follow-on)

Once the two-agent system works with fixed-horizon trades, add mid-trade
monitoring using the journaler's confuser memory:

    while position is open (t to t+36):
        encode viewport at t+k
        confuser_sim = cos(viewport, confuser_proto_for_our_direction)
        if confuser_sim > bail_threshold -> early exit at close[t+k]
        if k == 36 -> natural exit

Requires: journaler confuser memory to exist first. Variable-length trades
change how the journaler self-labels — build fixed-horizon first, then
add early exit as refinement.

### Epoch Training

After a full pass through 2019-2025, restart from 2019 with end-of-run
accumulator state. Like neural net epochs — the model re-learns 2019 with
structural wisdom from 2025. Each epoch refines prototypes.

Tuning: lower decay on later epochs (0.9999 vs 0.999) so the model retains
more as it gets smarter. Track per-epoch accuracy to detect convergence.

### Composability

All techniques from the candidate list plug into this architecture:
- Multi-timescale (#1) -> different decay rates on journaler accumulators
- Confidence gating (#7) -> driven by trader's self-assessed track record
- Recognition rejection (#10) -> "unfamiliar AND confuser unknown -> sit out"
- Cross-class feedback (#9) -> wrong predictions feed both journaler classes
- Regime detection (#3) -> gates phase transitions (CONFIDENT -> TENTATIVE)
- Engram library (#2) -> sub-patterns within each of the four categories
- Negative prototyping (#11) -> IS the confuser accumulators
- Layered resonance (#8) -> multi-pass filtering in journaler updates
- Iterative grover (#12) -> scale correction strength by error magnitude

Pure Holon algebra. No gradients, no backprop, no GPU.

---

## Implementation Roadmap

### Phase 1: Self-Supervised Journaler (replace oracle labels)

Refactor main.rs: remove oracle label dependency. Journaler self-labels from
price action outcomes (0.5% threshold, 36-candle horizon). Four accumulators
(buy_good, buy_confuser, sell_good, sell_confuser). All existing algebraic
correction logic transfers to journaler updates.

Deliverable: walk-forward run with NO oracle labels, reporting rolling accuracy
of journaler predictions vs actual outcomes. Compare to current baseline.

### Phase 2: Trader Agent + Position Sizing

Add trader agent that consults journaler for predictions. Implement conviction
scoring (good_sim - confuser_sim). Add position sizing with confidence curve
and overconfidence cap. Track simulated P&L (equity curve) alongside accuracy.

Deliverable: equity curve over 652k candles. Compare to buy-and-hold baseline.

### Phase 3: Progressive Confidence + Reinforcement Pipeline

Add OBSERVE/TENTATIVE/CONFIDENT state machine. Wire in Wave 1 techniques:
confidence gating, recognition rejection, iterative grover scaling. Trader
learns from its own trade outcomes with self-regulating weights.

Deliverable: improved equity curve. Per-phase accuracy breakdown.

### Phase 4: Advanced Composition

Multi-timescale journaler accumulators. Engram library for sub-patterns.
Temporal binding for momentum context. Epoch training.

### Phase 5: Stop-Loss + Live Readiness

Mid-trade confuser monitoring for early exit. Variable-length trade P&L.
Real-time encoding pipeline for live trading.
