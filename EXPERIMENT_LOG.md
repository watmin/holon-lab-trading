# Experiment Log — Holon BTC Trader

Living document tracking experiment results, system architecture, and learnings.

---

## Current Best: #7 + #10 + #3 → **+4.65% return, 50.5% win rate**

| Metric | Value |
|--------|-------|
| Equity | $10,465 (+4.65%) |
| Win rate | 50.5% (33,663/66,599) |
| j_acc overall | 50.6% |
| j_acc rolling | 48.3% |
| Candles | 100,000 (2019-01-01 to 2019-12-15) |
| Buy-and-hold | +89.56% |
| cos(buy_good, sell_good) | 0.9296 |
| cos(buy_good, noise) | 0.5473 |
| cos(sell_good, noise) | 0.5519 |
| buy_good count | 68,051 |
| sell_good count | 66,558 |
| buy_confuser | 16,629 |
| sell_confuser | 16,624 |
| Phase | CONFIDENT |

---

## System Architecture

### Prediction Flow

```mermaid
flowchart TD
    V[/"Encoded Viewport"/] --> NS["Noise Stripping: negate vec, noise_proto"]
    NS --> CS["Cosine Similarity vs buy_disc and sell_disc"]
    CS --> NG{"Noise sim > max class sim?"}
    NG -->|Yes| SIT[/"Sit out"/]
    NG -->|No| CC["Confuser Check: conviction = good_sim - confuser_sim"]
    CC --> PRED{"buy_conviction > sell_conviction?"}
    PRED -->|Yes| BUY[/"Predict BUY"/]
    PRED -->|No| SELL[/"Predict SELL"/]
```

### Learning Flow (Journaler.observe)

```mermaid
flowchart TD
    INPUT[/"vec + outcome + prediction + conviction"/] --> CG["#7 Confidence Gate: weight *= conviction"]
    CG --> NOISE{"Noise?"}
    NOISE -->|Yes| NA["Add to noise_accum"] --> DONE[/"Return"/]
    NOISE -->|No| RR{"#10 Recognition Rejection: max sim < 0.01?"}
    RR -->|Yes| SKIP[/"Skip learning"/]
    RR -->|No| RAW["Raw Accumulation: decay + add vec"]
    RAW --> WRONG{"Predicted wrong?"}
    WRONG -->|Yes| FEED["Feed Confuser accum"]
    WRONG -->|No| GATE
    FEED --> GATE
    GATE["#3 Separation Gate: scale weights by proto divergence"] --> MATCH{"Prediction correct?"}
    MATCH -->|Reward| REWARD["resonance → amplify → add_weighted"]
    MATCH -->|Correction| CORRECT["resonance → negate → amplify → add_weighted"]
    REWARD --> RECAL["Every 500 updates: recalibrate discriminative protos"]
    CORRECT --> RECAL

    style CG fill:#2d6a2d,color:#fff
    style RR fill:#2d6a2d,color:#fff
    style GATE fill:#2d6a2d,color:#fff
    style CORRECT fill:#8b4513,color:#fff
    style REWARD fill:#1a5276,color:#fff
```

### Trader Decision Flow

```mermaid
flowchart TD
    CANDLE[/"New 5-min candle"/] --> ENC["Encode viewport: 48 candles → pixel grid → bipolar vec"]
    ENC --> JPRED["Journaler.predict(vec)"]
    JPRED --> PHASE{"Current Phase?"}

    PHASE -->|OBSERVE| WAIT["No trade, just watch"]
    PHASE -->|TENTATIVE| SMALL["Trade min size 0.5%"]
    PHASE -->|CONFIDENT| FULL["Trade up to 2% cap"]

    SMALL --> PENDING["Pending queue: wait 36 candles"]
    FULL --> PENDING

    PENDING --> RESOLVE{"Price moved >= 0.5%?"}
    RESOLVE -->|Up| BUY_OUT["Outcome: BUY"]
    RESOLVE -->|Down| SELL_OUT["Outcome: SELL"]
    RESOLVE -->|Flat| NOISE_OUT["Outcome: NOISE"]

    BUY_OUT --> OBS["Journaler.observe"]
    SELL_OUT --> OBS
    NOISE_OUT --> OBS
    OBS --> PNL["Update P&L + check phase transitions"]
```

---

## Experiment Results

### Confirmed Techniques (in production baseline)

| # | Technique | Return | Win Rate | Key Insight |
|---|-----------|--------|----------|-------------|
| 7 | Confidence-Gated Learning | +2.50%¹ | 49.6% | Scales learning by conviction. Prevents prototype smearing from coin-flip predictions. 62x better than ungated baseline. |
| 10 | Recognition Rejection | +3.31%² | 49.7% | Skips learning when max similarity < 0.01. Filters truly novel/ambiguous data. |
| 3 | Separation Gate | +4.65%³ | 50.5% | Scales learning by prototype divergence. Suppresses corrections when buy/sell converge during trends. Noise separation improved dramatically (0.78→0.55). |

