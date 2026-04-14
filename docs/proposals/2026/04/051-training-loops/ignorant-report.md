# Ignorant Report: Proposal 051 — Training Loops

I know nothing about this project. I read 17 files in order. Here is
what I found.

---

## 1. What I understood — the core argument

The system has three learners: a market observer (predicts direction),
a position observer (predicts distances for stops and trails), and a
broker (accounts for trade outcomes). The position observer is broken.
It has two learning paths that contradict each other: one honest
(continuous geometric error against simulation-computed optimal
distances), one dishonest (binary Grace/Violence labels derived from
a self-referential rolling median and contaminated by the market
observer's direction accuracy). The dishonest path creates a
mathematically provable limit cycle where grace_rate oscillates to
zero. The fix is a deletion: remove the binary learning path from
the position observer. One teacher, one signal, one channel.

I can state this back because the 17 documents taught it to me
through repetition from five independent angles. By the end of the
debate round, I could have written the recommendation myself. The
path teaches.

---

## 2. What confused me — where the path broke

**The proposal itself assumes deep prior knowledge.** The six
questions in PROPOSAL.md reference proposals 043, 038, 035, 024, 026
without summarizing them. I do not know what Proposal 035 did to the
broker reckoner, only that it "stripped" it. I do not know what
Proposal 043 changed about paper registration, only that papers now
register every candle. I do not know what Proposal 038's "hold
architecture" is. The proposal is addressed to reviewers who have
already read 50 prior proposals. For the ignorant reader, the first
document is a wall of undefined references.

**The reviewers saved me.** Each reviewer re-explained the system
from scratch in the process of answering the questions. By the time
I finished Seykota's review, I understood the architecture well
enough to follow the remaining four. The reviews are better entry
points than the proposal itself.

**Specific confusions that were never fully resolved:**

- What exactly is `observe_scalar` vs `observe`? I infer these are
  two methods on the reckoner: one for continuous values, one for
  binary labels. But neither the proposal nor any review defines them.
  I pieced this together from context across multiple files.

- What is a "reckoner"? I gathered it is the learning mechanism, but
  its interface was never specified. I know it has `observe`,
  `observe_scalar`, a discriminant, and a subspace. These words
  appeared scattered across reviews without a single definition.

- What is the "anomalous component" and "residual"? Beckman mentions
  the subspace absorbing signal. Seykota mentions residuals. These
  are VSA/HDC terms that the reviews use fluently but never define
  for the ignorant reader.

- The phrase "the simulation's `compute_optimal_distances`" appears
  in every review as if it is well-known. I believe it is a function
  that sweeps candidate distances against realized price paths to
  find the hindsight-best stop and trail. But this is inference, not
  knowledge.

---

## 3. Where the five voices contradicted each other

**On wrong-direction papers:** Seykota and Beckman (Round 1) said
discard them -- zero weight when direction was wrong. Van Tharp said
keep them -- wrong-direction papers contain information about
defensive stop quality. Hickey initially agreed with filtering, then
reversed in Round 2 after accepting that the continuous geometric
error is direction-agnostic and no filter is needed. Seykota also
reversed. By the end of Round 2, this contradiction was resolved:
all five agreed no filtering is needed because the continuous signal
handles both populations.

**On phase capture ratio vs geometric error:** Wyckoff proposed
phase capture ratio as the training signal replacement. The other
four preferred geometric error against simulation-computed optimal
distances, arguing that phase capture ratio introduces a dependency
on the phase labeler's accuracy. Wyckoff conceded in Round 2 that
phase capture ratio belongs in the broker's telemetry, not in the
position observer's training loop. Resolved.

**On the broker composition -- remove or keep dormant:** Wyckoff and
Hickey (debate round) said remove the dead composition. Seykota said
keep it dormant -- removing correct infrastructure to save
microseconds is premature. Hickey shifted in Round 2 to "gate it
behind a flag." Van Tharp said remove for now, file restoration as
future proposal. This contradiction was NOT fully resolved. Three
voices say remove, one says gate, one says keep. The practical
difference is small but the principle is contested.

**On what comes second:** Wyckoff says volume-price divergence atoms
(Change 2). Van Tharp says R-multiple normalization (Change 2).
Seykota says R-multiples. Hickey says gate the composition. Beckman
says add a concordance atom. Every voice agrees on Change 1 but the
priority queue after that has five different orderings. This is
unresolved.

**On R-multiples as the ONE change:** Van Tharp held this position
through the review round. Every other voice argued it is a
second-order change. Van Tharp conceded in Round 2 that the
learning signal must be fixed first. The contradiction resolved,
but Van Tharp's concession came with a caveat: R-multiples are
necessary, just not first.

---

## 4. Where the five voices converged

The convergence is remarkably clear. By Round 2, all five voices
agreed on:

1. **Remove the binary Grace/Violence learning path from the position
   observer.** This is the single highest-leverage change. The
   continuous geometric error via `observe_scalar` with
   simulation-computed optimal distances is the sole training signal.

2. **The rolling percentile median dies.** No voice defended it after
   Beckman's proof that it is a contraction mapping guaranteeing
   oscillation.

3. **No direction conditioning needed.** The continuous error signal
   is direction-agnostic. All papers contribute to learning.

4. **The grace_rate becomes a broker-side diagnostic,** not a
   position-observer self-assessment.

5. **The market observer's training loop is honest.** Do not touch it.
   Direction is binary; the binary label is correct.

6. **A design invariant emerges:** no learner shall be graded against
   a statistic derived from its own output distribution. All five
   voices endorsed this principle.

7. **The broker reckoner should return -- but later,** after the
   position observer's signals are clean.

The convergence is genuine. It was not forced by the moderator. Each
voice arrived independently and then acknowledged where they were
moved. The Round 2 documents explicitly credit which voice changed
their mind on which point. This is honest process.

---

## 5. If I had to implement ONE change

**Delete the binary Grace/Violence learning path from the position
observer.**

The documents taught me enough to know what this means concretely:

- Remove the call that sends Grace/Violence labels to the position
  observer's discrete reckoner (the `observe` path).
- Remove the rolling percentile median computation and the
  `journey_errors` window from the broker's journey grading path.
- Keep the `observe_scalar` calls that feed continuous geometric
  error (predicted vs optimal trail, stop, take-profit, runner-trail)
  to the continuous reckoners.
- Derive the position observer's self-assessment from the broker's
  trade outcomes, not from the observer's own rolling window.

I know WHAT to delete. I do not know WHERE in the codebase it lives.
The reviews reference "the broker program," "the position observer
program," and "the propagation logic," but these are conceptual
locations, not file paths. The proposal mentions `wat/` files and
`src/` files but the actual filenames are never given. An implementer
would need to find the `observe_distances` call (or equivalent), the
`journey_errors` window, the rolling percentile median computation,
and the binary Grace/Violence path in the position observer. The
documents describe the surgery precisely but do not hand you the
scalpel or point to the operating table.

---

## 6. Questions that remain unanswered

1. **What happens to the position observer's `confidence` and
   `avg_residue` after Path B is removed?** Van Tharp proposed
   `calibration_confidence = 1.0 / (1.0 + mean_error)`. Nobody
   else commented on this. It was neither endorsed nor rejected.
   The downstream consumers of confidence are mentioned but the
   replacement formula has one vote.

2. **The market observer's directional accuracy is never stated.**
   Every voice says it is "around 50%" or implies it is barely
   above coin-flip. But the actual number is never quoted from data.
   If market accuracy is genuinely 50%, the entire system produces
   zero edge from direction prediction. The position observer fix
   is necessary but not sufficient.

3. **What is the position observer's continuous reckoner convergence
   rate currently?** The reviews discuss that 508K core experience
   produced no improvement. But nobody asks: is the continuous path
   (Path A) already converging? If Path A is also failing, removing
   Path B is necessary but does not guarantee improvement.

4. **How does `compute_optimal_distances` handle the case where the
   paper should never have been opened?** On a wrong-direction trade,
   the "optimal trail" is zero (no favorable excursion). What
   geometric error does the position observer learn from a predicted
   trail of 0.03 versus an optimal of 0? Division by zero? The
   formula `|predicted - optimal| / optimal` is undefined when
   optimal is zero. Nobody addressed this edge case.

5. **The sequencing after Change 1 is unresolved.** Five voices
   proposed five different second priorities. There is no mechanism
   in the process to resolve this. The debate converged on the first
   action and diverged on everything after.

6. **The 2x weight modulation at phase boundaries.** Wyckoff and Van
   Tharp argued it should be a continuous function of phase duration,
   not a step function at duration <= 5. Beckman noted the temporal
   misalignment (the weight is applied to the detection candle, not
   the actual turn candle). None of these concerns were resolved.
   They were acknowledged and set aside as "not the highest leverage."
   They remain open.

7. **Wyckoff's volume-price divergence proposal received no
   engagement from the other four voices.** In Round 2, Wyckoff
   argued it is not premature -- that a market observer without
   volume understanding predicts from noise. No other voice responded
   to this argument. It was neither endorsed nor refuted. It hangs.
