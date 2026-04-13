# Resolution: Proposal 045 — Pivot Mechanics

**Decision: APPROVED. All five converged after debate.**

## Ownership — unanimous after debate

Post detects. Exit interprets. Hickey found the synthesis:
split detection from significance.

The post holds one PivotTracker per market observer — a map
of 11 trackers, one per lens. Each tracker runs the state
machine on its market observer's conviction stream. Each
tracker produces raw PivotRecords.

Each exit observer receives its paired market observer's
pivot records through the chain. Each exit applies its own
learned significance filter — which pivots enter ITS memory,
which shape ITS Sequential thought.

One tape. Many readers. The diversity is in the interpretation,
not the detection.

## Conviction threshold — unanimous

80th percentile of a rolling window. Adaptive. Breathes with
the market. Start at 80, learnable over time.

## Conviction window — 4 to 1

N=500. Matches the recalibration interval. Covers one full
market phase. Van Tharp conceded (phase alignment argument).

## Direction change — unanimous

Direction change during high conviction forces a new pivot
period. All five agreed. A spring (false breakdown then
reversal) is two events, not one.

## Gap debounce — split resolved by Hickey

3-candle debounce at the post level. The post emits structural
events, not measurement noise. The exit's significance filter
provides a second layer — the exit can further filter what
enters its bounded memory.

Van Tharp's "keep the raw record honest" argument is valid but
the bounded 20-entry memory makes debounce a practical
necessity at the shared layer. 3 candles = 15 minutes. Any
real pause lasts at least that.

## RollingPercentile — extracted

Shared primitive. Same construction as journey grading (043).
One implementation, two instantiations. Hickey and Beckman
both required this.

## What 045 resolved

- Who detects: the post (one tracker per market observer)
- Who interprets: the exit (significance filter per observer)
- Threshold: 80th percentile, rolling, N=500
- Direction: change forces new period
- Debounce: 3 candles at post level
- State machine: pivot/gap alternation with running stats
- RollingPercentile: shared primitive

## What 045 spawned

**Proposal 046** — the pipe architecture. How do the
PivotTrackers on the post serve their records to the exit
observers through the chain? Who holds the data, who reads
it, how do we prevent contentious reads and writes? The
ownership is resolved. The plumbing is not.
