# Review: Van Tharp

**Verdict: CONDITIONAL**

Conditional on measuring expectancy through the architecture before going live, and on defining the worst-case scenario explicitly at the broker-observer level.

---

## What This Proposal Gets Right

### The Psychology Is Sound

This is the most psychologically honest trading architecture I have reviewed in some time. Let me explain why.

Most system designers encode what they *wish* the market were doing. They build indicators that confirm their beliefs and ignore the ones that disagree. This proposal does something fundamentally different: it encodes the *evolution* of indicators as rhythms, then strips out what is normal, and trades only on what remains. The system does not trade on what it believes. It trades on what surprises it.

That is the correct psychological stance. A trader who only acts on surprise cannot be overconfident, because the noise subspace literally removes the familiar. A trader who sees rhythms rather than snapshots cannot suffer from recency bias, because the trigram-pair encoding carries the full recent movie, not just the last frame. The architecture enforces good trading psychology through its structure, not through willpower.

The choppy-range example is particularly telling. When the same-deltas cluster around zero, the system sees "range-bound" and does nothing. Doing nothing in chop is Grace. Most traders cannot do nothing. Most systems do not reward doing nothing. This one does, because the geometry itself becomes uninteresting to the reckoner when nothing is progressing.

### The Broker-Observer's Anxiety Is Real Risk Management

The five portfolio rhythm indicators in the broker-observer's thought are exactly what a position manager needs:

- `avg-paper-age` -- how long have positions been open, and is that getting worse?
- `avg-time-pressure` -- are positions approaching their natural expiry under stress?
- `avg-unrealized-residue` -- is unrealized P&L drifting negative?
- `grace-rate` -- what fraction of recent closes were winners?
- `active-positions` -- is exposure growing?

These are not snapshots. They are *rhythms*. The broker does not see "I have 3 positions." It sees "I had 1 position, then 2, then 3, and each new one has been less profitable than the last." That progression IS anxiety. The delta encoding captures the deterioration. The noise subspace strips the normal level of exposure, leaving only the deviation -- the growing unease.

This is essentially what I teach about the psychology of position sizing. The size of your position affects your ability to think clearly. When unrealized losses accumulate and age, the trader's judgment degrades. This architecture makes that degradation visible as a vector direction. The gate reckoner can learn: "when the anxiety rhythm points HERE, get out."

### The Phase Rhythm Captures Market Type

The four phase types (transition-up, peak, transition-down, valley) with their structural deltas encode what I call "market type" in my work. A trending market has strengthening transition-ups and weakening transition-downs. A volatile market has wide ranges on both transitions. A quiet market has near-zero deltas everywhere.

The examples are well-chosen. The exhaustion-top (weakening rallies, lingering peaks, strengthening selloffs) is a textbook distribution pattern. The breakdown (higher lows but weaker rallies -- the contradiction IS the signal) captures the kind of divergence that precedes sharp moves. The recovery-bottom (three rising valleys with weakening selloffs) is accumulation.

The fact that these patterns emerge from the same encoding with different scalars, rather than from different rules, means the system can recognize patterns it was never explicitly taught. That is the hallmark of a robust system.

---

## What Is Missing

### Position Sizing Is Absent

The proposal defines *when* to exit (Hold/Exit) but says nothing about *how much* to risk. The treasury "funds proportionally to edge" -- but where is the edge measured? Where is the R-multiple defined? Where is the initial risk (1R) calculated for each trade?

Every trade must have a defined worst case before entry. The initial stop defines 1R. The position size is derived from 1R and the total capital at risk. This is not optional. It is the single most important decision in any trading system.

The broker-observer decides Hold or Exit. The position observer predicts trailing stop and safety stop distances. But I do not see where the *initial* risk is bounded. If the position observer's predicted stop distance is 3% and the treasury allocates 10% of capital, the worst case on that trade is 0.3% of total equity. Is that calculated? Is it bounded? Is it tracked as part of the anxiety rhythm?

**Requirement:** Before this architecture goes live, the initial risk per trade (1R) must be explicit. The treasury must enforce a maximum portfolio heat (total open risk across all positions). The broker-observer's anxiety rhythms should include a `portfolio-heat` indicator that tracks total open 1R exposure over time.

### Expectancy Is Not Measured Through the Architecture

The proposal proves that the noise subspace separates regimes (3.5x residual separation). That is a necessary condition. It is not a sufficient condition. Regime separation does not equal positive expectancy.

Expectancy = (Win% x Average Win) - (Loss% x Average Loss)

Or in R-multiple terms: the mean R-multiple across all trades. A system with 40% winners averaging +3R and 60% losers averaging -1R has expectancy of +0.6R. That is a good system.

Where is this measured? The reckoner learns to discriminate Grace from Violence, but the proposal does not describe how the R-multiple distribution is tracked, reported, or used for position sizing. The curve (conviction-to-accuracy) is mentioned as accountability, but the curve should map to an R-multiple distribution at each conviction level.

