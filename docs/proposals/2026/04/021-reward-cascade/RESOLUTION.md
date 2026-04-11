# Resolution: Proposal 021 — The Reward Cascade

**Date:** 2026-04-11
**Decision:** ACCEPTED with refinements from designers + ignorant

## Refinements from review

1. **Hickey:** `buy_signaled` extracted from PaperEntry — observation
   bookkeeping doesn't belong on the trading value. Track on the broker
   or a signal struct.

2. **Beckman:** Noise subspace (Theory 3) is orthogonal and unaddressed.
   Fix the label path (this proposal) AND the input path (separately).

3. **Ignorant:** Both sides crossing produces contradictory labels.
   **Resolved:** only the FIRST side to trigger counts. The other half
   is dead. One direction per paper.

4. **Ignorant:** Bootstrap/feedback loop concern.
   **Resolved:** the feedback is self-correcting. Exit learns from
   runners weighted by residue. Tiny residue = tiny weight. The
   learning pressure pushes distances toward large residue, not toward
   zero. Virtuous cycle, not death spiral.

## Superseded by Proposal 022

The cascade design is correct but the paper mechanics need updating
to support it. Proposal 022 specifies the paper lifecycle with
fixed stop loss + trail confirmation + runner transition.
