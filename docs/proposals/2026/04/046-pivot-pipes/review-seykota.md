# Review: Seykota / Verdict: APPROVED (Option A)

I approved 045 with a concession: the post detects, the exit
interprets. Now I answer the two questions, and I pick the pipe.

---

## Question 1: Does the exit need full pivot history or just recent records?

Just the recent records. The exit observer maintains a bounded
20-entry memory. That is not a limitation — that is the design.
The exit does not run regressions over 500 pivots. The exit
looks at the recent sequence of pivot and gap periods and asks:
what is the rhythm right now? How long are the moves? How long
are the pauses? Is this market stretching or compressing?

Twenty records is roughly 20 alternating pivot/gap periods —
that covers the last several days of structural behavior at
5-minute resolution. That is enough context for a trailing stop
or a take-profit distance. The exit is not a historian. The exit
is a tactician reading the current tape.

The chain carrying a bounded slice of recent records is correct.
The exit does not need the full history. The tracker on the post
holds the full rolling state. The chain delivers a window.

---

## Question 2: Is the exit's significance filter stateless or stateful?

Stateless. Here is why.

In my 045 debate I conceded that per-exit sensitivity survives
through the reckoner, not through per-exit detection. The
reckoner IS the stateful learner. The reckoner learns which
pivots predict profitable distances. That learning lives in the
reckoner's subspace and the curve — not in a separate
significance filter with its own state.

The exit's "filter" is a pure function: given this PivotRecord,
does its duration and conviction exceed a threshold? That
threshold comes from the record itself (it already contains
the close-avg conviction relative to the rolling percentile)
and from the exit observer's learned style (the curve). There
is no accumulator, no rolling window, no hidden state in the
filter. The statefulness lives where it already lives — in the
reckoner and the curve. The filter is a gate, not a learner.

If the filter were stateful — if it maintained its own rolling
statistics over pivot records — that would be a second learning
mechanism competing with the reckoner. Two learners on the same
signal is a factoring error. Beckman taught me that in 045.
One learner per concern. The reckoner learns what matters. The
filter applies what the reckoner learned.

Stateless filter means Option A works without qualification.
The exit receives the records on the chain, applies a pure
function, and feeds the survivors into its Sequential thought.
No persistent pivot state needed on the exit thread.

---

## The pick: Option A

Option A. Not close.

**Option B is over-engineering.** Twenty-two new channels to
deliver 2KB of data that already has a carrier. The join
problem alone kills it — synchronizing pivot updates with
market chains across separate pipes creates exactly the kind
of temporal coupling that the bounded(1) channels were designed
to prevent. Two pipes that must arrive together are one pipe
pretending to be two. The proposal itself identifies this. I
agree with the proposal's own analysis.

**Option C violates 045.** We just spent an entire debate
resolving that the post detects and the exit interprets. Option
C puts detection back on the exit thread. It produces M
identical Mealy machines consuming the same conviction stream.
Beckman called this a factoring error in 045. It is still a
factoring error in 046. The fact that it "requires no changes
to the chain" is not a virtue — it requires duplicating the
state machine, which is worse. The cheapest change is the one
you do not make. The cheapest state machine is the one you do
not duplicate.

**Option A follows the existing pattern.** The chain already
carries conviction, direction, the candle, the market thought.
Adding pivot records is the same pattern — values flow through
the chain. The main thread is the orchestrator. It updates the
trackers between step 2 and step 3, enriches the chain, and
sends it. No new synchronization. No new threads. No new
failure modes. The bounded(1) channel carries a slightly larger
message. 22KB per candle is noise.

The main thread doing a PivotTracker tick between steps 2 and
3 is cheap. A percentile lookup and a state transition. This
is not a bottleneck. The bottleneck is encoding — always has
been. Adding 11 tracker ticks to the main thread's sequential
phase is microseconds against milliseconds of parallel encoding.

Option A is the simplest pipe that works. It carries the data
on the carrier that already exists. It matches the 045
resolution: the post detects (tracker on the main thread,
updated between steps), the exit interprets (reads the records
from the chain, applies its stateless filter). One tape. One
pipe. Many readers.

The simplest system is the one with the fewest moving parts.
Option A adds zero moving parts. It widens an existing pipe.
That is the right answer.