¹ vs +0.04% baseline  ² stacked on #7  ³ stacked on #7+#10

### Ruled Out Techniques

| # | Technique | Result | Root Cause |
|---|-----------|--------|------------|
| 1 | Multi-Timescale Accumulators | No improvement | Cross-timescale corrections corrupt accumulator state. Per-timescale fixes matched but didn't beat baseline. |
| 9 | Cross-Class Surgical Feedback | +0.14% (was +3.31%) | Over-feeds accumulators. Double-adding on wrong predictions smears prototypes. |
| 14 | Analogy-Based Correction | +2.23% (was +3.31%) | `analogy` degenerates when prototypes converge (difference→0). `flip` penalty dominates, creating asymmetric accumulator damage. |
| 12 | Iterative Grover Amplification | -7.4% at 50k | Grover iterations change vector *intensity* independently of weight. Conflicts with all weight-based gates (#3, #7). Tested on both correction and reward paths — same result. |
| 16 | Complexity-Gated Learning | -7.4% at 50k | Pixel encoding produces uniform complexity scores. Gate degenerates to constant scalar, smothering learning. |
| 15 | Blend-Based Gentle Correction | -5.6% at 40k | Replaces load-bearing negate/amplify correction. Nullifies separation gate — correction mechanism and gate are a coupled system. |

### Key Learnings

```mermaid
flowchart LR
    subgraph WORKS["What Works"]
        L1["GATING: deciding WHETHER to learn"]
        WIN["#7 confidence, #10 rejection, #3 separation"]
    end
    subgraph FAILS["What Fails"]
        L2["INTENSITY: more grover iterations → #12"]
        L3["MECHANISM: replacing negate/amplify → #14, #15"]
        L4["UNIFORM SCALING: same gate for all → #16"]
    end
    subgraph CRITICAL["Critical Constraint"]
        L5["Correction path is LOAD-BEARING for sep gate"]
    end

    L1 --> WIN
    style WORKS fill:#2d6a2d,color:#fff
    style FAILS fill:#8b0000,color:#fff
    style CRITICAL fill:#b8860b,color:#fff
```

### What's Left to Try

| Category | # | Technique | Risk Assessment |
|----------|---|-----------|-----------------|
| **Reinforcement** | 8 | Layered resonance filtering | ⚠️ Modifies correction path — likely breaks sep gate |
| **Reinforcement** | 13 | Soft-then-hard filtering | ⚠️ Modifies correction path — likely breaks sep gate |
| **Reinforcement** | 18 | Similarity profile correction | ⚠️ Modifies correction path — likely breaks sep gate |
| **Encoding** | 4 | Temporal binding | ✅ Safe — changes input, not learning |
| **Architecture** | 2 | Engram library (sub-patterns) | ✅ Safe — adds parallel classification |
| **Architecture** | 17 | Reject-based class isolation | ✅ Safe — adds parallel classification |
| **Architecture** | 5 | Subspace classification | ✅ Safe — adds parallel classification |

**Recommendation**: Skip remaining reinforcement techniques (#8, #13, #18) — they all modify the correction path which is coupled to the separation gate. Next moves should come from **encoding** or **architecture** categories.

---

## Reuse Notes for Ruled-Out Techniques

These techniques failed at specific insertion points (the learning/correction path in `Journaler.observe`). They may be valuable elsewhere.

### #1 Multi-Timescale Accumulators
**Failed at:** Learning — cross-timescale corrections corrupt accumulator state.
**Could work at:**
- **Prediction (read-only):** Maintain multi-timescale accumulators but only READ from fast/slow for prediction signals. Learn at single timescale only. Fast/slow disagreement = regime transition signal.
- **Phase transitions:** Fast accumulator diverging from slow = market regime is changing. Could trigger CONFIDENT → TENTATIVE demotion earlier.

### #9 Cross-Class Surgical Feedback
**Failed at:** Learning — double-feeding on wrong predictions smears prototypes.
**Could work at:**
- **Prediction scoring:** Use the "what fooled us" signal as a read-only penalty during prediction, not as accumulator input. Already partially implemented via confuser accumulators.
- **Diagnostics:** Track how much of a wrong prediction was due to genuine confuser overlap vs noise.

### #14 Analogy-Based Correction
**Failed at:** Learning — `analogy(wrong, correct, vec)` degenerates when prototypes converge because `difference(correct, wrong) → 0`.
**Could work at:**
- **Well-separated regimes only:** Gate analogy by separation — only apply when `sep_gate > 0.5`. When prototypes are distinct, analogy is a principled rotation from wrong-space to correct-space.
- **Encoding / transfer:** Analogy is designed for relational transfer (A:B::C:?). Could be useful for encoding temporal relationships or transferring patterns across timeframes.

### #12 Iterative Grover Amplification
**Failed at:** Learning — changes vector intensity independently of weight-based gates, breaking the coupled equilibrium.
**Could work at:**
- **Encoding pipeline:** Sharpen viewport vectors BEFORE they enter the learning system. `grover_amplify(encoded_vec, null_template, 2)` to boost signal-to-noise in the raw encoding.
- **Prediction:** Amplify discriminative prototypes before similarity comparison: `grover_amplify(buy_disc, sell_disc, 2)` to make the classifier more decisive.
- **Recalibration:** Multiple grover iterations when building `buy_disc`/`sell_disc` during recalibration (offline step, not in the feedback loop).

### #16 Complexity-Gated Learning
**Failed at:** Learning — pixel encoding produces uniform complexity scores, so the gate is a constant.
**Could work at:**
- **Non-uniform encodings:** If we add temporal binding (#4), bound sequences would have genuinely varying complexity. A sequence of similar candles = low complexity. A volatile sequence = high complexity.
- **Monitoring/diagnostics:** Track complexity of prototypes over time. Rising prototype complexity could signal accumulator pollution.
- **Engram library (#2):** When deciding whether to create a new engram vs merge with an existing one, complexity of the residual could indicate "genuinely new pattern" vs "noisy variant."

### #15 Blend-Based Gentle Correction
**Failed at:** Learning — breaks the separation invariant that negate/amplify maintains. Feeds partial copies of prototypes back into accumulators.
**Could work at:**
- **Prototype seeding (warmup):** During OBSERVE phase before the separation gate is active, blend could bootstrap initial prototypes more gently than raw accumulation.
- **Prediction (soft classification):** `blend(buy_disc, sell_disc, confidence)` could produce a "consensus prototype" for ambiguous market states.
- **Engram merging:** When two engrams are close, `blend(engram_a, engram_b, 0.5)` is a natural merge operation.

---

## Next Experiments (prioritized)

### Tier 1 — Trivial, safe (read-only or offline)

| ID | Experiment | Where | Rationale |
|----|-----------|-------|-----------|
| 12R | Grover-amplify disc protos at recalibration | Recalibrate (offline, every 500 updates) | Sharper discriminative protos. Not in feedback loop. |
| 12P | Grover-amplify disc protos at prediction | Predict (read-only) | More decisive classifier. Doesn't touch learning. |
| 1R | Fast/slow accumulator disagreement for phase demotion | Phase transition logic | Read-only from extra accumulators. Earlier regime detection. |

### Tier 2 — Moderate, safe (changes input or preprocessing)

| ID | Experiment | Where | Rationale |
|----|-----------|-------|-----------|
| 4 | Temporal binding (bind consecutive viewports) | Encoding pipeline | New signal: transitions, not just snapshots. |
| 12E | Grover-sharpen viewport vectors before learning | Encoding pipeline | Boost signal-to-noise before accumulation. |

### Tier 3 — Architecture (parallel systems)

| ID | Experiment | Where | Rationale |
|----|-----------|-------|-----------|
| 2 | Engram library (sub-pattern clustering) | Parallel classification | Capture distinct buy/sell sub-patterns. |
| 5 | Subspace classification (OnlineSubspace) | Parallel classification | Second opinion via subspace projection. |

### Tier 4 — Risky but principled

| ID | Experiment | Where | Rationale |
|----|-----------|-------|-----------|
| 14G | Analogy correction, only when separation > 0.5 | Correction path (conditional) | Analogy works when protos are distinct. Still touches feedback loop. |

---

## Run History

| Date | Config | 100k Return | Win Rate | Notes |
|------|--------|-------------|----------|-------|
| 2026-03-20 | Baseline (no gates) | +0.04% | 50.0% | Initial self-supervised trader |
| 2026-03-21 | +#7 | +2.50% | 49.6% | Confidence gating confirmed |
| 2026-03-21 | +#7+#10 | +3.31% | 49.7% | Recognition rejection confirmed |
| 2026-03-21 | +#7+#10+#9 | +0.14% | — | Cross-class ruled out |
| 2026-03-21 | +#7+#10+#14 | +2.23% | 49.5% | Analogy ruled out |
| 2026-03-21 | +#7+#10+#3 | **+4.65%** | **50.5%** | **Current best** |
| 2026-03-21 | +#7+#10+#3+#12 (correction) | — | — | Killed at 50k (-7.4%) |
| 2026-03-21 | +#7+#10+#3+#12 (reward) | — | — | Killed at 50k (-7.4%) |
| 2026-03-21 | +#7+#10+#3+#16 | — | — | Killed at 60k (-5.3%) |
| 2026-03-21 | +#7+#10+#3+#15 | — | — | Killed at 40k (-5.6%) |
