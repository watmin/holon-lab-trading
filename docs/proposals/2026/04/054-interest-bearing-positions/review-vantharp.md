# Review: Van Tharp

Verdict: CONDITIONAL

The core insight is strong: replacing distance-based exits with
time-cost exits is a legitimate position sizing framework. Interest
as carrying cost is how professional capital markets work. But the
proposal has statistical gaps that must be addressed before it
produces measurable expectancy.

## Answers to the 10 Questions

### 1. The lending rate

ATR-proportional. Fixed rate creates a hidden regime dependency — a
rate that filters well in low-volatility periods will be invisible
in high-volatility periods, and vice versa. The rate should breathe
with the market's current movement per candle. One ATR fraction per
candle is the natural unit. The rate is 1R. This is correct — but
only if it scales with volatility. A fixed rate means 1R is a
different bet in January 2020 versus March 2020. That is not a
stable system.

### 2. Entry frequency

One entry per phase window, not per candle. One per candle during a
53-candle window creates 53 overlapping positions with correlated
outcomes. Your sample of 200 papers is not 200 independent trades —
it is perhaps 4-8 independent clusters. The survival rate of 70%
on 200 papers sounds like n=200, but the effective sample size is
closer to n=20. This is the single biggest statistical risk in the
proposal. Entry frequency must be low enough that consecutive
entries are not measuring the same market move.

### 3. The reckoner's question

Discrete is correct. "Exit or hold at this trigger" produces a
binary outcome the reckoner can learn from. "How much longer" is a
continuous prediction that requires the reckoner to be right about
magnitude, not just direction. Your own finding from Proposal 053
is that continuous distance prediction inflates. Discrete avoids
that failure mode entirely. The R-multiple framework works here:
every hold decision at a trigger is a fresh bet with a known cost
(the interest since last trigger). The reckoner learns the shapes
that precede Grace versus Violence. That is learnable.

### 4. Treasury reclaim

Automatic. No grace period. When interest exceeds position value,
the trade is dead. Giving the broker "one more transition" is
giving the losing trade hope, and hope is the most expensive
emotion in trading. The interest IS the stop. If you soften the
stop, you have recreated the distance problem with extra steps.
Hard reclaim keeps the definition of Violence clean and the
learning signal unambiguous.

### 5. The residue threshold

The reckoner should learn "worth it." Any fixed threshold is a
magic number. The three-condition AND gate (phase + direction +
positive residue after fees) already prevents arithmetically
impossible exits. Beyond that, the reckoner should discover from
its own curve which exits were premature versus which captured
sufficient residue. The learning signal is: did exiting HERE
produce better outcomes than holding through to the next trigger?
That is what the reckoner's journal should measure.

### 6. Both sides simultaneously

Yes, both sides. This is portfolio-level hedging. The treasury
lends to longs and shorts. The net exposure is the treasury's
real risk. But — and this is critical — the treasury must track
net directional exposure as a position sizing constraint. If 80%
of active capital is long, the next long proposal gets less
capital, not more. The phase labeler's statistical symmetry
(2,891 buy vs 2,843 sell) suggests natural balance, but symmetry
in window COUNT does not guarantee symmetry in window TIMING.
Clusters of same-direction windows will occur. The treasury needs
a net exposure limit.

### 7. The interest as thought

The four anxiety atoms are good. Add one more: `drawdown-from-peak`.
The distance between the position's maximum unrealized profit and
current value is the most informative fact about whether a runner
is dying. A position that was up 3% and is now up 0.5% feels
very different from one that was never above 0.5%. The reckoner
needs this signal to distinguish "runner cooling off" from "trade
that never worked."

### 8. The denomination

Per-candle is correct granularity. ATR-proportional rate, as
stated in question 1. Fixed rate in a volatile market means
interest is trivial during big moves and punishing during quiet
periods — exactly backwards from what you want. The rate should
be calibrated so that a flat position (zero movement in your
direction) erodes to Violence in approximately 2-3 average phase
durations. That gives the trade enough room to encounter one
favorable phase while punishing indefinite holding.

### 9. Rebalancing risk

The treasury MUST limit directional exposure. Phase labeler
symmetry is a long-run statistical property, not a per-candle
guarantee. Sustained trending markets will produce extended
same-direction windows. Cap net directional exposure at 60-70%
of total portfolio. This is position sizing at the portfolio
level — the same discipline applied one layer up. Without this,
a strong trend followed by a reversal will leave the treasury
heavily imbalanced at exactly the wrong moment.

### 10. Paper erosion as the only gate

Insufficient. Paper survival rate is necessary but not sufficient.
You need at minimum:

- **Survival rate** (the proposal has this)
- **Average R-multiple of survivors** (how much do winners win?)
- **Average R-multiple of Violence deaths** (how much do losers lose?)
- **Expectancy** = (win rate x avg win) - (loss rate x avg loss)

A 70% survival rate with tiny winners and large Violence losses
has negative expectancy. A 40% survival rate with large winners
and small Violence losses has positive expectancy. Survival rate
alone cannot distinguish these cases. The treasury must compute
expectancy from the paper trail. The gate should require positive
expectancy over the last N independent samples, not just survival
rate above a threshold.

## The Conditional

The interest-as-stop-loss concept is sound. The three-condition
exit is well-constructed. The anxiety-as-thought encoding is
natural. The treasury-as-lender model is how real capital markets
work. But the proposal will produce a system that LOOKS like it
has statistical validity while hiding three problems:

1. **Correlated samples.** Entry frequency of one-per-candle
   destroys sample independence. The survival rate is not what
   it appears to be.

2. **No expectancy calculation.** Survival rate without R-multiple
   distribution is half a measurement. A system can have high
   survival and negative expectancy.

3. **Fixed rate in a volatile market.** The rate must breathe or
   it selects for regime, not skill.

Fix these three and the proposal produces a measurable, honest
trading system. Without them, the paper trail proves something,
but not what you think it proves.

The favor system (rising/falling/rehabilitation) is narratively
appealing but statistically ungrounded as written. "The rate
never drops as fast as it rose after the fall" is a punishment
heuristic, not a statistical relationship. The rate should be
a function of recent expectancy — if the broker's trailing
expectancy is positive and stable, the rate drops. If it turns
negative, the rate rises. The treasury remembers through the
math, not through asymmetric decay curves. Make the favor
system mechanical and expectancy-driven, not narrative.

The lending model is the right abstraction. Interest as 1R is
the right definition — IF the rate scales with volatility.
The paper trail is the right proof — IF you measure expectancy,
not just survival. The discrete exit is the right question — IF
the samples are independent.

Conditional approval. Address the three items. Then this is a
legitimate position sizing framework.
