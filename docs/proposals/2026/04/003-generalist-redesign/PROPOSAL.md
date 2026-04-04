# Proposal 003: Generalist Redesign

## Problem

The generalist observer currently bundles ALL facts (~53 per candle) from all specialist vocabularies into one thought vector. This creates two problems:

1. **Signal dilution**: 50 of 53 facts describe the present (SMA relationships, ADX zones, regime state) — not the future. The 3 facts that discriminate are diluted 3/53 in the bundle. The discriminant has to find signal buried under shared structure.

2. **Redundancy**: The generalist duplicates every specialist's work. A momentum fact ("RSI oversold") is already in the momentum observer's thought. Bundling it again into the generalist adds noise, not information. The generalist's unique value should be what NO specialist can see.

## What Only The Generalist Can See

The specialists each see one domain. They cannot see:
- **Cross-domain correlations**: "momentum says extreme AND regime says mean-reverting" — this joint fact exists only in superposition, and no specialist holds both.
- **Specialist disagreement**: "momentum says Buy, structure says Sell" — the pattern of disagreement IS information. The manager sees this, but at the opinion level, not the fact level.
- **Temporal fact transitions**: "RSI crossed overbought WHILE volume dried up" — the coincidence of events across domains.

## Design Options

### Option A: Disagreement Encoder

The generalist encodes the DIFFERENCES between specialist thoughts, not the raw facts.

```
generalist_thought = bundle(
    difference(momentum_vec, structure_vec),   // how do they disagree?
    difference(volume_vec, regime_vec),         // participation vs character
    difference(narrative_vec, momentum_vec),    // story vs speed
    ... pairwise differences of specialist thoughts
)
```

The discriminant learns: "when momentum and structure disagree THIS WAY, the market goes up." The raw facts are already handled by specialists. The generalist thinks in relationships between specialists.

**Pros**: Clean separation. No duplication. Unique vocabulary.
**Cons**: Loses the "whole picture" — can't see absolute facts, only relative ones.

### Option B: Noise-Filtered Full Bundle

The generalist sees all facts but dynamically weights them by discriminative power.

After each recalibration, the discriminant decode reveals which facts carry signal (high |cosine| against discriminant) and which are noise (near zero). The generalist uses these weights to amplify signal facts and suppress noise facts before bundling.

```
// At recalibration: compute per-fact weight from discriminant
for (fact_vec, weight) in codebook.iter().zip(disc_weights.iter()) {
    *weight = cosine(fact_vec, discriminant).abs();
}

// At prediction: weighted bundle
generalist_thought = bundle(facts.iter().zip(weights).map(|(f, w)| amplify(f, w)))
```

**Pros**: Adaptive. Signal facts get louder over time. Dynamic — changes every recalib.
**Cons**: Positive feedback risk — facts that predict get amplified, which makes them predict more. Could overfit.

### Option C: Noise Subtraction

