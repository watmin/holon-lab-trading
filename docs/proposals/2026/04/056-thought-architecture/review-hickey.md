# Review: Hickey

Verdict: CONDITIONAL

---

## What hangs straight

The central insight is good: move order from the container to the content. A bundle is a set. Sets don't order. But if each element carries its relation to its predecessor as a scalar delta, the ordering information is *in the value*, not complected with the container's structure. This is the right move. You stopped trying to make the container do two things (hold items AND remember their sequence) and let each item be self-describing. That's simplicity.

The one-function-for-all-rhythms design (`indicator-rhythm`) is genuinely simple. One generic function. The atom name is a parameter. The extractor is a parameter. The dims determine the budget. Three callers, same algorithm. No polymorphism, no trait objects, no strategy pattern. A function. Good.

The three-layer encoding (fact -> trigram -> bigram-pair -> rhythm bundle) composes cleanly. Each layer does one thing. Bind rotates without consuming capacity. Bundle consumes capacity but is recoverable by cosine. The layers don't reach into each other. The trigram doesn't know it will be paired. The pair doesn't know it will be bundled. Each is a value.

The noise subspace stripping at each level is the right separation. Each thinker asks its own question, learns its own normal, strips its own background. The market observer doesn't know about the regime observer. The regime observer doesn't know about the broker. Information flows up through values — the chain carries what the next thinker needs. No callbacks, no shared mutable state, no observer pattern.

The thermometer encoding is honest about a real failure. Rotation-based scalar encoding destroys small differences. The proposal names the failure (`+0.07` and `-0.07` encode identically at `scale=1.0`), explains why (bipolar thresholding), and proposes a replacement with an exact cosine formula. The bounds come from the indicator's mathematical definition, not from tuning. That's the difference between a parameter and a magic number.

## What's complected

**The delta scheme carries a hidden assumption about stationarity.** The `same-move-delta` compares "me vs the last phase of my type." But phases are not evenly spaced. Valley 1 might be 200 candles ago. Valley 2 might be 30 candles ago. The delta treats them as "the same kind of thing" regardless of temporal distance. This is a choice, and it might be the right one, but the proposal doesn't acknowledge it. The delta is a value comparison pretending to be a temporal comparison. When the market regime changed between two same-type phases, the delta conflates "the phase was different" with "the market was different." These are two separate concerns braided into one scalar.

**The regime observer is called "middleware" but it has a subspace.** Middleware transforms and passes through. A thing with a learned subspace that strips its own background is not middleware — it's an observer that doesn't predict. The naming is imprecise, and imprecise names create imprecise thinking. If it learns what's normal, it's an observer of normalcy. Call it that or acknowledge the tension.

**The market rhythms pass through the regime observer into the broker as pre-computed vectors.** This means the regime observer's anomaly filtering selects *which* market rhythms pass through, but the broker receives them as opaque vectors it cannot decompose. The broker bundles market rhythms it didn't create and cannot inspect. This is fine as long as the subspace at the broker level handles the redundancy, but it means the broker's thought is partially a composition of things it received as black boxes. The proposal doesn't discuss what happens when the regime observer's anomaly filter is wrong — when it strips a market rhythm that the broker actually needed. There's no mechanism for the broker to say "I wanted that." The information only flows one direction. For a system that learns, that might be a problem. For a system that only predicts, it's probably fine. Which is this?

**The `prior-bundle delta` and `prior-same-phase delta` are two different notions of "previous" living on the same record.** One is sequential (the phase right before me). The other is type-matched (the last phase of my kind). These are different questions. Having both on the same record means the trigram binds them together — the "compared to my predecessor" fact and the "compared to my last same-type" fact are complected into one vector by the bundle within each phase record. The reckoner cannot attend to one without the other. The proposal argues this is fine because "the reckoner discovers what matters" but the reckoner discovers what matters *within the geometry it's given*. If two concerns are bound into the same direction, the reckoner cannot separate them.

Consider: make the prior-bundle deltas part of the phase record, and make the same-phase deltas a separate, parallel rhythm — the "structural momentum" rhythm. Two rhythms, two directions, two things the reckoner can attend to independently. The broker already bundles multiple rhythms. One more doesn't change the architecture. It does change the geometry — it hangs straight instead of being braided.

## The proof

The proof proves that the noise subspace separates regimes. That's a necessary condition for the architecture to work. It's not a sufficient condition. The proof uses synthetic data (monotone uptrends, monotone downtrends, stationary chop). Real market data is none of these things. A real uptrend has pullbacks, pauses, and regime micro-shifts within it. The synthetic data generator (`noisy_uptrend`) adds noise but not structure — no mean reversion, no momentum clustering, no volume spikes. The proof demonstrates the mechanism works in the favorable case. It doesn't demonstrate it works in the adversarial case.

