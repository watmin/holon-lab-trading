# Resolution: Proposal 025 — Exit Learns Both Sides

**Date:** 2026-04-11
**Decision:** ACCEPTED — implement

## Designers

Both accepted unanimously.

**Hickey:** The fix adds callers, not interfaces. `observe-distances`
already accepts any (thought, optimal, weight) triple. The reckoner
does not care about outcome — outcome is encoded in the weight.
The near-zero defaults make no claim. Subtlety noted: tick-papers
uses approximate optimal distances (MFE/MAE), while Violence path
uses full 20-candidate sweep. Both honest given their information.

**Beckman:** The training distribution is a strict subset of the
inference distribution. The reckoner has no prototypes in
Violence-leading regions. 99% Grace is the fixed point of a
repeller-attractor loop. The algebra closes — both weights are
f64 fractions of price. The scalar accumulator's extract-scalar
only reads grace-acc — same principle applies, separate proposal.

## The changes

1. **Market signals teach the exit observer.** Every market signal
   (Grace or Violence) calls `observe_distances` on the exit
   observer for that broker's exit index. The composed thought and
   optimal distances flow to all N reckoners.

2. **Defaults become near-zero symmetric.** trail=0.0001,
   stop=0.0001. The bootstrap produces fast, balanced resolutions.
   The learned values replace the defaults as experience accumulates.

## Designer notes for future

- Weight asymmetry (excursion vs stop-distance) is signal, not
  noise. Don't normalize. Measure after shipping.
- Scalar accumulator extraction reads grace-acc only — the
  principle of both-sides applies there too. Separate proposal.
- Bootstrap phase will produce ~480 extra resolution calls.
  Bounded. Measure the transient empirically.
