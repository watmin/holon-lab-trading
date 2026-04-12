# Resolution: Proposal 030 — Broker Thinks Opinions

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement with ALL facts, not opinions-only

## Designers

**Hickey:** Drop extracted facts, opinions-only. **OVERRULED.**
We have learned many times that more thoughts and stripping noise
is the best path. If the extracted facts are noise, the broker's
noise subspace will strip them. If they carry signal, the reckoner
will use them. We don't decide. The measurement decides.

**Beckman:** Opinions-only isolates causation. The structural
correction stands — one construction, two call sites. The
diagnosis (50/50 is inevitable without opinions) is accepted.

## The datamancer's decision

The broker keeps ALL its thoughts:

```scheme
(Bundle
  ;; OPINIONS — what the leaves decided (7 atoms) — NEW
  market-opinions         ;; signed-conviction, conviction, edge
  exit-opinions           ;; trail, stop, grace-rate, avg-residue

  ;; CONTEXT — what the candle looked like (extracted facts) — KEEP
  extracted-market-facts  ;; ~100 atoms from market anomaly
  extracted-exit-facts    ;; ~28 atoms from exit anomaly

  ;; SELF — the broker's own performance (7 atoms) — KEEP
  self-assessment)        ;; grace-rate, paper-duration, etc.
```

~142 atoms. The noise subspace strips what doesn't matter.
The reckoner finds what predicts Grace. The broker holds the
market accountable based on its thoughts — it must KNOW what
the market found noteworthy. The opinions are the missing signal.
The context is the accountability. Both compose. The noise
subspace separates.

We have proven: more thoughts, strip noise, let the reckoner
decide. The exit went from 16 atoms to 128 and all deciles
went positive. We do it again here. If the market's thoughts
are noise, they are noise. The architecture handles it.

## The changes

1. **New vocab module:** `src/vocab/broker/opinions.rs`

   ```scheme
   ;; Market opinions (3 atoms):
   (Linear "market-direction"  signed-conviction)  ;; [-1, +1]
   (Linear "market-conviction" conviction)          ;; [0, 1]
   (Linear "market-edge"       edge)                ;; [0, 1]

   ;; Exit opinions (4 atoms):
   (Log    "exit-trail"        trail-distance)      ;; (0, 0.10]
   (Log    "exit-stop"         stop-distance)       ;; (0, 0.10]
   (Linear "exit-grace-rate"   grace-rate)           ;; [0, 1]
   (Log    "exit-avg-residue"  (max 0.001 residue)) ;; positive
   ```

2. **Broker thread: opinions + extracted + self.** The broker's
   bundle is all three. Not opinions-only. The opinions are
   ADDED to the existing extracted facts and self-assessment.

3. **One construction, two uses.** (Beckman's correction.) The
   broker_thought is constructed once. Used in `propose()`. The
   SAME thought flows to paper registration. Alignment preserved.

4. **Signed conviction:** Direction IS the sign. One Linear atom.
   Range [-1, +1]. Up at 0.15 → +0.15. Down at 0.08 → -0.08.

5. **Log for distances.** Three orders of magnitude. Log preserves
   ratio semantics.

## What doesn't change

- Market observer encoding or learning
- Exit observer encoding or learning
- The extraction pipeline (still used by broker — context)
- The broker's propagate() — learns from last_composed_anomaly
- The paper mechanics
- The simulation
