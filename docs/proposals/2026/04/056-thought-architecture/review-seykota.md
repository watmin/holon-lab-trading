# Review: Seykota

**Verdict: APPROVED**

---

## Can This System Follow a Trend?

Yes. And it follows the trend the way I would want a system to follow
a trend: by encoding the *progression*, not the snapshot.

The single biggest mistake I see in system design is people encoding
where the market IS. "RSI is 68." So what? The question that matters is:
was it 55, then 58, then 62, then 68? That is a trend. Was it 75, then
72, then 70, then 68? That is a dying trend. Same number. Opposite
meaning. The indicator rhythm encoding solves this correctly. The delta
IS the trend. The sequence of deltas IS the trend's character. The
trigram of value-plus-delta bundles IS one breath of the market. The
chain of trigram pairs IS the movie.

The same-phase deltas in the phase rhythm are the second correct
decision. "This valley was lower than the last valley" is the
definition of a downtrend. "This rally was weaker than the last rally"
is the definition of exhaustion. These are not rules. They are
measurements. The reckoner discovers which measurements matter. That
is the right division of labor.

## Can It Detect When a Trend Is Dying?

The exhaustion-top example answers this directly. Weakening rallies
carry negative `same-move-delta` on `phase-transition-up`. Lingering
peaks carry positive `same-duration-delta` on `phase-peak`. Strengthening
selloffs carry positive `same-volume-delta` on `phase-transition-down`.

These three signals converge in the trigrams. The reckoner does not
need a rule that says "if rallies weaken AND peaks linger AND selloffs
strengthen THEN exit." The three conditions produce a direction in
hyperspace. The reckoner has seen that direction before. It points
toward Violence. Exit.

The breakdown example is subtler and more interesting. Higher lows
(support holds) but weaker rallies (demand fading). Opposing deltas.
The proposal calls this "the squeeze" and says "low conviction." That
is honest. A system that says "I don't know" when the signals conflict
is a system I trust. The broker does nothing. Doing nothing when you
don't know is the first rule of trading.

## Does the Phase Rhythm Capture Higher Highs and Lower Lows?

Yes. The prior-same-phase deltas are precisely this measurement.
`same-move-delta` on `phase-valley` tracks whether valleys are rising
or falling. `same-move-delta` on `phase-peak` tracks whether peaks
are rising or falling. The relation is carried IN each record, not
between records. This is the key insight.

The bundle loses ordering between pairs. But the ordering lives in
the deltas. "Rally 3 was weaker than rally 2" is stated on rally 3's
record. It does not need to find rally 2 in the bundle. The
information migrated from the container to the content. That is
elegant and correct.

## Is the Hold/Exit Reckoner Honest About Cutting Losses?

The broker-observer asks one question: "Do I get out now?" It does not
ask "Should I have gotten in?" or "Where is the market going?" It asks
the exit question. That is the right question. Getting out is the
only decision that matters once you are in.

The portfolio rhythms give the broker self-awareness: how is my
unrealized P&L evolving? How is my time pressure changing? Is my
grace rate improving or deteriorating? These are not market questions.
These are "how am I doing?" questions. The broker knows its own
situation is changing. That is honesty.

The triple anomaly filtering is the mechanism that prevents denial.
Three subspaces strip three layers of "normal." What survives is
what is genuinely unusual about the full situation. The broker cannot
hide behind "the market usually does this" because the subspace
already absorbed that. What reaches the gate reckoner is the surprise.
Surprises demand decisions.

## Is It Over-Engineered?

No. Every piece earns its place. Let me count:

**The indicator rhythm function.** One generic function. Same algorithm
for every indicator, every observer. No special cases. No indicator-
specific logic. The atom name and the extractor are the only parameters.
That is minimal.

**The trigram.** Three consecutive items, internally ordered. One
full cycle. You need at least three to capture "this then that then
this" -- the minimum context for a pattern. Two is too few. Four adds
nothing the overlapping trigrams don't already provide.

**The bigram of trigrams.** "This cycle then that cycle." The transition
between patterns. You need this to see "rally-cycle then exhaustion-
cycle." Without it you have individual cycles but no progression.

**The bundle.** Sets of pairs. Each recoverable. Position-independent.
The same shape is recognizable whether it happened yesterday or
last week. This is exactly what a trend follower needs: pattern
recognition that is not anchored to a calendar.

**The noise subspace.** The proof test shows 0.96 raw cosine between
uptrend and downtrend rhythms. Without the subspace, the system
cannot distinguish regimes. With the subspace: 0.12. The subspace
is not optional. It is the difference between a system that works
and one that does not.

**The thermometer encoding.** The proposal documents that the rotation-
based scalar encoding destroys the sign of small deltas. +0.07 and
-0.07 encode identically. The sign of a delta is the direction of
change. Destroying the sign destroys the signal. The thermometer
encoding fixes this. It earns its place by making the deltas readable.

**The trim to sqrt(D).** Not hardcoded. Derived from the dimensionality.
Scales automatically. More dimensions means longer memory, no code
changes. That is the right kind of parameter.

## What I Like Most

The choppy-range example. All same-deltas near zero. The trigrams
repeat. The pairs repeat. The bundle is dense around one direction:
noise. The broker does nothing.

"Doing nothing in chop is Grace."

That is the sentence of a system designer who understands trading.
The market pays you to wait. Most systems lose money in chop because
they keep trying. This system recognizes chop as a regime and sits
still. That is worth more than any entry signal.

## What I Would Watch

The window sampler selects 12 to 2016 candles, but the trim caps the
thought at sqrt(D)+2 candles. A 560-candle window trimmed to 103
candles means the oldest 457 candles were computed and discarded.
That is waste. Not dangerous waste, but the system should eventually
learn which window lengths produce useful trim budgets and stop
over-selecting. The proposal acknowledges this. Good.

The capacity math assumes D=10,000. At D=4,096 the budget is 64.
The proposal says "tight -- the lens must be selective." I would
say: run at 10,000. Trading is not a domain where you save money
on dimensions. The information density justifies the cost.

## The Bottom Line

This is a system that encodes the structure of price action without
naming the patterns. It lets the reckoner discover what matters. It
cuts losses by detecting anomaly against its own learned normal. It
follows trends by encoding the progression of indicators and phases,
not their current values. It stays flat in chop.

The proof test is honest. Raw cosine: 0.96. After subspace: 0.12.
That is a 3.5x residual separation between uptrend and downtrend,
6.3x between uptrend and chop. Four indicators. Fifty candles. One
subspace. The full system will have more to work with.

The proposal knows what it knows and says what it does not know.
The breakdown example ends with "low conviction" and "the next phase
decides." That is not a weakness. That is the system being honest
about uncertainty. I trust systems that say "I don't know" more than
systems that always have an answer.

Win or lose, this system is asking the right questions.

-- Ed
