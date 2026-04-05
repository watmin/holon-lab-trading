# Resolution: Proposal 007

**Hickey: APPROVED.** First clean approval across all proposals.

**Beckman: CONDITIONAL** on three empirical conditions.

---

## Beckman condition 1: Kernel selectivity

**Accepted. Will measure.** After the first 100k run with the new architecture, plot the cosine similarity distribution of stored thoughts in the LearnedStop. If bimodal (near-zero cluster + meaningful cluster), the kernel is selective. If broad unimodal, introduce a sharpening exponent (`cos^k`). The measurement comes from the run, not from theory.

## Beckman condition 2: Sell-side optimal distance

**Accepted. Will implement.** `compute_optimal_distance` currently simulates buy-side trailing stops only. The sell-side mirror is trivial — ratchet the extreme downward, fire when price rises above the trail. Both sides needed for the DualExcursion to learn honestly. Will add before the first run.

## Beckman condition 3: Feedback stability

**Accepted. Will measure.** Run the 100k benchmark twice: once with per-candle LearnedStop adjustment on live trades, once with fixed stops from entry. Compare whether the learned distances oscillate or stabilize. The paper stream provides open-loop training (not influenced by the LearnedStop), which should stabilize the closed loop. The measurement proves it.

---

## Hickey's items to watch

1. **Paper vector memory** — each closure holds paper entries with thought vectors. Will monitor memory growth. The ring buffer on papers caps it.
2. **LearnedStop linear scan** — O(pairs) per query. At 5000 pairs, this is ~5000 cosines per candle per active trade. Will profile. If hot, spatial indexing (e.g., locality-sensitive hashing) replaces the linear scan.
3. **Step 3 scope creep** — PROCESS does two things (update active + tick papers). Will keep them as two sub-phases, not interleaved.
4. **Tuple journal struct size** — papers + track record + learned stop + scalar accumulators. Will monitor. The flat vec means one allocation, not N×M.

---

## The decision

Build it. Beckman's conditions are measurements from the first run, not design changes. Hickey's items are monitoring, not blocking. The algebra is sound. The architecture composes. The tuple journal is the right abstraction.

Sell-side `compute_optimal_distance` first (Beckman condition 2). Then the four-step loop. Then the 100k run. Then the measurements (conditions 1 and 3).

*Accepted. Implementation follows.*
