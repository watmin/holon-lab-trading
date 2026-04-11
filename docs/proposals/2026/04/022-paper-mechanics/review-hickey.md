# Review — Proposal 022

**Reviewer:** Rich Hickey (voice)
**Date:** 2026-04-10

---

## Is this simpler than "both sides resolve independently"?

Yes. Dramatically. The current design has a paper that is two independent
state machines ticking in parallel, each producing outcomes that must be
reconciled. That's complecting measurement with exploration. This proposal
collapses it: one prediction, one measurement, one outcome. The paper
becomes a *test* of a *claim*. That's what measurement IS.

The superposition language is apt — you don't observe both branches. You
choose which question to ask and then you get one answer.

## Do the separations hold?

They do. Three clean boundaries:

1. **Market observer** — produces a claim (direction + conviction). Knows
   nothing about papers, distances, or outcomes.
2. **Broker/paper** — tests the claim. Owns the measurement apparatus
   (triggers, distances). Returns a verdict.
3. **Exit observer** — only exists in the Grace path. Learns from runners.
   Never touched by Violence.

The critical insight: the exit observer learning NOTHING from failed entries.
That's proper separation. A failed prediction is not exit information — it's
market information. Today's design leaks exit learning into failed trades.
That's complecting two independent concerns.

## Answers to the four questions

**Q1 — Should the opposite side be tracked?**
No. Two triggers. Trail and stop for the predicted direction. The opposite
side is not information — it's noise. Tracking it invites the temptation to
use it. Don't carry what you won't consume.

**Q2 — Exit distances grading market observer?**
Acceptable. The market observer is graded by *whether reality confirmed its
claim within a tolerance*. That tolerance must come from somewhere. Having it
come from a learning system (exit observer) is better than a magic number.
The market doesn't know the tolerance. It just gets Grace or Violence. Clean.

**Q3 — Timeout?**
No timeout. A paper that sits is information — the market made an
indeterminate claim. But do bound the NUMBER of open papers. Capital is the
natural timeout. If treasury won't fund new papers because capital is
reserved in indeterminate ones, the system self-regulates.

**Q4 — Should conviction influence distances?**
No. That complects the claim with the measurement apparatus. The market says
"how sure." The broker decides "how to test." If conviction influenced
distances, the market observer would be indirectly choosing its own grading
criteria. Keep the judge independent of the defendant.

## Verdict

Accept. This is a genuine simplification — fewer states, fewer transitions,
cleaner information flow. The previous design asked "what happened?" This
design asks "was the prediction correct?" That's the right question.
