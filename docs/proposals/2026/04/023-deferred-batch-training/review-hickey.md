# Review — Proposal 023

**Reviewer:** Rich Hickey (simulated)
**Date:** 2026-04-10

## 1. Is the accumulation simple or hidden complexity?

The accumulation itself is simple — append a tuple per candle, drain on
closure. That's a log. Logs are good. But the proposal hides a coupling:
RunnerHistory only exists during the "runner phase," which means the
broker must now track a lifecycle state it didn't have before. Today
a paper is a paper. Tomorrow a paper is a paper that might become a
runner that accumulates history. That's a state machine wearing a
struct's clothing.

The accumulation is simple. The conditional allocation ("only when
signaled") is where the complexity lives. If every paper accumulated,
you'd have simplicity at the cost of memory. If only runners accumulate,
you have a mode — and modes are a form of complecting.

## 2. Is RunnerHistory in the right place?

No. The proposal puts it on PaperEntry. But PaperEntry is a value — it
tracks extremes and trail stops. RunnerHistory is a growing collection
of observations about a learning process. These are different concerns.

The broker already owns the paper. The broker already owns scalar
accumulators. RunnerHistory is the broker's learning material about
its exit observer — it belongs on the broker, keyed by whichever paper
is in runner phase. One optional field: `active_history: Option<RunnerHistory>`.
The paper stays a value. The broker stays the accountability unit.

## 3. Is batch-at-closure the right drain point?

Yes. This is the strongest part of the proposal. You cannot grade
predictions against hindsight until you have the hindsight. The drain
point is forced by information availability, not by design preference.
That's the best kind of constraint — reality chose it for you.

The O(n^2) concern from question 2 in the proposal is real but
solvable: compute optimal distances in a single backward pass over
the price history. O(n), not O(n^2). The suffix-maximum gives you
the answer.

## 4. Verdict

**Accept with one structural change:** RunnerHistory belongs on the
broker, not on PaperEntry. The paper is a hypothesis. The history is
accountability material. Keep them separate.

The three learning rates are not invented — they fall out of when
information becomes available. That's a good sign. The design is
discovered, not constructed.
