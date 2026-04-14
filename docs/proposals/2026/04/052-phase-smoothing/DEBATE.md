# Debate: Proposal 052 — Phase Smoothing

Five voices reviewed. Three tensions.

## Tension 1: Fix the threshold or fix the input?

- **Seykota/Van Tharp/Wyckoff/Beckman:** Raise k to 2.0+ ATR.
  Keep raw close. The threshold is wrong, not the input.

- **Hickey:** Smooth the input — feed ema(close, 20) instead
  of raw close. Separate the timescale knob from the structural
  knob. The raw close is noisy by nature. Raising the threshold
  is compensating for noisy input with a bigger filter.

Can both coexist? Smooth the input AND raise the threshold?
Or does one make the other redundant?

## Tension 2: How many phases is right?

- **Seykota:** 50-100 per 1000 candles. Median 5-10.
- **Van Tharp:** 60-120 per 1000. Median 8-12.
- **Beckman:** 100-150 per 1000. Modal 3-8.
- **Wyckoff:** 8-20 per 1000. Median 25-50.

Wyckoff wants 10-20x fewer phases than the others. He's
reading structural scale — full Wyckoff phases, not swing
highs and lows. The others are reading swing scale. Which
scale does this labeler serve?

## Tension 3: Confirmation window or not?

- **Van Tharp:** 5-candle confirmation before declaring a phase.
- **Seykota:** 2-3 candle persistence filter.
- **Hickey/Wyckoff/Beckman:** No. Fix the smoothing and the
  minimum becomes unnecessary.

## Hickey's deeper point

"The labeler detects reversals (events) but calls them phases
(durations). Peaks and valleys are punctuation. The transition
is the actual phase."

Does this change what we're building? Should Peak/Valley be
rare events (punctuation) and Transition be the dominant label?

## For the debaters

Respond to these tensions. Converge on:
1. ONE approach: threshold, input smoothing, or both
2. ONE target distribution (phases per 1000 candles)
3. Confirmation: yes/no, and if yes, how many candles
4. Does Hickey's punctuation framing change anything?
