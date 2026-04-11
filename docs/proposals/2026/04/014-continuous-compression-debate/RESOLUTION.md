# Resolution: Proposal 014 — The Compression Debate

**Date:** 2026-04-11
**Decision:** PARTIAL — implement F. Defer D vs B until F reveals data.

## The decision

The designers agree on one thing: F (similarity gating at the call site).
Everything else is in tension. Rather than choose between D and B without
data, implement F alone and measure what it reveals.

F changes the question. Today every candle queries every reckoner. After F,
only candles where the composed thought shifted meaningfully query the
reckoner. The query count drops. The remaining queries are the ones that
MATTER — where the context genuinely changed.

The data from F tells us:
- How often do composed thoughts actually change? (hit rate on the gate)
- When they change, how much does the distance change? (sensitivity)
- Does the grid cost flatten, or does it still grow? (residual scaling)

If F alone flattens the grid, the D vs B debate is moot — the reckoner
is rarely queried and its internal cost doesn't dominate. If F reduces
but doesn't flatten, the residual scaling reveals whether D's bounded
cost or B's algebraic structure is the right next step.

Measure first. Then decide.

## Update: F measured. F failed.

2000 candles. Zero gate hits. The cosine between consecutive composed
thoughts averages 0.50, with minimums at 0.10. The thoughts shift
massively every candle — the market moves, the indicators change,
the facts change. The threshold of 0.95 is unreachable. Even 0.50
would suppress real signal.

F is the wrong lever. The premise — that composed thoughts are stable
between candles — is false. The data proved it. The reckoner MUST
answer every candle because every candle brings a genuinely new thought.

The answer is not fewer queries. The answer is cheaper queries.
Forwarded to Proposal 015.

## What F looks like

Each broker caches its last query result and the composed thought that
produced it. On the next candle:
1. Compute the new composed thought (O(D) — this happens anyway)
2. Cosine between new and cached thought (O(D))
3. If cosine > threshold: reuse cached distances. Skip the query.
4. If cosine <= threshold: query the reckoner. Cache the new result.

The threshold starts at 0.95. We measure. We adjust. The threshold
itself may become derivable from the data — but start with a constant.

## The designers' positions (preserved)

Hickey: D+F → A. The FIFO buys time. The single regression direction
is the destination.

Beckman: B+F. Bucketed accumulators are the destination. The bucket
boundaries are derived from precision, not tuned.

Both positions stand. F is the common ground. The data from F informs
the next decision.
