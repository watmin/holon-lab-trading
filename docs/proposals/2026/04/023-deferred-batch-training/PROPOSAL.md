# Proposal 023 — Deferred Batch Training

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposal 022 (paper mechanics — accepted, implemented)

## The insight

The components learn at different rates. The market observer must
learn FAST — reversals must be detected as soon as possible. The
exit observer learns DEFERRED — it needs the full trade history to
know if its decisions were good. The broker orchestrates: it
accumulates training material over the paper's life and batch-trains
the exit at paper closure.

## The market observer — taught twice

### First teaching: the paper signals Grace

The paper's excursion crosses the trail. The market was right. A
runner is forming. The broker IMMEDIATELY signals the market observer:
"the thoughts you had at entry predicted a buy/sell runner." This
is the fast signal. The market observer learns to spot reversals.

Already implemented in Proposal 022.

### Second teaching: how right was the reversal

When the runner finally closes (the trail fires on retracement),
the broker knows HOW FAR the reversal went. The excursion at closure
is the magnitude of the reversal the market observer spotted.

The broker signals the market observer again: "the reversal you
spotted built up to X%. Your thoughts were THIS good." The weight
is the excursion magnitude. A 5% reversal teaches harder than a 1%
reversal.

```
First teaching:  observe(market_thought, direction, weight=trail_distance)
                 "you were right — a runner formed"

Second teaching: observe(market_thought, direction, weight=excursion)
                 "you were THIS right — the reversal was this big"
```

Two observations from one paper. Different moments. Different weights.
The first rewards detection. The second rewards magnitude. The market
observer learns both: "I can spot reversals" AND "I can spot BIG
reversals."

## The exit observer — taught with full context at paper closure

The exit observer made predictions EVERY candle the runner lived.
Each candle, it recommended distances (trail, stop) for the current
composed thought. The broker ACCUMULATES these predictions.

At paper closure, the broker has:
- The full price history of the runner
- Every composed thought during the runner's life
- Every distance prediction the exit observer made
- The actual outcome: where the maximum was, where the trail fired

The broker grades EVERY prediction against hindsight:

```
For each candle k of the runner's life:
    composed_thought_k = the composed thought at candle k
    predicted_trail_k  = what the exit recommended at candle k
    actual_optimal_k   = what trail would have maximized residue
                         (computed from the FULL price history)

    If predicted was close to optimal → Grace, weight = closeness
    If predicted was far from optimal → Violence, weight = distance
```

One runner of 500 candles = 500 exit training observations. Each
graded with full hindsight. Each carrying the composed thought from
THAT moment — the exit observer learns what context produces good
distance predictions and what context produces bad ones.

The exit observer doesn't learn once per paper. It learns N times —
once per candle the runner lived. Batch-trained at paper closure.

## The broker — accumulation and batch drain

The broker already owns the papers. It already ticks them. It already
detects Grace and Violence. The new responsibility: ACCUMULATE the
exit observer's predictions during the runner's life.

```rust
struct RunnerHistory {
    candle_thoughts: Vec<Vector>,      // composed thought per candle
    candle_distances: Vec<Distances>,  // exit's recommendation per candle
    candle_prices: Vec<f64>,           // price at each candle
}
```

The broker stores a `RunnerHistory` per signaled paper (runner). Each
candle, the runner ticks: the broker appends the current composed
thought, the current recommended distances, and the current price.

At paper closure, the broker:
1. Signals the market observer (second teaching — magnitude)
2. Computes optimal distances for each candle from full price history
3. Grades each candle's prediction against optimal
4. Batch-trains the exit observer with all N observations
5. Trains its own reckoner (Grace/Violence for the pairing)

The batch drain is a pipe operation. The broker accumulates. The
closure triggers the drain. The exit observer receives the batch
through its learn channel.

## The topic: market → exit fan-out

When the market observer detects a reversal (paper signals Grace),
ALL exit observers need to know. The market observer publishes to a
topic. The topic fans out to N exit observer pipes. Each exit
observer receives the signal and begins managing its half of the
runner.

```scheme
(let ((market-topic (make-topic (list exit1-tx exit2-tx exit3-tx exit4-tx))))
  ;; When paper signals Grace:
  (send market-topic (list market-thought direction excursion)))
```

The topic is synchronous. The caller (broker thread) sends. The
fan-out happens inline. Each exit observer's pipe receives the
signal. No thread. No queue. A function call.

## The learning rates

```
Component        When it learns              How often
Market observer  Paper signals Grace         ~48/candle (fast)
                 Runner closes (reinforced)  ~2/candle (deferred)
Exit observer    Runner closes (batch)       ~2/candle × N candles per runner
Broker reckoner  Runner closes               ~2/candle
```

The market observer learns the fastest — every paper signal is a
training event. The exit observer learns the most — one runner
produces N observations. The broker learns accountability — one
observation per runner.

## What changes from today

1. **PaperEntry** gains `RunnerHistory` — accumulated per candle
   during runner phase. Only allocated when signaled (Grace).

2. **Broker tick_papers** — during runner phase, append to history
   each candle. At closure, compute optimal distances per candle,
   produce batch of exit training observations.

3. **Resolution struct** — runner resolutions carry the batch of
   exit training observations (Vec of (thought, optimal, weight)).

4. **Binary** — route exit training batches to exit observer learn
   channels. Route second market teaching on runner closure.

5. **Topic** — market observer publishes reversal detections to
   exit observers via make-topic fan-out.

## Questions for the designers

1. The RunnerHistory stores a Vector per candle — 10000 dims × 8
   bytes = 80KB per candle per runner. A 500-candle runner = 40MB.
   24 brokers × some runners each. Is this too much memory? Should
   we subsample (every 10th candle)?

2. The "optimal distance at candle k" requires replaying the price
   history from candle k forward. That's O(runner_length) per candle,
   O(runner_length²) total. For a 500-candle runner, that's 250k
   operations. Acceptable? Or should we compute optimal from the
   full history once and apply it to all candles?

3. The second market teaching (magnitude reinforcement) — should
   the weight be the raw excursion? Or the excursion minus the trail
   (the EXCESS — how much beyond the threshold)? The excess is how
   much MORE than "barely right" the market observer was.

4. Should the exit observer also learn from Violence papers (papers
   where the stop fired)? The distances WERE set — they just failed
   to protect. That's information about what distances DON'T work
   in that context. Or is that noise — the market observer was wrong,
   not the exit observer?