The assertion thresholds are generous: `avg_down > avg_up * 1.2`. A 20% separation between "completely opposite regimes" is not ambitious. The reported numbers (3.49x and 6.29x) are much better than the threshold, which means either the threshold is too conservative or the test is too easy. Given synthetic data, I'd bet on the latter.

The `raw_cosine_vs_anomaly_cosine` test is the more important one. 0.96 raw vs 0.12 after stripping is a dramatic improvement. But it's testing one uptrend against one downtrend, both synthetic. The test I'd want to see: train on 200 windows of *real BTC candle data from 2020*, test against *real BTC candle data from 2024*. If the subspace still separates, the architecture works. If it doesn't, you've built a synthetic-data separator.

The proof is honest about what it proves. The proposal says "measured" and shows the numbers. That's better than most proposals. But the gap between "this works on synthetic monotone series" and "this works on BTC 5-minute candles" is the gap where proposals go to die.

## The capacity math

The capacity math is sound. `sqrt(D)` as the bundle budget is the Kanerva limit, well-established in the VSA literature. The accounting is careful: 15 market + 13 regime + 5 portfolio + 1 phase = 34 items at D=10,000 (budget 100). Comfortable. The observation that bind costs zero capacity because it rotates rather than superposing is correct and important — it means the trigrams and pairs are free. Only the final bundle counts.

The one thing I'd watch: the proposal counts "items in the bundle" but each item is itself a bundle (the rhythm vector is a bundle of pairs). The Kanerva limit applies per level, and it's respected per level, but the *effective* information capacity compounds. A rhythm of 64 pairs, each a bind of two trigrams, each a bind of three phase records of 10 facts — that's a deep composition. At some depth, the information degrades not because of capacity but because of noise accumulation in the floating point. The proposal doesn't discuss numerical stability of deep VSA compositions. At D=10,000 with f32 vectors, this probably doesn't matter. But it's the kind of thing that matters at 3AM when a test passes at D=10,000 and fails at D=4,096.

## The thermometer

The thermometer encoding is the most concrete contribution and the easiest to evaluate. The cosine formula `1.0 - 2.0 * |a - b| / (max - min)` is correct and gives a linear gradient — identical values map to cosine 1.0, maximally different values map to cosine -1.0, and everything in between is proportional. This is the right encoding for bounded indicators with meaningful absolute positions (RSI at 30 means something different from RSI at 70, and the difference should be proportional to the distance).

The question the proposal doesn't address: what happens at the boundaries? An RSI of 0.0 and an RSI of 5.0 get `|0-5|/100 = 0.05`, cosine = 0.90. An RSI of 95.0 and RSI of 100.0 get the same. But RSI spends most of its life between 30 and 70. The encoding gives equal resolution across the full range, but the *useful* range is the middle. This isn't a bug — it's a feature of thermometer encoding — but it means most of the dynamic range is allocated to values the indicator rarely visits. A thermometer over [20, 80] would give 2.5x the resolution in the useful range. The proposal chose the mathematical bounds over the empirical bounds. That's a defensible choice, but it's a choice, and it costs resolution.

For deltas, the symmetric range from ScaleTracker is the right call. Deltas are centered at zero by construction. The range needs to be learned, and the ScaleTracker learns it. No complaints there.

## What's missing

The proposal is silent on the transition path. It says "`phase_series_thought` replaced by `phase_rhythm`" but the current system is live, running, producing results. What's the migration plan? Do you run both encodings in parallel and compare? Do you switch atomically and measure the before/after? Do the reckoners need to be reset because the geometry changed? A new encoding is a new language. The reckoners learned to read the old language. They need to relearn. The proposal should say how much that costs.

The proposal is also silent on computational cost. Each indicator rhythm requires walking the window, computing deltas, forming trigrams, forming pairs, bundling. 15 indicators times 100 candles is 1,500 fact encodings, 1,470 trigrams, 1,455 pairs, 15 bundles, per market observer, per candle. The current snapshot encoding is ~33 facts, once. That's a 40x increase in encoding work. Is that acceptable at 251 events/second? The proposal should have a back-of-envelope throughput estimate.

## Conditions

1. Run the proof on real BTC candle data, not synthetic. If it separates, merge. If it doesn't, the thermometer and delta scheme need work before the rhythm encoding will matter.

2. Address the prior-bundle vs same-phase delta complection. Either separate them into distinct rhythms or argue explicitly why braiding them is the right choice for this domain.

3. Add a throughput estimate. The architecture is meaningless if it can't keep up with the candle stream.