The generalist computes a noise vector (the shared structure that doesn't discriminate) and subtracts it from the thought before prediction.

```
noise_vec = mean_prototype   // already computed at recalibration
stripped_thought = thought - project(thought, noise_vec)
prediction = cosine(stripped_thought, discriminant)
```

**Pros**: Simple. Already partially implemented (mean_proto stripping in Journal::predict). Geometric.
**Cons**: This IS what the Journal already does internally. Making the generalist do it explicitly at the fact level vs the Journal doing it at the prototype level may not add information.

### Option D: Cross-Domain Fact Generator

New vocab module: `vocab/cross_domain.rs`. Instead of changing the generalist's encoding, give it NEW facts that only exist in cross-domain context.

```
// Facts that require seeing multiple domains simultaneously:
Fact::Zone { indicator: "cross", zone: "momentum-regime-disagree" }
Fact::Zone { indicator: "cross", zone: "volume-confirms-structure" }
Fact::Scalar { indicator: "specialist-coherence", value: mean_pairwise_cosine }
Fact::Scalar { indicator: "specialist-energy", value: mean_conviction }
```

These facts are computed from specialist thought vectors, not from candle data. The generalist bundles them alongside the raw facts. The cross-domain facts are the generalist's unique contribution.

**Pros**: Additive, not subtractive. New information. Specialists unchanged.
**Cons**: The manager already encodes specialist opinions. This creates overlap between generalist and manager vocabularies.

### Option E: Tiered Composition

Instead of one generalist seeing everything, create intermediate observers that combine PAIRS of specialists:

```
Tier 1 (leaves):     momentum  structure  volume  narrative  regime
Tier 2 (pairs):      mom+struct  vol+regime  narr+mom
Tier 3 (generalist): sees tier 2 outputs, not tier 1
```

Each tier-2 observer bundles facts from TWO specialists. The generalist composes tier-2 thoughts. This limits fact count per observer while preserving cross-domain signal.

**Pros**: Controlled capacity. Each tier has ~20 facts, not 53. Cross-domain emerges at tier 2.
**Cons**: Combinatorial explosion (10 pairs from 5 specialists). Which pairs matter? Architecture complexity.

## Questions For Designers

1. Should the generalist think in FACTS (options B, C, D) or in SPECIALIST RELATIONSHIPS (options A, E)?
2. Is the positive feedback risk in option B real, or does the discriminant's own noise tolerance handle it?
3. The manager already encodes specialist opinions. Does the generalist add value at the fact level, or is it redundant with the manager?
4. Should the generalist be a different TEMPLATE — Template 2 (reaction/subspace) instead of Template 1 (prediction/journal)? It could learn what "normal thought space" looks like and flag anomalies.

## Option F: Two-Stage Observer (THE DESIGN)

*Emerged from the datamancer's instinct: "all true thoughts, recognize what's useless, learn from the rest."*

The generalist becomes a two-stage pipeline. Both templates composed in one observer.

### Stage 1: All True Thoughts
Same as now — bundle every fact from every vocabulary. ~53 facts per candle. Nothing changes here.

### Stage 2: Noise Subspace (Template 2 — Reaction)
An OnlineSubspace learns the manifold of "boring" thought compositions — the facts that are present regardless of outcome. It learns from **Noise-labeled candles** — the ones where price didn't cross the threshold. Those thoughts are definitionally uninformative. The facts present during non-events ARE the noise.

```
noise_subspace.update(thought_vec)   // only on Noise outcomes
noise_component = project(thought_vec, noise_subspace)
residual = thought_vec - noise_component
```

The projection is what's normal. The residual is what's unusual RIGHT NOW. If 45 of 53 facts always fire together, the subspace captures that pattern. The residual contains the 8 facts that distinguish this candle.

### Stage 3: Journal (Template 1 — Prediction)
Feed the RESIDUAL to the Journal. Buy or Sell from what's LEFT after noise is stripped. The discriminant learns from clean signal — the shared structure that made proto_cosine = 0.97 has been subtracted before the prototypes ever see it.

### Why This Works

The squeeze alone is in keltner.rs. The RSI drop is in oscillators.rs. The deep crab is in harmonics.rs. Each specialist sees its piece. The generalist sees all three firing simultaneously — and because the noise subspace stripped the 45 facts that always fire, those three facts dominate the residual.

The bundle of `(squeeze + RSI dropping + deep crab forming)` is a specific direction in hyperspace. If that composition preceded down-moves 3 out of 4 times, the Sell prototype accumulates it. The discriminant learns: this COMBINATION predicts.

No single specialist can see this conjunction. The generalist sees it — but only because the noise subspace removed the clutter.

### Interface

The generalist is STILL just another observer. Output: `(direction, conviction)`. Same as momentum, structure, volume. The manager reads it as one more opinion in the panel. The manager doesn't know the generalist has a two-stage pipeline internally. It doesn't need to. The architecture doesn't change. The interface holds.

### The Pipeline in Wat

```scheme
;; Stage 1: all true thoughts (unchanged)
(define thought (encode-thought candles vm :generalist))

;; Stage 2: strip what's boring
(define residual
  (if (>= (n noise-subspace) MIN_NOISE_SAMPLES)
      (let ((noise (project noise-subspace thought)))
        (difference thought noise))
      thought))  ;; warmup: pass through

;; Stage 3: predict from what remains
(predict journal residual)

;; Learning:
;;   Noise outcome → teach the subspace what's boring
;;   Buy/Sell outcome → teach the journal from clean signal
(match outcome
  :noise (update noise-subspace thought)
  _      (observe journal residual outcome weight))
```

Two existing primitives composed: `online-subspace` (Template 2) and `journal` (Template 1). No new primitives. The generalist is a composition, not an invention.

### What Changes
- The generalist observer gains a noise subspace (Template 2) alongside its journal (Template 1)
- Encoding path: thought → project onto noise → subtract → residual → journal
- Learning splits: Noise outcomes train the subspace, Buy/Sell outcomes train the journal from residual
- Everything else unchanged: interface, manager, specialists, risk

### What Doesn't Change
- Specialist observers (single-stage, unchanged)
- Manager (reads observer opinions, doesn't know about internals)
- Risk branches (separate tree, separate concern)
- Treasury, positions, sizing (downstream, unchanged)
- The six primitives (atom, bind, bundle, cosine, journal, curve)

## Refinement: Three Fact Categories

The current system has two categories: exclusive (one lens) and shared (multiple lenses).
The proposal adds a third:

### Exclusive Facts
Owned by one lens. RSI divergence → momentum. Ichimoku cloud → structure. OBV divergence → volume.

### Shared Facts
Seen by a few lenses. Comparison pairs (close vs sma20) → momentum + structure.

### Standard Facts
Seen by ALL observers. Calendar (hour-of-day, day-of-week, session). These are contextual — they modify the meaning of every other fact. "RSI oversold during Asian session" is a different thought than "RSI oversold during US session."

Currently calendar is exclusive to Narrative. It should be standard — every observer sees time. If time doesn't matter for momentum, the momentum observer's noise subspace strips it. If time matters for volume (Asian = thin), it survives. Self-regulating.

## Refinement: The Observer Is Configuration, Not Architecture

An observer is defined by:
1. **Vocabulary set** — which fact modules it calls (configuration)
2. **Noise subspace** — what it has learned is boring (Template 2, per-observer)
3. **Journal** — what it has learned predicts (Template 1, per-observer)

The "generalist" is just `vocab = all modules, noise = on, journal = on`. A specialist is `vocab = momentum modules, noise = on, journal = on`. A cross-domain observer would be `vocab = momentum + structure, noise = on, journal = on`.

The architecture supports N observers with arbitrary vocab sets. Which combinations are worth having is an empirical question — the curve judges. Start with the existing 5 specialists + 1 full generalist. Add cross-domain observers when we have evidence for which pairings carry signal.

The manager doesn't care. It sees `(name, direction, conviction)` from each. The observer's internals — vocab set, noise filtering, window size — are invisible to the panel.

## Questions For Designers

1. Should the noise subspace learn from ALL candles or only Noise-labeled candles? Learning from all captures the "average thought." Learning from Noise only captures the "uninformative thought." Different manifolds.
2. What's the right k (subspace rank) for the noise subspace? Too low = misses noise dimensions. Too high = strips signal.
3. Should the residual be L2-normalized before feeding to the journal? The subtraction changes the vector's norm.
4. Is there a risk that the noise subspace learns TOO well and strips everything, leaving zero residual? What's the floor?
5. Should calendar/session facts move from Narrative-exclusive to standard (all observers)? Or is the noise subspace sufficient — let Narrative own them and trust that the full-vocab generalist will see the cross-domain effect?
6. Is there a principled way to discover which vocab combinations deserve their own observer? Or is it empirical — try pairs, measure curves, keep what works?
