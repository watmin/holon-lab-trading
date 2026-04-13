# Review: Van Tharp
Verdict: CONDITIONAL

## Overall Assessment

This proposal gets something deeply right that most system designers
miss entirely: the trade is not the entry. The trade is the
*management* of the position from entry through exit. The biography
concept — encoding a trade's history of survival through decision
points — is precisely the kind of context that separates professional
position management from amateur "set and forget."

The pivot-based approach also addresses a statistical problem I see
constantly: systems that generate too many trades in noise and too
few in opportunity. By gating activity on conviction spikes, you
naturally reduce sample pollution. Fewer trades, each more meaningful,
each with defined context. This is the path to positive expectancy.

The concern — and this is where the CONDITIONAL comes — is that
this proposal introduces multi-position management per broker without
sufficiently defining the R-multiple framework that governs it.

## The R-Multiple Gap

Every trade must define its initial risk — its 1R. This proposal
describes trail distances, excursion, retracement. But I do not see
where 1R is locked at entry. When Trade 1 enters at $100, what is
its 1R? Is it the initial trail distance? The safety stop? This must
be explicit and immutable for the life of the trade.

Without locked 1R per trade:
- You cannot compute R-multiples at exit
- You cannot compute expectancy across the portfolio
- You cannot compare Trade 1 (a 5-pivot runner) to Trade 3 (a newborn)
  on equal terms
- You cannot aggregate risk across the broker's portfolio

The `r-multiple` atom already exists in the trade atoms from
Proposal 040. Good. But with multiple concurrent trades, the
broker's AGGREGATE R-exposure becomes critical. Four trades
each risking 1R means 4R total heat. If the pivot that kills
Trade 1 also kills Trade 2 and Trade 3 (because they entered
during the same move), you take a 3R loss, not a 1R loss.
Correlated entries produce correlated exits.

## Answers to the Six Questions

### 1. Pivot detection: conviction or separate mechanism?

Conviction is correct. A pivot is a decision point — a moment where
the system has enough information to evaluate. The market observer
already measures "something is happening." Reusing that signal avoids
overfitting a secondary detector.

However: the conviction threshold should not be fixed. Different
market regimes produce different conviction distributions. A fixed
threshold will overtrade in volatile regimes and undertrade in quiet
ones. Let the threshold be adaptive — perhaps the top N% of recent
conviction values. This preserves the conviction mechanism while
adapting to regime.

### 2. Pivot memory size: 10, 20, or discovered?

Fixed at 10, with a reason: you need enough pivots to compute
meaningful series statistics (trends, compression, spacing) but not
so many that old regime data poisons current evaluation. 10 pivots
at ~50 candle spacing is ~500 candles — roughly 40 hours on 5-minute
bars. That is one regime. Two regimes of memory is noise.

Do NOT try to discover this. Optimizing memory size is a parameter
that will overfit to backtest. Pick 10. Accept the choice. Move on.
The energy spent discovering optimal memory size is better spent on
improving the R-multiple framework.

### 3. Trade biography on the chain: pivot memory or computed atoms only?

Computed atoms only. The exit observer should see the *statistics*
of the pivot history, not the raw records. The 3 new atoms plus the
6 pivot series atoms are sufficient context. Sending raw pivot
records forces the exit observer to do its own computation — that
is not its job. Its job is: given this biography, what trail
distance serves this trade? Feed it conclusions, not data.

This also matters for dimensionality. 10 raw pivot records with
5 fields each is 50 additional dimensions per trade. The computed
atoms are 9. Fewer dimensions, more signal.

### 4. Portfolio biography scope: compose or separate?

Compose. The broker's reckoner must see the portfolio state IN
CONTEXT with the market thought. A portfolio-heat of 0.7 means
something different during a trend (acceptable — you are
accumulating in a move) than during range-bound chop (dangerous —
you are stacking correlated entries in noise). The reckoner cannot
make this judgment if portfolio state arrives separately from
market state. Bundle them.

But separate the ACCOUNTING from the THOUGHT. The portfolio-heat
atom flows into the reckoner for decision-making. The actual
position sizes flow to the treasury for risk enforcement. The
reckoner proposes. The treasury disposes.

