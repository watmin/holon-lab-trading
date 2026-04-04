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

## The Datamancer's Instinct

The generalist should filter noise dynamically. Not static partitioning (that's what specialists do). Not equal bundling (that's what we have). Dynamic weighting based on what the discriminant has learned. The noise vec changes every recalibration. Facts that predicted last month but don't predict this month fade. Facts that emerged this month get amplified.

This is attention. The discriminant IS the attention mechanism. Using it to weight the input (not just evaluate the output) closes the loop.
