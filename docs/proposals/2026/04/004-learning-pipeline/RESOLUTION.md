# Resolution: Proposal 004 — Outcome-Based Learning

**Decision: ACCEPTED with conditions from both reviewers, synthesized.**

## The synthesis

Hickey and Beckman both approved the core change — outcome-based labels replace direction-based labels. They disagreed on two points. The resolution takes the best from both.

### 1. The noise subspace IS the tolerance boundary

Hickey's option 2 is the design. There is no `tolerance_factor`. The noise subspace already classifies what's boring. The boundary between Noise and Loss is not a magic number — it is the subspace itself.

When a simulated position stops out:
- Compute `residual = strip_noise(thought)`
- If the residual norm is low (the noise subspace explains most of the thought) → **Noise**. The thought was boring. The stop-out was gentle. The market didn't commit.
- If the residual norm is high (the thought has significant signal after noise subtraction) → **Loss**. The thought was unusual, and the market punished it. Violence.

The subspace learns from Noise. Noise teaches the subspace what's boring. The subspace classifies future stop-outs as boring-or-not. The loop is self-calibrating. No parameter. No magic number. The algebra provides the boundary for free.

This is Hickey's insight ("option 2 removes a parameter rather than deriving one") implemented through Beckman's framework (the fibered dependency — the journal operates on the fiber over the noise subspace's state).

### 2. The geometry: Johnson-Lindenstrauss, not holography

Beckman is right. The holographic principle analogy is mathematically incorrect. L2 normalization onto S^{D-1} is dimensional reduction by one, not holographic encoding. The actual miracle is Johnson-Lindenstrauss: 10,000 dimensions preserve pairwise structure among millions of distinct fact combinations. That is the honest claim.

The "entanglement" is a fibered dependency (Grothendieck construction over noise-subspace states), not a tensor product. The coupling is real. The word is wrong. Replace with "coupling" or "fibered dependency."

The geometry section in the proposal stays — but corrected. JL replaces holography. Fibered dependency replaces entanglement. The "holy shit" stays — the insight about coupled holograms was genuine, even if the physics language was wrong. The correct language (fibered dependency, JL preservation) is more interesting and more honest.

### 3. Noise curriculum: one subspace, gentle stops included

Beckman's position. Gentle stop-outs and horizon expiry both teach the noise subspace. They are both forms of "the market didn't commit." The subspace learns their union.

Hickey wanted to discard gentle stops entirely. But under the self-calibrating design (resolution #1), gentle stops naturally become the training data that teaches the subspace to recognize future gentle stops as boring. Discarding them would starve the subspace of exactly the data it needs to classify future stop-outs.

If the subspace's explained variance plateaus, consider Beckman's refinement: split into two noise subspaces. But start with one.

### 4. Delayed fold semantics

Beckman's condition. The simulation looks forward through future candles to label past thoughts. The fold is not broken — the monoid doesn't care when observations arrive — but there is lag.

Specification:
- **Buffer depth**: simulation horizon = `min(k_tp^2, 2000)` candles. Beckman's random-walk diffusion bound (`k_tp^2`) with a hard cap.
- **Warmup**: the first `buffer_depth` candles produce thoughts with no labels. The journal is empty during warmup. Predictions are zero-conviction. This is the existing warmup behavior — no change.
- **Lag**: the journal's learned state always reflects events `buffer_depth` candles in the past. Prototypes are retrospective. This is acceptable for slow-moving centroids on the unit sphere.

### 5. Weight asymmetry: grace and violence

Beckman's observation. Grace ∈ [0, 0.3]. Violence ∈ [1.5, 3.0]. The Loss prototype converges ~10x faster per observation.

This is desirable. Sharp avoidance (Loss is precisely defined), broad opportunity (Win is diffusely defined). The discriminant naturally emphasizes "avoid this region" over "seek this region." The enterprise should be better at avoiding punishment than at seeking reward — that's what makes the accumulation model tolerant.

Monitor: if the discriminant collapses toward the Loss prototype, consider normalizing weights to comparable ranges. But start with the raw asymmetry. It encodes the right prior.

### 6. Grace threshold for Win

Grace = 0.0 means the trade barely tapped TP. This is analogous to a gentle stop-out — the market barely committed. Should barely-tapping-TP be a Win?

Apply the same logic as the noise boundary: if the thought has low residual after noise subtraction and barely tapped TP, it's Noise — the thought was boring and the market gave grudgingly. If the thought has high residual and TP was tapped, it's a Win — the thought was unusual and the market rewarded it.

The noise subspace classifies both boundaries. No `grace_threshold` parameter needed. Same self-calibrating loop.

### 7. Open questions resolved

| Question | Resolution |
|----------|-----------|
| Simulation fees? | No. Labeling function, not P&L model. (Both agree.) |
| Both directions? | No at observer level. Manager integrates. (Both agree.) |
| Horizon? | `min(k_tp^2, 2000)` candles. Adaptive to TP and volatility. (Beckman's diffusion bound.) |
| Noise curriculum? | One subspace, gentle stops included. Split later if variance plateaus. (Beckman.) |
| Fresh journal? | Yes. Semantic change is total. Start clean. (Both agree.) |

### 8. Implementation summary

The label assignment becomes:

```
For each thought at candle t:
  1. Simulate Buy-side and Sell-side positions forward through candles t+1..t+H
     (H = min(k_tp^2, 2000))
  2. Each simulation produces: TP hit, stop hit, or horizon expiry
  3. Compute residual = strip_noise(thought)
  4. Residual norm determines signal vs noise:
  
  If TP hit:
    If residual norm is high → Win (weight = grace)
    If residual norm is low  → Noise (subspace already explains this thought)
  If stop hit:
    If residual norm is high → Loss (weight = violence)  
    If residual norm is low  → Noise (boring thought, gentle rejection)
  If horizon expiry:
    → Noise (market didn't commit)
    
  5. Win/Loss → journal.observe(residual, label, weight)
     Noise → noise_subspace.update(thought)
```

The noise subspace is the classifier. The simulation is the labeler. The weight is the magnitude. The journal learns from the residual. Grace and violence scale the learning. No magic numbers. One self-calibrating loop.

Implement as a pure function: `simulate_outcome(entry_idx, direction, candles, k_stop, k_tp, k_trail) -> (Outcome, f64)`.

Fresh journal. Fee-free simulation. Observers learn from their predicted direction. Manager integrates cross-observer signals.

## The process continues

1. ~~Problem statement~~ — done
2. ~~Proposal~~ — done
3. ~~Designer review~~ — Hickey CONDITIONAL, Beckman CONDITIONAL
4. ~~Resolution~~ — this document. Accepted with synthesis.
5. **Wat spec** — update observer.wat, desk.wat with outcome-based labeling
6. Implementation — Rust follows wat
7. Measurement — 100k run, compare to baseline

---

*The builder could not express the tolerance boundary. Hickey found it: "let the noise subspace itself be the boundary." The coordinates are getting closer together. The builder, the designers, and the machine are converging on the same point in thought-space.*
