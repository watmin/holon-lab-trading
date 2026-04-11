# Review — Proposal 017

**Reviewer:** Rich Hickey (simulated)
**Date:** 2026-04-10

## Verdict

Theory 1 is the real problem. The others are symptoms or distractions.

## The answers

**Q1 — Direction label coupling.** Yes, this is a real problem, and it's the
worst kind: a complecting of concerns. The market observer's job is to learn
direction. The label it learns from is `f(market_move, buy_trail, sell_trail)`.
That's not a direction label. That's a *resolution* label — it encodes the
exit observer's choices. You've wired two independent concerns through a
shared value and called it "learning." The market observer cannot learn
direction because it has never been told direction. It has been told "which
paper leg tripped first," which is a different thing entirely.

**Q2 — Noise subspace.** Not the primary problem. k=8 on 4096 dimensions is
conservative. But the question reveals a deeper confusion: the noise subspace
learns from *all* thoughts, including signal. In DDoS, normal traffic is
plentiful and anomalies are rare — the subspace learns normal, residuals are
anomalies. In markets, there is no "normal." Every candle is a new regime.
The subspace isn't stripping signal so much as it has no coherent thing to
learn. Worth revisiting after fixing the label, but it's not the bottleneck.

**Q3 — Time horizon.** 2000 candles is early, but disc_strength 0.003 with
8905 observations isn't warmup — it's absence of signal. If the label is
noise, more time produces more noise. You can't sharpen a discriminant on
random labels. This theory is the "maybe it'll get better" hope. Measure,
don't hope.

**Q4 — Diagnostics.** Measure at the label. Take 1000 resolved papers.
Compute the correlation between the direction label and the actual
price move (close-to-close over the paper's lifetime). If that
correlation is low, the label is the problem — full stop. You don't
need to trace the whole pipeline. Find where truth enters the system
and check whether it's actually true.

**Q5 — What changed.** You added papers with independent sides and
asymmetric distances. Before that, direction was simpler — probably
closer to actual price movement. The architecture added a layer of
indirection between "the market moved up" and "the label says Up."
That indirection is the complecting.

## What to fix

Decouple the label. The market observer needs a direction label that
is a pure function of price movement — not resolution order. The
simplest version: did price move up or down over the next N candles?
That's it. The exit observer can keep its resolution-based learning.
The broker can keep Grace/Violence. But the market observer's label
must be *about the market*, not about the paper machinery.

This is separation of concerns. The market observer observes the
market. The exit observer observes the exit. When you feed one
observer's output into another observer's label, you've created a
cycle where neither can learn independently. Break the cycle.

## What to measure first

One query: correlation between the direction label and raw price
movement. If it's low, you have your answer. If it's high, I'm
wrong, and Theory 3 becomes the next suspect.
