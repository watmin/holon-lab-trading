# Review: Proposal 030 — Broker Thinks Opinions

**Reviewer:** Rich Hickey (in character)
**Date:** 2026-04-12

---

## The diagnosis is correct

The broker is 50/50 because it thinks about the wrong things. That sentence
is the entire review. Everything else is commentary.

You have confused inputs with outputs. You fed the broker what the candle
looked like — the market's inputs — and asked it to predict what a trade
will do. The trade doesn't know what the candle looked like. The trade knows
what the leaves DECIDED. The broker's reckoner never had the information it
needed. It was guessing.

That's not a bug. That's a design error. You built a discriminant that
accumulates the wrong superposition. Fix the superposition; the reckoner
learns.

---

## On Question 1: drop the extracted facts

You ask whether to keep the extracted facts alongside the opinions.

Drop them. Or run experiments and see — but here's the argument for dropping:

The extracted facts are the INPUTS to the leaves' decisions. The opinions are
the OUTPUTS of those decisions. If you include both, you have the input and
the output in the same bundle. The reckoner doesn't need the input once it has
the output — the output already encodes what the leaf found worth acting on.
The leaf filtered the candle. The opinion IS the filter result.

More concretely: you have 7 opinion atoms and roughly 100 extracted-fact atoms.
In a bundle, signals combine by superposition. 100 dimensions of context
drowns 7 dimensions of decision. The thing you want the reckoner to learn from
is the minority voice.

The proposal answers its own question: "the opinions are the signal, the
context is the background." You've told us the background is noise relative
to the signal. Then why include it?

Run the broker on opinions only first. If it's still blind, add context back
and measure whether it helps. Don't complect signal and noise before you know
what the signal is worth alone.

---

## On Question 2: the feedback loop

You ask whether encoding the broker's own edge as an input creates a
circular dependency.

Yes. And it is probably fine. Here is why.

The edge at prediction time is computed from the broker's historical curve.
It is a lagging average over past episodes. It tells the reckoner "when we
were in this regime, we had this accuracy at this conviction level." That is
not circular — it is self-referential in the way a posterior belief is
self-referential. The edge is a summary of the past, not a prediction of the
future. The reckoner learns to weight it appropriately.

The potential pathology is if the edge grows large (broker has a good run),
amplifies the signal in the bundle, causes the reckoner to bet more
aggressively, causes more wins, causes higher edge, repeat. That is
reinforcement, not circularity. Whether that's desirable depends on whether
the edge is a reliable signal.

The question to ask is simpler: does including edge as a reckoner input
improve the reckoner's discrimination? Measure it. The architecture doesn't
prohibit self-reference. VSA bundling is superposition — the edge atom sits
alongside the other atoms, weighted equally. It cannot dominate unless you
amplify it.

---

## On Question 3: Log vs Linear for distances

Log. The proposal already says the distances are small positive fractions
in `[0.001, 0.10]`. That is three orders of magnitude. Linear encoding implies
that the difference between `0.001` and `0.002` is the same structural
distance as the difference between `0.09` and `0.091`. It is not. The exit
observer chose `0.002` instead of `0.001` — doubling the distance. That
doubling matters. Log-encoding preserves ratio semantics. Use Log.

This is not ambiguous. The primer says it clearly: "log for quantities
spanning orders of magnitude." Distances spanning 0.001 to 0.10 span two
orders. Log.

---

## On the signed conviction encoding

This is the sharpest idea in the proposal and deserves explicit acknowledgment.

One Linear atom. Sign carries direction. Magnitude carries conviction.
`+0.15` means Up at moderate confidence. `-0.08` means Down at low confidence.
The reckoner's discriminant learns in one scalar what would otherwise require
two atoms and a coupling constraint between them.

This is simple. Not simplistic — the distinction matters. Direction and
conviction are complected in the market observer's output — they are not
independent. Encoding them as one signed magnitude honors that complecting
rather than artificially separating them. The geometry of Linear encoding
then makes `+0.15` more similar to `+0.20` than to `-0.15`. Correct.

The one thing to verify: the Linear encoder's range. If you normalize
conviction to `[-1, 1]`, the encoding covers the full signed range. If
conviction is already in `[0, 1]` and sign is applied externally, make
sure the encoder knows the full range is `[-1, +1]`, not `[0, 1]`. The
interpolation basis depends on the declared range.

---

## On the architecture

The broker is the accountability unit. The proposal correctly observes that
accountability without information is theater. You cannot hold an observer
accountable for outcomes it couldn't see coming. The broker currently holds
paper trades but doesn't observe the leaf decisions that caused those trades.
It observes the candle weather, not the leaf choices.

The fix is architecturally minimal: add opinion encoding to the broker's
vocabulary. The broker already receives the prediction struct, the edge, the
reckoner_dists. All seven proposed atoms are on the pipe. This is not a
redesign — it is completing the encoding that should have been there from the
start.

The proposal is correct. The broker's reckoner was fed the wrong facts. Fix
the facts; fix the reckoner.

---

## Verdict

Implement this. Opinions only, no extracted facts, at least for the first
run. Measure. If the broker lifts above 55% Grace discrimination, the
diagnosis was right. If it doesn't, we have a harder problem — the reckoner
itself, or the label quality, or a structural issue in the paper mechanics.

One proposal, one variable. Don't add the extracted facts back in at the same
time as the opinions. You won't know which one moved the needle.

The signed conviction is the right encoding. Log for distances. The feedback
loop is not pathological. The ratio problem (7 vs 100 atoms) is the main
risk, and the solution is to not create the problem in the first place.

Build it.
