# Proposal 012: Exist in the Moment

**Date:** 2026-04-10
**Author:** watmin + machine
**Status:** PROPOSED

## Context

The machine processes candles at 175/s during warmup. By candle 500
it degrades to 4/s. The bottleneck is the QUANTITY of vec ops — each
resolution triggers 5 × 10000D operations in propagation. More
papers → more resolutions → more propagation → slower. SIMD didn't
help. The count is the cost.

The machine manages trades. A trade may last years. But the
management lives for one candle. The enterprise doesn't predict
where the price will be in 300 candles. It predicts: right now,
for THIS thought in THIS context, what is the best trail distance?

The breathing stops. Step 3c. Every candle. One encode. One predict.
One distance. Set the stop. Done. Next candle.

## The insight

The machine needs to exist in the moment. The thought IS the moment.
The reckoner maps moments to actions. The papers teach the mapping.
The papers don't need to simulate full trade lifecycles. They need
to answer: "at THIS moment, with THIS trail distance, did the next
move produce Grace?"

The hot path should be constant per candle:
1. Encode the moment (one candle → one thought)
2. Ask the reckoner (one cosine → one distance)
3. Act (set the stop)

The learning should be decoupled from the hot path:
- Papers resolve asynchronously
- Propagation flows through pipes
- The reckoner updates in the background
- The prediction at candle N uses the reckoner's state from
  candle N-1 (or N-10, or whenever it last updated)

The prediction doesn't need a perfectly current reckoner. One
observation barely moves the discriminant. The reckoner at candle
500 and the reckoner at candle 499 produce nearly identical
predictions. The learning is eventually consistent. The prediction
is approximately correct. The stops breathe approximately right.

## The question

Should the learning (propagation) be separated from the hot path
(encode → predict → act)? Concretely:

**Current architecture:** The broker thread drains its learn queue
BEFORE processing the next candle. If 50 propagation signals are
queued, the broker does 50 × 5 = 250 vec ops before it can
propose on the next candle. The hot path is gated by the learning.

**Proposed architecture:** The broker thread processes candles at
full speed — encode, predict, act. The learn queue is drained on a
SEPARATE schedule: every N candles, or in idle time, or on a
separate thread. The prediction uses whatever the reckoner has
learned so far. The learning catches up. Eventually consistent.

The hot path is constant: one encode, one predict, one propose.
The learning path is decoupled: drain when you can, skip when busy.
The reckoner is always approximately correct because one observation
barely moves the discriminant.

## What changes

- The broker thread no longer drains its learn queue every candle.
  It drains on a schedule (every N candles) or in a separate loop.
- The prediction uses the reckoner's current state, not the
  perfectly-up-to-date state.
- The throughput becomes constant — no degradation with candle
  count. The learning happens in the background.

## What doesn't change

- The algebra. Same six primitives.
- The cache. Same encoder service.
- The pipes. Same channel architecture.
- The accuracy. The reckoner is eventually consistent — the
  discriminant converges to the same fixed point. The path to the
  fixed point is slightly different (delayed observations) but the
  destination is the same.

## The designers' question

Is eventually-consistent learning honest? Does the reckoner
produce trustworthy predictions when its state is N candles behind
the observations? Is the prediction from a slightly-stale
discriminant Grace or Violence?

The market observer's reckoner at candle 500 has accumulated 3312
observations. One more observation changes the discriminant by
1/3313. The prediction changes by... nothing measurable. Is
deferring 50 observations the same as deferring one, applied 50
times? Or does the batch change the discriminant enough to matter?

The machine needs to exist in the moment. The moment is the
prediction. The learning is the past. Should they run at the
same speed?
