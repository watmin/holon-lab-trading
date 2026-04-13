# Review: Seykota / Verdict: CONDITIONAL

Conditional on resolving the direction change question (Q3) and
the ownership question before implementation begins. The rest is
sound mechanics.

---

## Q1: The 80th percentile threshold

Wrong question. The right question is: what does the market tell
you the threshold should be?

The 80th percentile is a reasonable starting point. But it must
be discovered per observer, not fixed globally. Here is why.

A momentum observer fires with high conviction on strong moves.
Its 80th percentile is a high bar. A structure observer fires
on subtle shifts in pivot relationships. Its 80th percentile is
a lower bar. Same percentile, different absolute conviction. The
percentile adapts — good. But the LEVEL of the percentile should
also adapt.

My suggestion: start every observer at the 80th percentile. Let
the reckoner learn whether this observer's pivots predict Grace
or Violence at that level. If the observer is too selective (misses
entries that would have been profitable), the percentile should
drop. If the observer is too noisy (enters on false pivots), it
should rise.

This is not a parameter to tune. This is a thing to LEARN. The
conviction curve already measures conviction vs accuracy. The
pivot threshold is the conviction level where the curve says
"above here, I trust you." That is the curve's job. The 80th
percentile is the bootstrap — the curve refines it.

**Start at 80th. Let the curve move it. Per observer.**

---

## Q2: The conviction window N=500

500 candles is about 42 hours. That is one market regime. Good.

The question is not "is 500 right?" The question is "what are
you measuring?" You are measuring: what does normal conviction
look like in this regime? 500 candles captures one regime. 2000
captures multiple regimes — too sticky. 100 captures noise.

500 is the right order of magnitude. I would tie it to the
market observer's recalibration interval. If the observer
recalibrates every 500 candles, then the conviction window
should match. The conviction distribution and the observer's
learned subspace are measuring the same thing — what is normal
right now. They should breathe together.

If recalibration happens at a different interval, match it.
The conviction window is not an independent parameter. It is
a shadow of the recalibration cycle.

**500 is fine. Tie it to recalibration interval.**

---

## Q3: Direction changes within a pivot

This is the critical question. The proposal sidesteps it.

A pivot where conviction stays high but direction flips is
TWO pivots. Not one. Here is why.

I track swing highs and swing lows. A swing high is a point
where the market was going UP and then goes DOWN. The
transition IS the pivot. If conviction stays high through the
transition, that means the market is pivoting HARD — so hard
that both the up move and the down move register as significant.
That is two events, not one.

If you merge them into one pivot, you lose the most important
information: the TURN. The turn is where the money is made and
lost. The runner that survived 5 pivots — it exits at the turn.
If the turn is buried inside a single pivot period, the exit
observer cannot see it happening. It sees "we are still in a
pivot" when in fact the market reversed under its feet.

A direction change within a high-conviction period MUST force
a new pivot. Close the current pivot. Open a new one with the
new direction. Even if conviction never dipped below the
threshold. The direction change is a structural break, not a
conviction break.

The state machine needs a third transition:

```
Currently in a pivot, conviction still high, direction changed
  → close pivot, record it, start new pivot with new direction
```

This is non-negotiable for trend following. The turn is the
signal. Do not hide it.

**Two pivots. Direction change forces a new period.**

---

## Q4: Gap minimum duration

A single candle below threshold is noise. Do not start a gap
for one candle.

But do not require too many candles either. In a fast market,
conviction oscillates. If you require 5 candles below threshold
to declare a gap, you will merge distinct pivots that happen
to be close together.

My suggestion: require 3 candles below threshold before
declaring a gap. This filters single-candle noise without
merging distinct moves.

The implementation: stay in "tentative gap" for 3 candles.
If conviction rises back above threshold within 3 candles,
the gap never happened — extend the current pivot. If it
stays below for 3 consecutive candles, retroactively start
the gap from the first candle that dropped below.

This is a debounce. Every mechanical system needs one. The
market does not move in clean states. It stutters. The
debounce lets the system see through the stutter.

**3 candles minimum. Debounce, not delay.**

---

## The ownership question

On a trading desk, the analyst identifies the pivots. Not the
trader. Not the risk manager. The analyst watches the market
and says "this is a swing high" or "this is a pivot low." The
trader acts on it. The risk manager sizes it. Three different
people. Three different concerns.

The proposal puts pivot detection on the exit observer. This
is wrong. The exit observer is the TRADER. The trader acts on
pivots. The trader does not identify them.

The broker is the RISK MANAGER. The broker measures
accountability. The broker does not identify pivots either.

Pivot detection is market structure analysis. It belongs on
the market observer. The market observer already produces
conviction and direction. It already knows "something is
happening." Adding "this is a pivot" is a natural extension
of that knowledge.

But — and this is important — the market observer should not
maintain the pivot history or the state machine. The market
observer's job is to CLASSIFY each candle: pivot or not,
direction, conviction. One candle at a time. Stateless.

The STATE (pivot history, current period, the sequence) belongs
on the exit observer. The exit observer maintains the biography
because it USES the biography to set distances. The broker
reads the portfolio-level summary because it USES the portfolio
shape to grade accountability.

So the answer is: SPLIT IT.

- **Market observer** classifies: "this candle is a pivot" or
  "this candle is a gap." This is a fact about the market, not
  about a trade. It flows on the chain like conviction and
  direction already do.

- **Exit observer** tracks: the state machine, the pivot memory,
  the current period, the sequence encoding. This is trade
  management state. It consumes the classification and builds
  the biography.

- **Broker** summarizes: portfolio-level biography atoms
  (active count, oldest runner, heat). Computed from the exit
  observers' pivot state. The broker reads, it does not detect.

This split respects the separation of concerns. The market
observer is the analyst. The exit observer is the trader. The
broker is the risk manager. Each does its job.

The conviction history (rolling window for the percentile
threshold) lives on the exit observer — because different exit
observers paired with the same market observer may use different
thresholds (per Q1 above). The market observer does not decide
the threshold. The exit observer decides what conviction level
constitutes a pivot FOR ITS PURPOSE.

Wait. I just contradicted myself. If the exit observer decides
the threshold, then the exit observer is doing the classification.
Not the market observer.

Let me reconsider.

The market observer produces conviction. The exit observer
decides whether that conviction constitutes a pivot. The
classification IS the exit observer's job because the threshold
is learned per exit observer. Two exit observers paired with
the same market observer may disagree on whether a candle is
a pivot. One has a higher threshold (fewer, stronger pivots).
One has a lower threshold (more frequent pivots). Both are
correct for their learned style.

**The exit observer owns everything.** The proposal is right.
I was wrong to split it. The pivot is not a fact about the
market — it is a fact about what THIS exit observer considers
significant. The significance threshold is learned, not given.
Two exit observers see different pivots from the same conviction
stream. That IS the diversity.

The exit observer is not just the trader. The exit observer is
the analyst AND the trader. It reads the market observer's
conviction, applies its own learned threshold, classifies the
pivot, tracks the state, manages the trades. One concern, not
three.

**Exit observer owns pivot detection, state, and memory.
The proposal is correct.**

---

## Summary of conditions

1. Direction change forces a new pivot (Q3). Non-negotiable.
2. Gap debounce of 3 candles (Q4). Mechanical necessity.
3. Threshold learned per observer via the conviction curve (Q1).
   Start at 80th, let it move.

The conviction window (Q2) and ownership question are already
answered correctly in the proposal. The exit observer is the
right home. 500 is the right window if it matches recalibration.

Meet these three conditions and the proposal is approved.
