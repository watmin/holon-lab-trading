# Review — Proposal 022: Paper Mechanics

**Reviewer:** Brian Beckman (invited)
**Date:** 2026-04-10

## The diagram

You have a functor from Prediction to Measurement. The market observer emits a morphism in {Up, Down}. The paper is a measurement device that collapses a superposition along that morphism. Four outcomes form the product category Direction x Quality. Three learners partition the fiber. The question is whether this is a proper factorization system.

## Answers

**Q1 — Should the opposite side exist?**

No. You defined measurement as projection onto the predicted subspace. The opposite half carries zero bits of information about the observer's competence. Tracking it is tracking a counterfactual — interesting for offline analysis, expensive for a live system. Two triggers per paper. The superposition is a conceptual device; the implementation should be the collapsed state.

**Q2 — Exit parameters grading the market observer.**

This is acceptable because the composition is a pullback. The exit observer defines the measurement apparatus (distances). The market observer is graded by whether reality exceeded that apparatus. The alternative — fixed thresholds — would make the grading functor constant, destroying the feedback path from exit learning to market grading. Let the apparatus co-evolve with the prediction. The diagram commutes: better exits make market grading more precise, better market predictions give exits cleaner runners to learn from.

**Q3 — Timeout.**

A paper stuck between triggers is a measurement that hasn't decohered. Physically: the market said nothing. The correct information-theoretic response is to emit a third outcome — Silence — carrying zero weight to all learners. A timeout (say, 2x the median resolution time) prevents resource leaks. The market observer receives neither Grace nor Violence. It simply learns nothing from that prediction. No reward, no punishment. This preserves the entropy — you don't fabricate a bit that wasn't there.

**Q4 — Conviction influencing distances.**

No. This would create a cycle in the dependency graph: conviction is computed before measurement, but if conviction modifies the measurement apparatus, you lose the clean factorization. The broker already uses conviction for sizing (how much capital). Let the paper use fixed distances (from the exit observer) for the what. Let conviction govern the how much. Separation of concerns. The diagram commutes only if the measurement is independent of the confidence in the prediction.

## Verdict

The information is properly factored. Three learners, three non-overlapping fibers of the outcome space. The cascade preserves information: Grace flows down to exit and broker; Violence terminates early and routes only to market. No learner receives signal it cannot act on. No signal is lost.

This is a well-constructed measurement theory. Ship it.
