# Debate: Wyckoff

I have read both positions carefully. Seykota is elegant. Van Tharp is
rigorous. Both are partially right. Here is where I land after hearing
them.

## Tension 1: Gate mechanism

**I concede to Seykota. Full rate. Always.**

My valve was clever. Too clever. Seykota is right that papers cost
nothing. A valve that throttles free observation is a mechanism without
a purpose. What am I throttling? Not capital -- capital is already gated
at the treasury. Not risk -- papers carry no risk. I was throttling
*information*, which is the one thing a learner in drawdown needs more
of, not less.

The valve made sense to me because I was thinking about market phases.
In accumulation, the composite operator watches but acts less. But the
operator is still watching at full attention. They do not close their
eyes 80% of the time because the stock is down. They watch every print.
Papers are the watching. Every candle, every broker.

Van Tharp's three-state machine (Proving, Active, Suspended) adds
formality I do not object to, but the states describe capital allocation,
not paper registration. Papers flow in all three states. The distinction
between Active and Suspended is about whether the broker proposes funded
trades. That is already what the treasury does -- it funds proven brokers
and does not fund unproven ones. Adding explicit states to the broker is
naming what already exists. I do not oppose it, but I do not require it.

Van Tharp's cold start threshold (200 minimum, 500 to declare dead) is
worth keeping as a principle, but "declaring dead" should mean "stop
allocating capital permanently," not "stop observing." If papers always
register, the question of when to declare a system dead becomes a capital
question, not a learning question. And capital questions belong to the
treasury.

**Recommendation: papers register at full rate, always. No valve. No
throttle. The gate controls funded proposals only. Van Tharp's sample
size thresholds (200 to activate EV-gating, 500 to declare truly dead)
apply to capital decisions at the treasury level, not to paper
registration.**

## Tension 2: Journey grading mechanism

**I hold on fixing volume first. But Van Tharp moves my position on
the mechanism.**

My original review said: fix the volume imbalance (per-broker grading),
then see if the EMA works. Seykota agrees -- per-broker EMA, the struct
already supports it, simple.

Van Tharp says: replace the EMA with a rolling percentile regardless.
Bounded window. Cannot collapse under volume. More honest.

Here is where Van Tharp changes my mind. Even with per-broker grading,
the EMA has a structural weakness: it never forgets. A broker that had
terrible early performance carries that ghost forever, weighted down
but never gone. In a system where brokers move through phases --
accumulation, markup, distribution, markdown -- the grading mechanism
must be phase-aware. An EMA is not. A rolling window is.

But I will not go as far as Van Tharp demands. His rolling percentile
with N=200 is a good mechanism, but the priority order matters. Step one
is per-broker grading. That is the structural fix. Step two is replacing
the EMA with a windowed mechanism. That is the statistical fix.

If you do step two without step one, you still have 4 brokers flooding
2 shared graders. The window helps but the distribution is still
poisoned. If you do step one without step two, each broker has its own
EMA that can still converge to a point estimate under high volume --
but the volume per broker is 1/22 of the total, so the convergence
problem is 22x less severe. Per-broker EMA might actually work. But
the rolling percentile is more robust and barely more complex.

**Recommendation: per-broker journey grading (step one, non-negotiable).
Replace EMA with rolling percentile of last N=200 error ratios, 50th
percentile threshold (step two, implement together if possible, defer
if necessary). Seykota's simplicity instinct is good but the EMA's
structural weakness is real. Van Tharp is right on the mechanism.
Seykota is right on the priority.**

## Tension 3: Market observer independence

**I hold. Explicit decoupling is required. Van Tharp is wrong that
papers-never-stop solves this naturally.**

Van Tharp argues that if papers always register, the market observer
always gets learn signals, so the wiring problem dissolves. This is
true for the starvation problem. It is not true for the *signal
contamination* problem.

Consider: papers always register. A broker with negative EV still
generates resolutions. The market observer learns from those
resolutions. But what does it learn? It learns whether the *trade*
succeeded -- which is a joint outcome of market prediction AND exit
quality. A market observer paired with a bad exit observer receives
a contaminated signal. The market prediction was correct (price moved
in the predicted direction), but the trade failed (the exit observer
set stops poorly). The market observer learns "my prediction was
wrong" when it was right.

This is not solved by papers-never-stop. It is solved by giving the
market observer a clean signal: did the price move in the direction
I predicted? That question is answered by the candle data alone, not
by the broker's P&L.

Seykota sees this clearly: "The market observer predicted Up and the
price went up -- that is Grace for the market observer, regardless of
whether the exit observer set a stop too tight." Different signal,
different learning path. The market observer evaluates directional
accuracy. The broker evaluates trade outcome. These are different
measurements and must have different learning paths.

Papers-never-stop keeps the wire alive. But a live wire carrying a
contaminated signal is not better than a dead wire -- it is worse,
because the observer is actively learning the wrong lesson. The
frozen observer at least preserves its 59.8% accuracy. An observer
learning from contaminated signals will degrade that accuracy.

**Recommendation: explicit decoupling. The market observer learns
from directional accuracy -- did price move in the predicted
direction over the paper's horizon? This is evaluated from candle
data, independent of the broker's P&L or the exit observer's stops.
The broker still learns from trade outcomes. Two signals, two paths.
This is not optional and it is not deferred.**

## Summary: three recommendations for the builder

1. **Papers register at full rate, always.** Gate controls funded
   proposals only. Van Tharp's sample size thresholds (200/500) govern
   capital decisions at the treasury. No valve. No throttle.

2. **Per-broker journey grading with rolling percentile.** Each broker
   maintains its own window of N=200 error ratios. Threshold at the
   50th percentile. Per-broker is the structural fix. Rolling percentile
   is the statistical fix. Both together.

3. **Market observer learning decoupled explicitly.** The market
   observer learns from directional accuracy, not trade outcome.
   Papers-never-stop keeps the wire alive but does not clean the signal.
   Both are needed.

Three changes. One new data structure (the rolling window per broker,
replacing the EMA fields that already exist). One wiring change (market
observer learns from direction, not P&L). One deletion (remove the paper
gate). No new parameters beyond the window size N=200, which Van Tharp
and I both arrived at independently.

The system can now accumulate, mark up, distribute, and mark down without
killing its participants. That was my condition. It is met.