**Requirement:** The system must track R-multiples for every trade. The expectancy must be calculable from the run database at any time. The position sizing (treasury allocation) should scale with measured expectancy, not just "edge" as an abstract concept.

### The Worst Case Is Undefined

What happens when the noise subspace is wrong? When the market enters a regime so novel that all three subspaces (market, regime, broker) produce high residuals simultaneously? The system sees "everything is anomalous" -- but that could mean opportunity or catastrophe.

In a flash crash, every rhythm deviates from normal. The market observer's anomaly is extreme. The regime observer's anomaly is extreme. The broker-observer's combined anomaly is extreme. The gate reckoner sees a direction it has never seen before. What does it do?

The architecture needs a circuit breaker. Not a kill switch (which requires human intervention). An automatic maximum drawdown threshold that exits all positions and pauses trading when cumulative loss exceeds a defined limit. This is the "worst case" definition that every system must have before it touches real capital.

**Requirement:** Define the maximum acceptable drawdown. Define the automatic response. Make it algebraic if you want -- a residual threshold above which the system goes flat. But define it.

---

## The Noise Subspace: Edge Amplifier, Not Edge Creator

The proof test shows raw cosine of 0.96 between uptrend and downtrend rhythms dropping to 0.12 after subspace stripping. That is impressive signal extraction. But I want to be precise about what this means.

The noise subspace does not create edge. It amplifies whatever edge exists in the rhythm encoding by removing the shared structure that obscures it. If the underlying indicator rhythms contain no predictive information about future price movement, the subspace will faithfully amplify noise into... cleaner noise.

The three-layer filtering (market subspace strips market background, regime subspace strips regime background, broker subspace strips the combination background) is elegant. Each layer removes one source of "this is normal." What survives is the triple anomaly. If the reckoner can learn from these triple anomalies, the system has edge. If it cannot, no amount of filtering will help.

This is actually a strength of the design. The system is honest. It does not pretend to create edge from thin air. It provides the reckoner with the cleanest possible signal and lets the reckoner prove (via curve accountability) whether that signal has predictive power. That honesty is rare.

---

## The Thermometer Encoding Fix

The diagnosis of the rotation-based scalar failure is correct and important. If +0.07 and -0.07 encode to identical vectors, the system literally cannot see the direction of change. The delta IS the causality, and the causality was invisible. Fixing this with thermometer encoding (linear gradient, sign-preserving) is the right call.

This is the kind of subtle encoding bug that can persist for months while everyone blames the reckoner for not learning. The reckoner cannot learn what it cannot see. Good diagnosis.

---

## Specific Concerns

**1. The trim strategy drops the oldest pairs.** This means the system forgets the early part of extended moves. A 500-candle window trimmed to 100 pairs loses the first 400 candles of context. For most trading purposes this is fine -- recent context matters more. But during extended trends (BTC in 2020-2021), the early structure carries information about the nature of the trend. Consider whether the trim should keep a small sample of early pairs alongside the recent ones, rather than pure recency.

**2. The Kanerva limit at D=4,096 is tight.** The proposal acknowledges this: "At D=4,096 (budget: 64): tight. The lens must be selective." For a trading system, tight capacity means information loss. Information loss means edge erosion. I would strongly recommend D=10,000 as the minimum for production. The cost is compute. The benefit is headroom. Headroom is cheap insurance.

**3. The broker-observer has no concept of correlation between positions.** The anxiety rhythms track averages across the portfolio. But two positions in the same direction on the same asset are not the same as two positions in opposite directions on different assets. The current architecture treats them the same because it averages age, pressure, and unrealized across all positions. When the system moves to multi-asset, this must change.

---

## Summary

The proposal demonstrates sophisticated understanding of what matters in trading system design: the evolution of market state (rhythms, not snapshots), the psychological state of the portfolio (anxiety as a vector), and the separation of signal from noise (subspace stripping). The encoding examples show that the geometry captures real market patterns -- exhaustion tops, breakdowns, recoveries, chop -- without hardcoded rules.

The conditional items are:

1. **Define 1R per trade.** Make initial risk explicit. Track R-multiples.
2. **Measure expectancy.** Not just accuracy -- the full distribution of outcomes in R-multiple terms.
3. **Define the worst case.** Maximum drawdown, automatic response.
4. **Use D=10,000 minimum.** Do not go to production at D=4,096.

Meet these conditions and the architecture is approved. The foundation is sound. The encoding is honest. The noise subspace is the right tool applied at the right layer. The psychology is enforced by structure, not by discipline. That last point alone puts this system ahead of most I review.

The market does not care about your architecture. It cares about your position size and your ability to survive the worst case. Build those in, and this system has a real chance.

-- Van K. Tharp
