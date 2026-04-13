# Review: Wyckoff / Verdict: CONDITIONAL

Conditional on one clarification. Option A is correct, but the
framing around the significance filter needs tightening.

## Question 1: Full history or recent records?

The exit does not need the full pivot history.

A tape reader does not hand the trader a transcript of every
print since the market opened. He hands the trader a reading:
the current condition and the recent pivots that define it. The
trader acts on the reading, not the tape.

The PivotTracker maintains its own full state. That is the tape.
What flows on the chain is the reading -- a bounded slice of
recent completed periods plus the current period. Twenty records
is generous. Ten would suffice for any Sequential count worth
acting on.

The exit observer receives a reading, not a tape. It has no
business maintaining history. History is the post's concern.

## Question 2: Stateless or stateful?

The significance filter is stateless. It must be.

A pivot is significant or it is not. The determination comes from
the record itself: duration, volume, conviction magnitude. These
are properties of the completed period. They do not depend on
what the filter saw yesterday.

If you make the filter stateful -- if it "learns" a threshold
over time -- you have created a second detection mechanism
disguised as an interpretation step. The 045 resolution said
the post detects. A stateful filter on the exit side is detection
by another name.

The filter is a pure function: PivotRecord -> bool. It asks: was
this pivot long enough, loud enough, convicted enough to matter?
That is a fixed threshold or a set of thresholds derived from the
record's own fields. No memory required.

If you later discover you need adaptive thresholds, those
thresholds are a property of the POST's tracker configuration,
not the exit's filter. The post tunes what counts as a pivot.
The exit reads what the post declared.

## The verdict: Option A

Option A is the correct architecture. Here is why, through the
tape reader's lens:

The tape reader (the post) reads the tape. Between receiving the
raw prints (market observer convictions) and passing the reading
to the traders (exit observers), the tape reader updates his
notes and attaches the relevant summary.

This is step 2.5 in the proposal. The main thread updates the
PivotTrackers, extracts recent records, attaches them to the
chain. The chain is the reading that travels to the trader.

Option B creates a separate messenger who runs alongside the
reading. Two messages arrive at the trader's desk about the same
moment in the market. He must match them. This is complexity
without purpose. The reading and the pivot state describe the
same candle. They belong together.

Option C puts a second tape reader on the trading floor. He
reads the same tape, makes the same marks, reaches the same
conclusions. Beckman was right to flag this as redundant Mealy
machines. Two readers of one tape is a factoring error. The
post is the reader. There is one reader.

## The condition

The proposal says the chain carries `Vec<PivotRecord>`. Clarify
the bound. The chain should carry a fixed-capacity slice, not a
growable Vec. If the tracker maintains 500 rolling values
internally, the chain must not leak that. Declare the window:
the last N completed periods, where N is a constant (10 or 20).
The exit never asks for more. The chain never carries more.

This is the difference between attaching a reading and attaching
a tape. Option A is correct only if the chain carries a reading.

## On question 5 from the proposal

> "Option A has the post detecting AND attaching."

This is not a violation of 045. Attaching is not detecting.
The post detected when it ran the tracker. Attaching the result
to the chain is routing -- the same thing the main thread already
does when it routes market predictions to exit observers. The
main thread is the orchestrator. Routing is its job.

The exit interprets what arrives. It runs the significance filter.
It builds the Sequential thought. It decides which pivots matter
for THIS trade's exit timing. That is interpretation.

Detection lives in the tracker. Interpretation lives in the exit.
The chain is the wire between them. Option A keeps the wire clean.
