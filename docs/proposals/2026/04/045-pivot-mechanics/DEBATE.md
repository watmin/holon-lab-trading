# Debate: Proposal 045 — Pivot Mechanics

Five voices reviewed. Five CONDITIONAL. Three tensions remain.

## Tension 1: Who owns pivot detection?

- **Seykota:** Exit observer. The threshold is learned per
  observer. Two exits paired with the same market observer may
  see different pivots. Significance is learned, not given.

- **Van Tharp:** Exit observer. A separate component forces a
  single pivot signal across all exits, destroying per-exit
  sensitivity.

- **Hickey:** Separate component (PivotClassifier on the post).
  The exit observer is accumulating three concerns — distance
  prediction, market structure classification, sequential
  encoding. They change for different reasons. Complecting.

- **Wyckoff:** Post. Market structure is an asset-level concern.
  The tape reader is a specific skill. Every broker sees the
  same market structure. One detection, shared by all.

- **Beckman:** Post. One PivotTracker per market observer at
  the fan-out point. M copies on the exit is redundant
  computation of the same transducer on the same input stream.

The split: 2 (exit) vs 3 (post/separate).

Seykota's argument: per-exit learned thresholds produce
different pivot signals from the same conviction stream.
That diversity matters.

Hickey/Wyckoff/Beckman's counter: market structure IS one
thing. One tape. One reading. The exit observer receives
the classification and decides what to DO with it — that's
where the diversity lives.

Can Seykota's per-exit sensitivity survive on the post?
Could the post produce raw pivot records and each exit
apply its own threshold to decide which pivots MATTER to it?

## Tension 2: Conviction window — 200 or 500?

- **Seykota:** 500. Tie to recalibration interval.
- **Van Tharp:** 200. 500 straddles regimes and is sticky.
  200 gives statistical stability with regime responsiveness.
- **Wyckoff:** 500. Covers one full Wyckoff sub-phase.

The split: 2 (500) vs 1 (200).

Van Tharp's argument: standard error of 2.8% on the 80th
percentile at N=200 is sufficient. Above 300 is sticky.

Seykota/Wyckoff's argument: 500 matches the recalibration
rhythm and covers a full market phase.

## Tension 3: Gap minimum duration — 0 or 3 candles?

- **Seykota:** 3 candles. Single candle below threshold is
  noise. Retroactively start the gap from the first drop.

- **Van Tharp:** 0 (none). Single-candle gaps are information.
  The Sequential encoding handles flickering naturally. If
  flickering is a problem, raise the percentile.

- **Wyckoff:** 3 candles. Prevents flickering without losing
  real pauses.

The split: 2 (debounce 3) vs 1 (no debounce).

## For the debaters

You have read each other's reviews. Respond to the three
tensions. Where do you concede? Where do you hold? Arrive
at ONE recommendation per tension.
