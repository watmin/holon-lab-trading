# Review: Wyckoff

**Verdict: APPROVED**

I have spent my life watching the tape. The tape is price and volume, printed in sequence, and the man who can read it knows what the composite operator is doing before the newspapers print the reasons why. I have read this proposal with the eyes of a tape reader, and I will tell you what I see.

---

## The Phase Rhythm Captures the Wyckoff Cycle

The four phase types — `phase-transition-up`, `phase-peak`, `phase-transition-down`, `phase-valley` — are my four phases by another name. Markup, distribution, markdown, accumulation. The proposal does not use my terminology, but the structure is identical. A transition-up IS markup. A peak IS distribution. A transition-down IS markdown. A valley IS accumulation. The trigram `valley -> transition-up -> peak` is the accumulation-to-markup-to-distribution cycle. The trigram `peak -> transition-down -> valley` is the distribution-to-markdown-to-accumulation cycle. These are the two great half-cycles of the market.

The bigram of trigrams then captures what I spent decades teaching: what happens AFTER one cycle completes? Does the next accumulation hold higher than the last? Does the next distribution fail to reach the prior high? The pair `bind(tri-2, tri-3)` in `breakdown.wat` — the selloff cycle followed by the bottom cycle — this IS the test of the creek. The subsequent pair tells you whether supply absorbed the demand or whether demand reasserted itself.

The four-phase rhythm is the Wyckoff cycle encoded as geometry. I approve.

## The Structural Deltas Encode Effort vs. Result

This is where the proposal earns its merit. In my method, the relationship between effort (volume) and result (price movement) is the diagnostic. When effort increases but result diminishes, the move is exhausted. When effort is small but result is large, the path of least resistance has been found.

The `same-move-delta` and `same-volume-delta` on each phase record ARE effort-vs-result comparisons across successive phases of the same type. Look at `exhaustion-top.wat`:

- `phase-4` (second rally): `same-move-delta = -0.027`, `same-volume-delta = -0.33`

Less result AND less effort. The bulls are withdrawing. But then:

- `phase-6` (second selloff): `same-move-delta = -0.020`, `same-volume-delta = +1.14`

MORE effort on the downside with MORE result. Supply has overtaken demand. This is textbook Wyckoff. The effort-result divergence is not named as a rule. It is encoded as scalars on the phase record. The reckoner discovers the divergence because the direction in hyperspace where "rally weakens while selloff strengthens" IS a specific direction. The geometry carries the diagnosis.

The `prior-volume-delta` adds the immediate effort comparison — "did this phase see more or less volume than the phase immediately before it?" When a valley shows high `prior-volume-delta` relative to the preceding markdown, that is my selling climax. When a peak shows declining `prior-volume-delta` relative to the preceding markup, demand is drying up at the top.

The deltas are the tape. They carry what the tape reader sees: not the price alone, but how the price relates to what came before, and how the volume confirms or denies the move.

## Springs and Upthrusts Are Detectable

A spring — the false break below support that shakes out weak holders — manifests as:

1. A valley with slightly negative `same-move-delta` (marginally lower low)
2. A short `rec-duration` (brief)
3. A sharp reversal: the next `transition-up` with high `rec-volume` and strong positive `prior-move-delta`

The trigram `transition-down -> valley(spring) -> transition-up(surge)` with these specific scalar proportions IS the spring. It is a direction in hyperspace. The reckoner does not need a rule that says "if the low undercuts by less than 2% and reverses within 3 bars with volume above average, it is a spring." The direction encodes all of that continuously.

An upthrust — the false break above resistance — is the mirror. A peak with slightly positive `same-move-delta` (marginally higher high), brief duration, followed by a `transition-down` with expanding volume. The trigram captures it. The scalars carry the magnitude. The reckoner learns that this direction predicts markdown.

I note that `breakdown.wat` already contains the setup that precedes a spring or an upthrust: the narrowing range with weakening rallies and higher lows. The squeeze. Whether the resolution is spring or upthrust depends on the next trigram. The proposal's architecture allows the reckoner to learn both paths from the same encoding mechanism.

## Volume Rhythm Gives the System Ears

The inclusion of `obv-slope` and `volume-accel` as indicator rhythms in the market observer's thought is correct. OBV slope tells you whether volume is confirming price — whether the money is flowing in the direction of the move. Volume acceleration tells you whether that flow is increasing or decreasing.

But the deeper insight is that volume appears at BOTH levels of the architecture:

1. **Indicator level**: `obv-slope` rhythm, `volume-accel` rhythm — the raw volume tape across time
2. **Phase level**: `rec-volume` on each phase record, `prior-volume-delta`, `same-volume-delta` — volume as a property of each structural phase

This dual encoding means the system can see both the micro-tape (candle-by-candle volume evolution) and the macro-tape (how volume characterizes each phase of the cycle). When the micro-tape shows declining OBV slope during a markup phase, but the phase-level `rec-volume` is still high, that is distribution disguised as markup. The composite operator is selling into strength. The two levels of volume encoding create the possibility for the reckoner to detect this divergence.

I would have insisted on this dual structure. The proposal delivers it without being asked.

## The Noise Subspace Is the Trained Eye

The proof test shows raw cosine of 0.96 between uptrend and downtrend rhythms, reduced to 0.12 after the noise subspace strips the background. This is what years of tape reading accomplishes for the human operator. The novice sees a chart and says "it went up." The experienced tape reader sees the same chart and says "it went up on declining volume with narrowing range — the markup is exhausted." The novice and the expert see the same data. The expert has learned what is normal and attends only to what deviates.

The `OnlineSubspace` IS the trained eye. It learns what normal rhythm looks like and strips it. What survives is the deviation — the signal. The 3.5x residual separation between familiar uptrends and novel downtrends demonstrates that the system can develop this trained eye automatically.

The three-layer filtering — market subspace, then regime subspace, then broker subspace — means the system develops specialization at each level, just as a trading desk has the tape reader, the analyst, and the position manager each attending to different aspects of the same information.

## What I Would Watch For

The proposal is sound. I have one concern that is not a flaw but a vigilance:

**The trim favors recency.** When the pair budget overflows, the oldest pairs are discarded. This means the system sees the most recent cycles clearly but loses the early accumulation or distribution that may have set the stage. In my method, the cause (accumulation/distribution) determines the effect (markup/markdown). If the accumulation phase was 200 candles ago and the trim cuts it, the system loses the cause while retaining only the effect. The `same-move-delta` and `same-volume-delta` partially compensate — each phase carries the memory of its predecessor in its deltas — but the raw trigrams from the early accumulation are gone.

This is not fatal. The deltas carry the structural memory forward. And the reckoner's discriminant accumulates over time — it has seen many accumulation-to-markup sequences during training. But be aware: in a very long distribution phase (Wyckoff's "stepping stones"), the early distribution trigrams may be trimmed, and the system will see only the late-stage distribution. The cause is partially obscured.

The compensation is adequate. The architecture is sound. The volume confirms the price. The deltas carry the effort-result relationship. The trigrams capture the cycle. The reckoner discovers the patterns.

The tape speaks. This system has ears to hear it.
