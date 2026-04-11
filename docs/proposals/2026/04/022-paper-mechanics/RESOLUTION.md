# Resolution: Proposal 022 — Paper Mechanics

**Date:** 2026-04-11
**Decision:** ACCEPTED — implement

## Designers

Both accepted. Beckman: drop the opposite side, two triggers only.
Beckman: add timeout as Silence (zero weight). Beckman: conviction
must NOT influence distances.

## Ignorant concerns — resolved

1. **Directional blindness:** the market MUST make a choice. It will
   be judged. The prediction balance is a diagnostic, not a gate.
2. **Intra-candle OHLC:** use close as proxy for current. Paper
   remembers entry close. Triggers compare against current close.
3. **Paper accumulation:** papers have organic expiry. They either
   become runners (and resolve) or hit stops (and die). Most are
   not runners. Self-managing.
4. **Death spiral:** deferred. Not observed in practice yet.
5. **Paper expiry:** organic — stop or trail fires.

## Implementation

The paper is simplified: one prediction, two triggers (trail + stop
for the predicted direction only), close as entry price. The market
observer's thought and prediction are stored. First trigger to fire
determines the outcome. Runner transitions to exit management.
