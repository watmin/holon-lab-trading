# Review — Proposal 021: The Reward Cascade

**Reviewer:** Rich Hickey (simulated)
**Date:** 2026-04-10

---

## 1. Is the complecting resolved?

Mostly. The market observer no longer learns from paper *resolution* — it learns
from excursion crossing the trail. That is a real improvement. But "excursion >
trail distance" still uses the exit observer's trail parameter as the threshold
for market truth. The market observer's reward is gated by the exit observer's
opinion of what constitutes a tradeable move.

This is not contamination. It is an *interface*. The trail distance is a
contract: "this far counts." The market observer doesn't know what the trail
distance is or where it came from. It only knows: excursion crossed, or it
didn't. That is an honest threshold — a value, not a mechanism. The complecting
from 017 was that the *same label* served two masters. Here each learner gets
its own label from its own event. The shared threshold is coordination, not
coupling.

## 2. Exit observer learning only from runners

This is correct and it is the strongest part of the proposal. An exit observer
that learns from failures would learn "don't set distances at all" — the wrong
lesson. The exit observer's job is to manage *winners*. If most papers fail, the
exit observer learns slowly. That is honest. It reflects reality: there is less
signal about optimal management when the market gives you nothing to manage.

The risk: a cold-start problem where the exit observer has too few samples to
form a useful reckoner. But that is a deployment concern, not an architectural
one. The separation is right. A slow learner is better than a confused one.

## 3. Three signal paths — simple or braided?

Three signal paths from one tick is not three concerns braided together. It is
one lifecycle emitting three independent events. The paper is the *subject*. The
events are *derived values* — each extracted by a different predicate at a
different moment. No event depends on the others. No ordering between them
(Event 1 and Event 3 can fire on the same tick for the losing side).

This is simple. One thing happens (price moves). Three observers each ask their
own question. The paper is a value that flows through predicates. The predicates
don't know about each other.

## 4. The `buy_signaled` flag

State in the wrong place. `buy_signaled` is learning bookkeeping — "have I
already sent this event?" — living on a trading data structure. The paper should
be a value describing market reality (entry, extremes, stops, resolved). Whether
the system has *reacted* to that reality is a separate concern.

Move it to the broker or to a separate signal-tracking structure. The paper
should not know it is being observed.

## Verdict

This proposal resolves the core complecting from 017. Three learners, three
moments, three questions — that is genuine separation of concerns. The shared
trail threshold is coordination, not coupling. The exit-learns-only-from-runners
constraint is the right kind of selective pressure.

One flaw: `buy_signaled` / `sell_signaled` on PaperEntry. Extract it. The paper
is a value. Don't make it remember who looked at it.

**Recommendation:** Accept with the signaled-flag extraction.
