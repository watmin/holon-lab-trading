# Debate: Beckman

## Tension 1: Who owns pivot detection?

Seykota's argument is precise: per-exit learned thresholds produce
different pivot signals from the same conviction stream. Two exits
paired with the same market observer may disagree about whether a
candle is a pivot. That diversity matters. I take the argument
seriously. Let me show why it does not change the factoring.

### The diagram

Start from what everyone agrees on. The pivot transducer is a
Mealy machine:

```
PivotDetect : Stream<(conviction, direction, candle)> --> Stream<PivotRecord>
```

The input comes entirely from the market observer's output. The
question is where this transducer lives and whether the threshold
parameter changes the answer.

### Separating detection from interpretation

Seykota says: the threshold is learned per exit, so the detection
must live per exit. Van Tharp agrees. But this conflates two
operations:

1. **Detection:** Given a conviction value and a threshold, emit
   a PivotRecord when the state machine transitions. This is a
   pure function of the conviction stream and the threshold
   parameter. It maintains the rolling window, the current period,
   the state transitions.

2. **Interpretation:** Given a PivotRecord, decide what it means
   for THIS exit's distances, THIS exit's trade biography, THIS
   exit's sequential encoding.

Detection is parameterized. Interpretation is contextualized.
These are categorically different. Detection takes a number and
produces a classification. Interpretation takes a classification
and produces action. They compose:

```
Interpret_j . Detect_θ : Stream<conviction> --> Stream<Action_j>
```

Seykota's concern is that θ differs per exit. Granted. But that
does not mean the detection MACHINERY must be duplicated. It means
the detection must be parameterized by θ. The question becomes:
can the Post run N parameterized detectors without becoming the
exit observer?

### The Post as parameterized fan-out

In my original review, I proposed one PivotTracker per market
observer. Seykota correctly objects: if exit observers have
different thresholds, one tracker per market observer is
insufficient. But the fix is not to move detection back to the
exit. The fix is to parameterize the Post's detection.

Consider the data flow. The Post already fans out each market
observer's output to M exit observers. Today:

```
MarketObs[i] --> Post fans out --> ExitObs[j] for j in 1..M
```

With pivot detection, there are two clean options:

**Option A: One detector, raw records.** The Post runs one
PivotTracker per market observer with a FIXED threshold (the
80th percentile bootstrap). It emits raw PivotRecords -- every
transition, unfiltered. Each exit observer receives the raw
stream and applies its own learned filter. The exit does not
re-detect. It filters.

```
MarketObs[i] --> Post.PivotTracker[i] --> Stream<PivotRecord>
                                              |
                    +-------------------------+-------------------------+
                    |                         |                         |
              ExitObs[1]                ExitObs[2]                ExitObs[M]
              filter(θ_1)               filter(θ_2)               filter(θ_M)
```

The PivotRecord carries conviction_avg, duration, volume_avg.
Each exit observer's filter is a predicate over PivotRecords:
"is this pivot significant FOR ME?" One exit might filter on
conviction_avg > its learned threshold. Another might filter on
duration > 3. The raw record is the same. The filter differs.

**Option B: M detectors on the Post.** The Post runs one
PivotTracker per (market observer, exit observer) pair. Each
tracker has the exit's learned threshold. This is N x M trackers.
Seykota gets per-exit thresholds. The Post still owns detection.

Option B is what Seykota wants but placed on the Post instead of
the exit. It works, but it has the redundancy I flagged in my
original review -- M copies of the rolling window over the same
conviction stream.

**Option A is the natural factoring.** Here is why.

The rolling window and the state machine are expensive state.
The filter is cheap -- a predicate over a completed PivotRecord.
Option A puts the expensive state in one place (one per market
observer) and the cheap state in M places (one predicate per
exit). The diagram factors through the minimal shared computation.

Does the diagram commute? Let me check.

The Post's PivotTracker sees every transition at the 80th
percentile (the bootstrap). It emits records for ALL transitions.
An exit with a HIGHER learned threshold (say 90th percentile)
would receive these records and filter: "I only care about
pivots where conviction_avg exceeds my threshold." It sees fewer
pivots. An exit with a LOWER threshold (say 70th) would... wait.

Here is the problem. If the Post's tracker uses the 80th
percentile, it only detects transitions at that level. An exit
that wants the 70th percentile would miss transitions that the
Post's tracker classified as gap-continuation. The Post's
threshold is a FLOOR. Exits can raise it (filter more strictly)
but cannot lower it (detect what the Post missed).

This is a real constraint. But I argue it is the RIGHT constraint.

