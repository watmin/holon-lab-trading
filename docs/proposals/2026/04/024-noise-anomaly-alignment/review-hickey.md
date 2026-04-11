# Review — Proposal 024

**Reviewer:** Rich Hickey (simulated)
**Date:** 2026-04-11

## 1. Is the mismatch the real problem?

Yes. Completely. You predict on f(x) and learn from x. The discriminant
builds a decision surface in one space and receives training signal from
another. This is not a subtle statistical concern — it is a categorical
error. The function that produced the input at prediction time is not the
identity, so the training pair is broken. Every gradient (or in your case,
every subspace update) pulls the reckoner toward something it will never
see again. The prior experiments showing "noise doesn't matter" were
testing the wrong thing. Of course they matched — both were wrong in
complementary ways.

## 2. Is storing the anomaly on the paper the right fix?

The fix is *almost* right, but it complects two things.

The paper is an accountability record — it tracks a trade from proposal
to settlement. It answers: what was proposed, at what price, what happened.
The anomaly is observation state — it is what a specific observer's
perceptual apparatus produced at a specific moment. These are different
concerns.

Storing the anomaly on the paper works mechanically. But now PaperEntry
carries `composed-thought` (for the broker/exit) AND `prediction-thought`
(for the market observer). The paper becomes a bag of vectors for different
consumers. That is a smell. The paper doesn't *use* the prediction-thought.
It *carries* it for someone else.

The simpler decomposition: the observer returns a prediction receipt —
the anomaly vector and the prediction. The broker holds the receipt
alongside the paper. At resolution, the broker hands the receipt back.
The paper stays clean. The receipt is the observer's concern, not the
trade's concern.

That said — if you only have one consumer (market observer) and the paper
is already the propagation vehicle, adding one field is pragmatic. Just
know you are making a tradeoff: simplicity of implementation against
simplicity of concept. The field works. The abstraction leaks.

## 3. Simple or complected?

It complects the paper with observation state. Mildly. The paper becomes
aware that different observers need different vectors back. That is a
coupling that did not exist before.

But the alternative — a separate receipt type, a separate propagation
path — adds moving parts. And you already have the propagation path
through the broker.

## Verdict

**Do it.** The mismatch is real and damaging. The fix is correct in
substance. The single field on PaperEntry is an acceptable pragmatic
choice. If you later find the paper accumulating more observer-specific
state, extract the receipt then. Not now. Solve the problem you have.

The real question is #1 from your questions section: is training on a
stale anomaly honest? Yes. The reckoner should learn "when I saw THIS,
the outcome was THAT." The noise model moved on. The reckoner's memory
should not. The anomaly is a fact about what was perceived, not a fact
about what was true. That is exactly what you want to learn from.
