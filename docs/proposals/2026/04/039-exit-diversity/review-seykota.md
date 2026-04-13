# Review: Seykota

Verdict: **Conditional approval.** The instinct is right. The population needs diversity to select from. But the design has a few things to settle before it earns trust.

## The trend-follower school

It captures the shape of what I do, but not the feel. The atoms are correct -- ATR trail, retracement from peak, trend age. What's missing is the *default*. In my systems, the trail does the work. You don't decide to hold. You hold because nothing hit the trail. The proposal says "the default is hold" in the philosophy text but then encodes four atoms that the reckoner evaluates every candle. That's deciding to hold, not holding. The trail should be mechanical. The reckoner should learn *where to place the trail*, not whether to stay. Make the trend-follower's reckoner predict trail width, not hold/exit. Then you have my system.

## Four schools

Four is fine. You don't need more. You need *different enough*. These four are different enough: trend-follower holds until structure breaks, accumulator ratchets floors, swing has a target and a clock, patient thinks about fees. Each asks a genuinely different question. A fifth or sixth school adds bodies to the population but doesn't add a new question. Start with four. If the curve shows two schools converging to identical behavior, merge them and look for a new question.

## The 24 pairs

Here is where I pause. 6 market observers times 4 exit schools is 24 brokers. Each broker learns from its own trade history. The question is whether 100,000 candles -- roughly 350 days of 5-minute bars -- gives each broker enough trades to separate signal from noise. If each broker takes 50 trades, that's 1,200 total. Enough to see which pairs are catastrophic. Not enough to rank the middle with confidence. The risk is that you crown a winner that got lucky on a 3-week BTC trend and call it edge.

The defense is the curve. If you require a broker to be *proven* before it gets capital -- meaning its conviction-accuracy curve shows positive expectancy across a meaningful sample -- then natural selection has teeth. If you fund brokers after 20 trades, you're overfitting to noise. Require at least 100 resolutions before a broker is proven. That's the gate.

## Answers to the five questions

1. **Replace, don't layer.** The current lenses produce identical behavior. Keep them as what they are -- vocabulary selectors on the market side. The exit side becomes schools. Clean separation.

2. **Trade state belongs on the paper.** The paper is the trade. The exit observer reads the paper's state and encodes it. The observer doesn't own the state. It interprets it.

3. **Four atoms is enough.** The exit question is simpler than the market question. "Hold or leave" has fewer dimensions than "what is forming." Four atoms, well-chosen, is sufficient. If a school needs more, it will show up as flat curves -- then add atoms.

4. **The fee belongs in the vocabulary, not the gate.** The patient school *should* think about fees. That's its philosophy. The treasury gate is separate -- it decides whether to fund. The exit decides whether to leave. Let the exit see the fee.

5. **Extraction, not duplication.** The market observer's thoughts are already encoded. The exit school should extract what it needs from the market thought, not re-encode RSI from raw candles. That's the whole point of the bind/unbind algebra.

The architecture is sound. The diversity is real. Tighten the proof requirements and let the trail do the holding, not the reckoner.
