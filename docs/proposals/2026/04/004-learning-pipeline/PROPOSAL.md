# Proposal 004: Outcome-Based Learning

## The problem

The accumulation model works. The architecture is tolerant. The plumbing is correct. The thoughts are wrong because the labels are wrong.

### The numbers

```
100k run (accumulation-100k, commit 3004284):
  Rolling accuracy:    41.9%
  Disc strength:       0.005 - 0.008
  Proto cosine:        0.85 - 0.93 (prototypes nearly identical)
  Recovery rate:       98 / 2,237 = 4.4%
  Stop-losses:         2,138 / 2,237 = 95.6%
```

### The wrong target

The journal currently learns to predict **price direction**. "Did price go up? Buy. Down? Sell." The label comes from a threshold crossing — price moved ±ATR.

The enterprise doesn't care about price direction. The enterprise cares about **whether the trade produces residue or consumes capital**. A 3% up-move that reverses before take-profit is a Loss. A slow grind to TP is a Win. The current system labels both "Buy" and teaches the journal to predict more of both.

## The proposal

### 1. Outcome-based labels

Replace threshold-crossing labels with position-lifecycle labels.

**Current**: first threshold crossing → Buy / Sell / Noise
**Proposed**: simulated position outcome → Win / Loss / Noise

For every thought, simulate what would have happened if we had entered:
- Simulate entry at current rate with current ATR
- Tick the position forward through subsequent candles
- Take-profit triggers → **Win** (principal recovered, residue produced)
- Stop triggers gently (actual exit within tolerance of stop level) → **Noise** (market didn't commit)
- Stop triggers violently (actual exit significantly past stop level) → **Loss** (market punished this thought)
- Neither within horizon → **Noise** (market didn't commit)

The three labels map to three market regimes:
- **Win**: the market rewarded this thought state. Residue produced.
- **Loss**: the market *punished* this thought state. Not just a stop-out — a violent rejection. The actual exit gaped past the stop level.
- **Noise**: the market didn't commit. Either the trade closed gently near the stop (within tolerance), expired at the horizon without resolution, or produced no decisive outcome either way.

The boundary between Noise and Loss is **violence**:
```
actual_loss = (entry_rate - exit_rate) / entry_rate
stop_distance = k_stop * entry_atr
violence = actual_loss / stop_distance

if violence > tolerance_factor:  → Loss (violent rejection)
else:                            → Noise (gentle, indecisive)
```

`tolerance_factor` is a tunable parameter — how much slippage past the stop constitutes "violence." A starting point: `tolerance_factor = 1.5` — the actual loss must exceed 150% of the stop distance to be labeled Loss. Everything gentler is Noise.

Both directions are simulated independently. A thought can be a Win on the Buy side and a Loss on the Sell side. Each observer learns from the direction it predicted.

### 2. Magnitude-weighted learning

The journal doesn't just learn Win/Loss — it learns **how much**.

The mechanism already exists: `signal_weight` in `journal.observe()` scales how hard each observation pulls the prototype.

- **Win**: `signal_weight = grace` — how generously the market gave beyond TP. `grace = (peak_rate - tp_rate) / tp_rate`. A trade that hit TP and the market kept giving teaches harder than one that barely tapped TP and reversed. Grace is effortless — the market gave freely, beyond what was asked. Naturally bounded: 0.0 (tapped TP exactly) to ~0.1-0.3 (strong continuation past TP).
- **Loss**: `signal_weight = violence` — the ratio of actual loss to stop distance. A stop at -3% with exit at -5% has violence = 1.67. A stop at -3% with exit at -8% has violence = 2.67. The more violently the market rejected the thought, the harder the Loss prototype learns. The weight IS the punishment. Naturally bounded by worst-case gap: typically 1.5-3.0.

The Win prototype becomes the weighted centroid of all winning thought states, pulled harder by bigger residues. The Loss prototype becomes the weighted centroid of all violently rejected thought states, pulled harder by more violent rejections. Noise — the gentle majority — teaches the noise subspace what indecision looks like, stripping it from future thoughts before the journal sees them.

Three regions on the unit sphere. Win: where the market rewards. Loss: where the market punishes. Noise: where the market doesn't care. The discriminant — the direction between Win and Loss — encodes "what predicts profitable trades under the accumulation model," with the noise already subtracted.

### 3. The geometry

Every thought vector lives on the surface of a 10,000-dimensional unit sphere. The journal's prototypes are centroids on this sphere — the average location of Win thoughts and Loss thoughts. The discriminant points from Loss toward Win. Prediction = which hemisphere does your thought fall in?

There is no gradient. No loss function. No backpropagation. Points on a sphere, distances between them, centroids that accumulate. The magnitude weighting means bigger outcomes pull the centroid harder — the prototype naturally gravitates toward the region of thought-space where the best trades live.

The hologram: every dimension of the vector encodes information about the whole thought. RSI, volume, regime, momentum — all superposed into one point on the sphere. The codebook — the vocabulary atoms — are labeled points on the same sphere. Every fact has a known vector: `rsi-overbought`, `bb-squeeze`, `obv-rising`. You CAN read what's in a thought by measuring cosine against each atom. The vocabulary modules are the identity functions — they define what a thought IS, and the codebook decodes what a thought CONTAINS. The prediction is: how close is this input to the Win centroid vs the Loss centroid? The decode is: which labeled atoms are present in the thought that drove the prediction?

Hawking and Bekenstein showed that the information content of a black hole isn't inside — it's on the surface. The holographic principle: a volume of space can be described by information encoded on its boundary. Our thoughts live on the boundary. The surface of the unit sphere. Every fact distributed across every dimension, readable with the codebook. The information isn't inside the vector — it's on the sphere. Hawking's hologram, in 10,000 dimensions, measured by a cosine.

*Holy shit.* — the machine, when the builder pointed out that two holograms operating in tandem are entangled fuzzy objects on the same sphere.

But Hawking would ask: what about TWO holograms? The observer's thought and the noise subspace's model are two fuzzy objects on the same sphere. They're coupled — what the noise subspace learns changes what the journal sees. `strip_noise` subtracts one hologram from the other. The journal's input is a joint state: thought MINUS noise model. You can't describe what the journal sees without knowing what the noise subspace has learned. They're entangled.

Six observers encode the same candle through different lenses. Six holograms sharing the same underlying reality, expressing it differently. The manager reads all six and produces a seventh — a superposition of superpositions. Measuring one observer's prediction tells you something about the others. They're entangled through the candle.

The position on the sphere isn't known precisely. The thought is NEAR many atoms simultaneously. Cosine against each atom is continuous — not "is RSI overbought" but "how much RSI-overbought is present." Fuzzy objects. Coupled. Entangled through the learning loop. The thought is a quantum of cognition on a holographic surface, and the two templates — prediction and reaction — are entangled observers of the same underlying state.

Hawking mapped the hologram on the boundary of a black hole. We mapped it on the boundary of a unit sphere. The information is on the surface. The coupling is real. The entanglement is the architecture.

## What changes

### Labels
- Buy/Sell → Win/Loss
- Source: position lifecycle simulation, not price threshold crossing
- The journal predicts "will this thought produce residue?" not "which direction will price move?"

### Signal weight
- Currently: `move_size / running_average_move` (scalar, disconnected from outcome)
- Proposed: `residue_fraction` for Win, `loss_fraction` for Loss (directly measures what we care about)

### Noise definition
- Currently: 0.3% noise rate (almost everything crosses the threshold — useless)
- Proposed: Noise = gentle stop-out (within tolerance) OR horizon expiry without resolution. The market didn't commit — either it drifted gently against us or it went sideways. Noise now includes the MAJORITY of stop-outs (gentle taps), making the noise subspace's curriculum genuinely informative: "these are the thought states where the market doesn't care."

### k_tp becomes a learning parameter
- Currently: k_tp = 6.0 ATR is just a trading parameter
- Under outcome labels: k_tp defines what "Win" means. It's the definition of success. The journal learns "what thoughts precede moves large enough to reach THIS TP level." k_tp too high → everything is Loss. k_tp too low → everything is Win. The TP level IS the curriculum.

## What stays the same

- Observer architecture (six observers, each with own vocabulary lens)
- Noise subspace (strip boring patterns before journal)
- Journal mechanics (accumulate, prototype, discriminant, cosine)
- Manager encoding (observer opinions → panel thought)
- Position lifecycle (stop, TP, runner, principal recovery)
- Risk gating, Kelly sizing, conviction threshold
- The six primitives, the unit sphere, the fold

## Open questions for designers

1. **Simulation fidelity**: The simulated position uses the same k_stop, k_trail, k_tp as real positions. Should it also simulate fees? Or is fee-free simulation cleaner for label generation?

2. **Both directions per thought**: Every thought gets two simulations — Buy-side and Sell-side. The observer learns from the direction it predicted. But should the journal also see the OTHER direction's outcome? "This thought was a Win on Buy but a Loss on Sell" is information.

3. **Horizon for simulation**: Real positions have no horizon — they run until stop or TP. But simulation needs a bound (can't look ahead infinitely). Is the current `horizon × 10` right? Should it be `k_tp / ATR` candles (the expected time to reach TP at current volatility)?

4. **Noise subspace interaction**: Noise-labeled thoughts teach the noise subspace. Under the new definition, Noise = "market didn't commit within horizon." Is this the right thing to teach the subspace? Or should the subspace learn from a different signal?

5. **Transition**: The current journal has Buy/Sell prototypes. The new journal has Win/Loss prototypes. Can we rename in place, or does the semantic change require a fresh journal?

## The baseline

```
accumulation-100k (commit 3004284):
  100,000 candles | Jan 2019 - Dec 2020
  Equity: $14,682 (+46.8%)
  Win rate: 50.8%
  Rolling accuracy: 41.9%
  Recovery rate: 4.4%
  Disc strength: 0.005-0.008
```

## The process

1. ~~Problem statement~~ — done
2. ~~Proposal~~ — this document
3. **Designer review** — Hickey and Beckman critique
4. Resolution — accept, reject, or modify
5. Wat spec — update observer.wat, desk.wat
6. Implementation — Rust follows wat
7. Measurement — 100k run, compare to baseline

---

*Status: proposal complete. Ready for designer review.*
