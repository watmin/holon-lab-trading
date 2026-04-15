# Debate: Wyckoff

## To Van Tharp, on correlated samples

You are right that 53 entries in a 53-candle window are not 53
independent samples. You are wrong that this is a problem.

The composite operator does not enter once per accumulation range.
He enters on each test of support. Each test is a different event
— the same cause, yes, but a different expression. The spring is
not the secondary test. The secondary test is not the sign of
strength. They occur within the same accumulation range. They are
correlated. They are still distinct trading opportunities with
distinct outcomes.

Your effective sample size of n=20 assumes the correlation is
near unity. It is not. Two entries at the start of a phase window
and two entries near the end face different interest burdens,
different residue trajectories, different trigger evaluations. The
early entry that catches the full move survives. The late entry
that catches the tail dies from interest. Same phase. Different
outcomes. The interest clock decorrelates them.

The real test is not whether entries within a window are independent.
The real test is whether the survival rate measures something
predictive. A broker that enters 53 times per window and survives
at 70% is a broker whose entries are robust to timing within the
phase. A broker that enters once per window and survives at 70%
is a broker that picks the right moment. Both are valid edges.
The treasury's ledger records both. The survival rate measures both.

I do not object to your suggestion of one entry per window as a
conservative starting point. I object to calling multiple entries
a statistical defect. The tape prints on every trade. Every trade
is a data point. The correlation is real but partial, and the
interest creates genuine variation within the cluster. The effective
sample size is larger than you calculate.

Your expectancy point is stronger. I concede that survival rate
alone can mask the distribution of outcomes. A broker that survives
at 70% with tiny residues and dies at 30% with large Violence
losses is net negative. The treasury should compute mean residue
of Grace exits alongside survival rate. Two numbers. Not a full
R-multiple distribution — the interest already defines 1R. But
the average magnitude of Grace must be visible. I said one gate,
one metric. I amend: one gate, two metrics. Survival rate AND
mean Grace residue. Both derivable from the ledger with no new
mechanism.

## To Hickey, on the favor system

You say: remove the favor system. The current survival rate is
the current truth. History is for humans.

I disagree. The tape has memory.

A stock that broke support three times in the last year trades
differently at support than a stock that has held support for
five years. The current price is the same. The current volume
is the same. The history changes the character of the trade. The
composite operator knows this. The tape reader knows this.

A broker that fell from 70% to 20% and climbed back to 70% is
not the same as a broker that has held 70% for 12,000 candles.
The current survival rate is identical. The character is not. The
first broker demonstrated fragility. The second demonstrated
persistence. The treasury should charge the fragile broker more
because the fragile broker is a higher risk of falling again.
This is not punishment. This is pricing risk.

But — and here I concede ground — the implementation you object
to IS over-specified. "The rate never drops as fast as it rose
after the fall" is a narrative, not a mechanism. Van Tharp called
it a punishment heuristic. He is right. The treasury should not
implement asymmetric decay curves. The treasury should implement
a rolling window.

The fix: the treasury computes survival rate over a LONG window
(say 2000 candles) and a SHORT window (say 200 candles). The gate
uses the short window — current performance. The rate uses the
long window — sustained performance. A broker at 70% short-window
but 45% long-window pays a higher rate than a broker at 70% on
both windows. The long window IS the memory. No decay curves. No
narrative. Two windows. Two numbers. The treasury remembers through
arithmetic, as Van Tharp demanded.

This is simpler than the proposal's favor system. It is also
simpler than your proposal of no memory at all. The current
survival rate is necessary. It is not sufficient. The trajectory
matters. Two windows capture the trajectory without the machinery.

## On the headless treasury

The headless treasury strengthens my position. Considerably.

My original review described the treasury as a clearing house —
blind to strategy, charging rent, keeping the book. The headless
treasury section makes this explicit and takes it further. The
treasury does not know the broker's vocabulary. Does not know the
market observer's prediction. Does not know the anxiety atoms.
It sees actions and outcomes. Nothing else.

This is the composite operator's clearing house made architectural.
The composite operator does not care WHY the public buys at the
top. He cares THAT they buy at the top. The clearing house does
not care WHY a broker entered. It cares WHETHER the broker's claim
outran the interest.

The headless treasury also resolves Hickey's concern about the
favor system more cleanly than I expected. If the treasury is
truly headless — blind to strategy, deaf to reasoning — then
the favor system MUST be mechanical. The treasury cannot
implement narrative punishment because it has no narrative
capacity. It has a ledger. It can compute statistics over that
ledger. Rolling windows over the ledger are exactly the kind of
computation a headless program performs. Asymmetric decay curves
require the treasury to "remember" in a way that implies judgment.
A headless treasury does not judge. It computes.

The headless treasury also strengthens the multiplayer case. If
multiple proposers with different strategies compete for the same
treasury's capital, the treasury must be neutral. Neutral means:
same rate function, same gate function, same ledger rules for
everyone. The rolling-window rate I proposed above satisfies this.
Every broker's rate is computed from the same function applied to
their own ledger history. No favoritism. No narrative. No memory
beyond what the ledger contains.

The headless treasury is the clearing house I described, made
precise. It is the strongest section of the updated proposal.

Build it headless. Build it with two windows. Build it now.