The 80th percentile is the bootstrap. It is generous -- one
candle in five is a pivot. Any exit that wants FEWER pivots
(higher threshold) filters naturally. Any exit that wants MORE
pivots (lower threshold) is asking for something unusual -- it
is saying "I consider one candle in three significant." That is
not a pivot. That is noise with a name. Wyckoff said the same
thing: 80th is already too generous for his Wyckoff phases.

The Post's tracker at the 80th percentile produces the maximal
set of candidate pivots. Each exit observer filters to its own
sensitivity. The filter is a learned predicate, not a re-detection.
This is the natural factoring: one generous detector, M selective
consumers.

### Why this answers Seykota

Seykota's diversity is preserved. Two exits DO see different
pivots. One filters at conviction_avg > 0.08. The other at
conviction_avg > 0.12. Same raw PivotRecords from the Post.
Different filtered views. Different biographies. Different
sequential encodings. The diversity lives in the filter, not
in the detector.

What Seykota loses: an exit cannot detect pivots that the Post
missed. But the Post is generous (80th percentile). If an exit
needs a 70th percentile sensitivity, the Post's threshold can
be lowered -- it is one parameter on one component, not a
per-exit decision. The floor is tunable.

What Seykota gains: no redundant rolling windows. No redundant
state machines. No M copies of the same percentile computation
over the same conviction stream. The detection is shared. The
interpretation is distributed.

### Van Tharp's objection

Van Tharp says a separate component "destroys per-exit
sensitivity." Not so. The separate component produces raw
records. The exit filters them. Per-exit sensitivity survives
in the filter, which is lighter, cheaper, and independently
learnable. Van Tharp's objection assumes a shared detector
produces a shared classification. But a shared detector that
produces raw records and lets consumers filter is not shared
classification. It is shared observation with distributed
judgment.

This is the distinction between a news wire and an editorial.
The wire reports every event. Each editor decides what matters
to their audience. The wire does not destroy editorial diversity.
It enables it by providing a common factual basis.

### The commuting diagram

```
                    Candle
                      |
                      v
                  MarketObs[i]
                      |
                      v
              (Vector, Prediction, conviction)
                      |
                      v
              Post.PivotTracker[i]     (one per market obs, 80th percentile)
                      |
                      v
              Stream<PivotRecord>      (raw, unfiltered)
                      |
          +-----------+-----------+
          |           |           |
          v           v           v
      ExitObs[1]  ExitObs[2]  ExitObs[M]
      filter(θ₁)  filter(θ₂)  filter(θ_M)
          |           |           |
          v           v           v
      Distances   Distances   Distances
```

The diagram commutes. Each path from Candle to Distances
passes through exactly one PivotTracker and exactly one
filter. No redundant computation. No sideways information
flow. The detection factors through the Post. The
interpretation factors through the exit.

### My recommendation for Tension 1

**The Post detects. The exit filters.**

One PivotTracker per market observer on the Post. The tracker
uses the 80th percentile (the generous bootstrap). It emits
raw PivotRecords on every transition. Each exit observer
maintains:

- `pivot_memory: VecDeque<PivotRecord>` — bounded at 20, fed
  from the Post's stream AFTER the exit's filter
- A learned filter predicate (threshold over conviction_avg,
  or duration, or both)

The exit does NOT maintain:
- `conviction_history` — the Post owns this
- `current_period` — the Post owns this

The filter is the exit's learned sensitivity. The detection is
shared infrastructure. Seykota's diversity survives. Hickey's
separation of concerns survives. Wyckoff's one-tape-one-reading
survives. The diagram commutes.

## Tension 2: Conviction window — 200 or 500?

I defer to the domain experts on the timescale question. But
from a structural perspective: the RollingPercentile is
parameterized by window size. If the Post owns detection, the
window size is one parameter on one component. Not a per-exit
decision. This makes the 200-vs-500 debate a tunable, not a
commitment. Ship at 500 (matching recalibration, as Seykota
argues). Measure. Adjust. The type does not care.

## Tension 3: Gap minimum duration — 0 or 3 candles?

The Post-owns-detection factoring clarifies this. If the Post
uses a 3-candle debounce (Seykota/Wyckoff), the raw
PivotRecords already exclude single-candle flicker. Each exit
receives clean records. No exit needs to re-debounce.

If the Post uses 0 debounce (Van Tharp), the raw records include
single-candle gaps. Each exit's filter can ignore them — filter
on duration > 3 if it wants debouncing. This is more general.
But it fills the Post's own pivot memory with noise entries,
which costs bounded memory slots.

I lean toward 3-candle debounce at the Post level. The debounce
is cheap (three candles of tentative state). The benefit is
shared — all exits receive clean records. An exit that genuinely
wants single-candle gap information can read conviction directly
from the chain. But the pivot memory — the structured sequence —
should contain structural events, not measurement noise.

**3 candles. At the Post. Shared benefit, no per-exit cost.**