### 5. Entry decisions: hard cap or learned?

Both, and this is the critical position sizing question.

**Hard cap (the treasury's job):** Total portfolio heat across ALL
22 brokers must never exceed a maximum — I recommend 20% of capital
as aggregate heat. This is non-negotiable. No reckoner, no matter
how convinced, overrides the heat limit. The treasury enforces this
by refusing to fund proposals that would breach the cap.

**Per-broker cap (structural):** A single broker should not hold
more than 4-5 concurrent trades. Not because of a parameter
optimization — because of correlation. Entries by the same broker
are correlated by definition (same market observer, same exit
observer, same lens). Four correlated trades is 4R of correlated
risk. At 5, you are one adverse pivot away from a significant
drawdown from a single broker.

**Learned entry sizing (the reckoner's job):** Within the hard caps,
the portfolio-heat atom teaches the reckoner when adding a position
is productive vs reckless. High heat + compressed range + many
pivots survived = the reckoner learns to WAIT. Low heat + expanding
range + fresh pivot = the reckoner learns to ENTER. But it learns
this within bounds. The bounds are not learned. The bounds are
imposed.

Never let a learning system discover its own risk limits. The
system optimizes for expectancy. The human imposes the drawdown
constraint. These are different objectives.

### 6. Simultaneous buy/sell across brokers: independent or netted?

Independent. Always independent.

Netting is an accounting fiction. Broker A exiting and Broker B
entering at the same pivot are two independent decisions based on
two different biographies. If you net them, you destroy the
information about WHY each decision was made. You also make it
impossible to evaluate each broker's expectancy independently.

The treasury should fund both. Broker A's exit returns principal
plus residue. Broker B's entry consumes new capital. These are
separate flows. The treasury's job is to track them separately,
enforce the heat cap on the aggregate, and let each broker's
curve tell the truth about its edge.

If the aggregate heat exceeds the cap after both are processed,
the treasury refuses the ENTRY (Broker B), not the EXIT (Broker A).
Exits always execute. Entries are contingent on available capital.

## The Expectancy Argument

This proposal will reduce trade count per broker significantly.
Instead of evaluating every candle, brokers evaluate at pivots
only. With 10 pivots per 500 candles, that is roughly 2% of
candles producing decisions. Over 100k candles, each broker might
produce 100-200 trades instead of thousands.

This is GOOD for expectancy analysis — if and only if the sample
size remains sufficient. With 22 brokers, even at 150 trades each,
you have 3,300 resolved trades across the system. That is
statistically meaningful. But any individual broker's 150 trades
requires caution in interpretation. I would want at least 100
trades per broker before trusting its curve. At 150, you can
start to see the distribution shape. At 500, you can trust it.

The key metric shifts from win rate to R-multiple distribution.
A system with 40% win rate but average winner = 3R and average
loser = 1R has expectancy of (0.4 x 3) - (0.6 x 1) = 0.6R per
trade. With fewer trades, each trade must produce a higher
R-multiple to maintain portfolio growth. The biography framework
— letting runners run, cutting newborns quickly — is precisely
the mechanism that produces high R-multiple winners.

## The Conditional

APPROVED if the implementation includes:

1. **Locked 1R per trade at entry.** Immutable. Computed from the
   initial trail or safety stop distance. Every trade carries its
   1R from birth to death.

2. **Per-broker heat cap of 4-5 concurrent trades.** Structural,
   not learned. Correlation demands it.

3. **Aggregate portfolio heat cap enforced by treasury.** 20% of
   capital maximum across all 22 brokers. Non-negotiable.

4. **R-multiple tracking per trade at resolution.** When a trade
   exits, its R-multiple (profit or loss divided by 1R) is
   recorded. This is the only honest measure of system performance.

If these four conditions are met, the proposal is sound. The pivot
biography framework is a genuine advance — it gives the exit
observer the context it needs to differentiate runners from
losers, and it gives the broker the portfolio awareness it needs
to accumulate intelligently.

Without locked R and enforced heat caps, the multi-position
framework is a drawdown generator. Many correlated entries in
the same move, each sized independently, with no aggregate
risk constraint. That is the path to ruin.

The algebra is elegant. The statistics are promising. The risk
framework needs teeth.
