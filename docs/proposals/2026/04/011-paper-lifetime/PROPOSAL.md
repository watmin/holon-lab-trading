# Proposal 011: Paper Lifetime

**Date:** 2026-04-10
**Author:** watmin + machine
**Status:** PROPOSED

## Context

Papers are hypothetical trades. Every candle, every broker registers
one paper. The paper tracks both buy and sell sides simultaneously.
It resolves when BOTH trailing stops fire. The resolution teaches
the broker and observers: what direction, what distances, Grace or
Violence.

The paper deque grows by 1 per broker per candle. It shrinks by
however many resolve. If resolution rate < creation rate, the deque
grows without bound.

At candle 380: each broker holds ~342 papers. 24 brokers × 342 =
8,208 paper ticks per candle. The throughput degraded from 176/s
to 9/s. The paper tick IS the bottleneck.

## The wat expression

```scheme
;; A paper resolves when BOTH trailing stops fire.
;; Buy side: price rises then retraces by trail distance.
;; Sell side: price drops then recovers by trail distance.
;;
;; In a sideways market: neither fires. The paper lives forever.
;; In a trending market: one side fires quickly, the other waits.
;;
;; A paper from 300 candles ago (25 hours of 5-minute BTC):
;; - The composed thought was from a different market context
;; - The distances were from different volatility
;; - The entry price is ancient
;; - The paper is tracking extremes from a dead regime
;;
;; Is this paper still teaching honest signal?
;; Or is it noise from a dead context?
```

## The question

Should papers have a maximum lifetime? If a paper hasn't resolved
after N candles, is it:

A) **Still valuable** — the market hasn't shown its hand yet. The
   paper is patient. Let it live. The resolution, when it comes,
   carries the full truth of what the market did.

B) **Stale** — the context is dead. The composed thought from
   300 candles ago doesn't describe the current market. The
   distances are from a different regime. The resolution would
   teach the wrong lesson. Evict it.

C) **Partially valuable** — the paper tracked extremes. Even
   without full resolution, the MFE/MAE data (how far each
   side went) carries signal. Produce a partial resolution
   at eviction time.

## The performance cost

Without lifetime cap: O(candles × brokers) paper ticks per candle.
Linear growth. 176/s → 9/s at 380 candles. Will reach 1/s by
candle 1000.

With lifetime cap N: O(N × brokers) paper ticks per candle.
Constant. At N=100: 2,400 paper ticks per candle (fixed).

## The designers' question

Is a paper's resolution at candle 300 honest learning, or noise
from a dead context? Should the machine learn from ancient
hypotheticals, or only from recent ones? What is the natural
lifetime of a thought in a 5-minute market?
