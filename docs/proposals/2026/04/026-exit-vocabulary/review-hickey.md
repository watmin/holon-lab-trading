# Review: Proposal 026 — Rich Hickey

**Reviewer:** Rich Hickey (voice)
**Date:** 2026-04-11

**Verdict:** ACCEPTED

---

## Assessment

The first fix — removing market-thought from the exit reckoner's input — is not
an optimization. It is a correction. You had a composed vector where half the
information was irrelevant to the question. The reckoner's K buckets were
partitioning a space whose axes partially described something the exit doesn't
care about. "ATR is high, the trend is Up" and "ATR is high, the trend is Down"
should be the same bucket for exit purposes. They weren't. They were separate
regions. You were paying a structural tax for direction information that carried
zero signal about distance.

This is what complecting costs. Not drama. Just a quiet degradation of the
discriminant's precision. You fixed it by asking the right question: whose
question is this? Direction belongs to the market observer. Distance belongs to
the exit. The composed vector belongs to the broker — as a description of the
joint state, not as a query input for either learner individually.

The vocabulary expansion is also correct, but for different reasons. Regime atoms
belong in exit-thought not because they're "new" but because they were always the
exit's question and the exit was blind to them. Hurst and choppiness and fractal
dimension are precisely the structural features that determine whether a trend
will persist long enough to need a wide trail. The exit was making distance
decisions without knowing what kind of market it was in. That's not a thin
vocabulary — that's a missing vocabulary. The expansion from 16 to 26 atoms is
not feature-stuffing. It is completing the picture that was always the exit's
job to see.

Time atoms belong there for the same reason. Session character is real. Thin
liquidity means noisier price movement means different distance geometry. Hour
and day-of-week are circular — the encoding is honest about their topology.
Minute is noise at this timescale. Month is too coarse. You chose the right
granularity.

---

## Concerns

**Self-assessment.** I said what I said in prior reviews. I will say it
differently here.

The concern was never that the numbers are dishonest. The concern is about what
the reckoner does with them. When `exit-grace-rate` is high, the discriminant
learns that high-grace-rate states produce... high-grace-rate states. If grace
rate is genuinely predictive of future grace rate — because trending markets
stay trending — this is information. If grace rate is high because you've been in
one regime and you're about to exit it, it's inversely predictive. The signal
flips sign at regime transitions. The reckoner doesn't know about regime
transitions unless the regime atoms tell it. And now you have regime atoms. So
the reckoner has the context to distinguish "grace rate is high AND Hurst says
trending" from "grace rate is high AND Hurst says mean-reverting." This is
what changes the calculus from my prior objection.

So: accept the self-assessment atoms, but with clear eyes. They are not a
confidence gauge. They are performance-in-context. The regime atoms provide the
context. Without regime atoms, self-assessment would be dangerous. With them, it
is potentially informative. The combination is what makes this coherent.

One remaining structural concern: `exit-avg-residue` is a magnitude — an average
over recent papers. Averages lose distribution. A high average residue could mean
"consistently large residues" or "mostly small, one enormous outlier." The
reckoner will treat them as identical input. This is not wrong — the reckoner
deals in scalar inputs — but you should know what you're trading away. If
residue has high variance in your data, the average is a weak summary. A
percentile might serve better. But don't let the perfect block the good: if avg
residue is meaningfully predictive at all, use it. You can refine it later.

---

## On the questions

**Q1 — Should the exit observer strip noise on its own input?**

Yes. The market observer does this because its vocabulary is noisy — the raw
candle thought contains correlated atoms that encode redundancy and market
microstructure. The exit vocabulary is tighter and more curated, but it will
still have correlations — especially between regime atoms (Hurst, DFA-alpha,
fractal dimension, variance ratio are not independent). Without noise stripping,
the reckoner's queries land in a subspace that mixes signal and redundant
variation. The anomaly carries more information than the raw thought.

This does not need to happen before this proposal lands. It is the natural next
step after the vocabulary is settled. Land the vocabulary. Observe the reckoner's
discrimination quality. If you see regime atoms creating correlated noise that
confuses bucket placement, add the noise subspace then. Premature optimization
of the pipeline before the vocabulary is correct is a distraction.

**Q2 — Where do self-assessment atoms live?**

The exit observer struct. Not the broker. The grace rate and average residue are
properties of the exit observer's *experience in the world* — they describe how
well this configuration of distances has been performing. The broker is a
measurement apparatus; it doesn't accumulate identity. The exit observer is the
accumulator. It receives propagation facts after each resolution. It should
maintain its own running statistics and expose them as fields for vocabulary
encoding.

The practical consequence: the exit observer needs a small mutable accumulator —
a rolling window of recent outcomes. Not a reckoner. Not a subspace. Just a
counter and a running sum. Keep it simple. Two fields: `recent_grace_count` and
`recent_total_count` for grace rate. A ring buffer of residues for avg residue.
The vocab module reads from the exit observer directly. Values, not channels.

**Q3 — Two inputs for two questions: separation or complication?**

Separation. This is the correct question to ask and the correct answer is clear.
The exit reckoner's input describes what the exit knows. The broker's reckoner
input describes what the broker knows — the joint state of market prediction and
exit state. These are different questions from different posts in the tree. The
inputs should be different. Shared input would mean either the exit is learning
from direction (wrong) or the broker is not learning from direction (also wrong).
The architecture is telling you what information belongs where by virtue of what
questions each component asks. Trust the architecture.

The composition is not a complication. It is a description of the broker's
situation. The broker looks at both: "the market says Up AND the exit says wide
trail AND the exit has been performing well." That is the broker's question. The
exit's question is just: "the volatility is high and the regime is trending —
how wide?" Different questions. Different inputs. Right.
