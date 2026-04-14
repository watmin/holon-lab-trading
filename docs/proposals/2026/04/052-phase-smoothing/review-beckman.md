# Review: Beckman

I've read the proposal and the implementation (`src/types/pivot.rs`,
`src/domain/indicator_bank.rs` line 1856). Let me take the questions
in order, then say what I actually think is going on.

## 1. Is 1.0 ATR the right smoothing?

No, and the measurement proves it. But the question is slightly
mis-framed. The issue is not "1.0 vs 1.5 vs adaptive." The issue
is the relationship between the smoothing parameter and the
*minimum resolvable structure* of your state machine.

Your machine has two tracking states. The transition threshold is
`smoothing` (1.0 ATR). The label threshold is `smoothing / 2`.
That means the machine can resolve structures whose amplitude is
at least 1 ATR, and it labels the top/bottom half of that
amplitude as Peak/Valley respectively.

For 5-minute BTC candles, 1 ATR is roughly 1 candle's range. So
your minimum resolvable structure is... one candle. That's not a
design choice. That's the Nyquist limit telling you that your
sampling rate equals your filter bandwidth. Of course you get 34%
single-candle phases. You're asking the machine to detect structure
at the resolution of noise.

**The math is right.** The implementation correctly does what the
spec says. The spec is asking for the wrong thing.

## 2. What does the distribution tell you?

The distribution is diagnostic. Let me be precise about what it
says.

If your phase durations followed a geometric distribution (each
candle has independent probability p of ending the phase), you'd
expect the fraction of 1-candle phases to equal p, the fraction
of 2-candle phases to equal p(1-p), and so on. The observed
distribution:

```
1 candle:  34.2%
2 candles: 20.8%
3-5:       29.4%  (~9.8% per bucket)
6-10:      12.8%  (~2.6% per bucket)
11-20:      2.8%  (~0.3% per bucket)
20+:        0.1%
```

If this were geometric with p = 0.34, the expected 2-candle
fraction would be 0.34 * 0.66 = 22.4%. You observe 20.8%. Close
enough. The 3-5 range should be ~32%. You observe 29.4%. Still
plausible.

This is the signature of a memoryless process. Your phase
labeler is behaving almost exactly like a coin flip at each
candle. The "structure" it detects is statistically
indistinguishable from noise at this smoothing level.

The deviation from geometric in the tail (6-10 and 11-20 are
slightly heavier than geometric would predict) is the actual
signal. Those longer phases are the real structure. They survive
because the market occasionally trends hard enough that even a
noise-level filter can track it.

**The distribution tells you: at 1.0 ATR, approximately 55% of
your phases are noise (durations 1-2), and approximately 45%
contain some signal (durations 3+). Your labeler is operating
at roughly 3 dB SNR.**

## 3. Is there a principled way to derive smoothing from data?

Yes. Several ways, in increasing order of elegance.

### A. Empirical: the survival function

Plot the survival function S(d) = P(duration > d). For a
geometric (noise) process, log S(d) is linear. Where the
empirical survival function departs from the geometric fit is
where structure begins. Set your smoothing so that the minimum
phase duration lands at that departure point.

Concretely: fit a geometric to durations 1-3 (the noise
regime). Find the duration d* where the observed survival
exceeds the geometric prediction by some threshold (say 2x).
Then adjust smoothing so that d* becomes your shortest phase.

### B. Information-theoretic: entropy rate

Compute the entropy rate of the phase label sequence at
different smoothing values. At very low smoothing, the sequence
is nearly i.i.d. (high entropy rate, no predictability). At very
high smoothing, you get very few phases (low entropy rate, but
also low information). The optimal smoothing maximizes the
*mutual information* between past phases and future price
movement. This is the smoothing where the labeler is most
useful as a predictor.

You can approximate this: for each candidate smoothing s, run
the labeler, compute the phase sequence, measure the conditional
entropy H(next_price_direction | last_N_phases). The smoothing
that minimizes this conditional entropy is your answer.

### C. Algebraic: the ATR multiplier as a filter

Your state machine is a nonlinear filter. The smoothing
parameter is the bandwidth. ATR is the noise floor estimate. The
multiplier k in `smoothing = k * ATR` controls the SNR:

- k = 1.0: bandwidth equals noise floor (SNR ~ 1, you resolve
  noise as structure)
- k = 2.0: bandwidth is 2x noise floor (SNR ~ 2, you miss
  some real moves but stop hallucinating)
- k = 3.0: you only see major trends

The classical result from detection theory: for a two-state
detector with Gaussian-ish noise, you want the threshold at
roughly 2 sigma to get a reasonable false-alarm rate. ATR is
not quite sigma (it's the average absolute range, which for
normal data is ~1.25 sigma), but as a rule of thumb:

**k = 1.5 to 2.0 is the principled range.**

At k = 1.5, your expected minimum phase duration rises from
~1 candle to ~3-4 candles (because the price must traverse 1.5
ATR to trigger a transition, which takes ~2-3 candles of
trending). At k = 2.0, minimum duration rises to ~4-6 candles.

This matches your intuition that single-candle phases aren't
structure.

## 4. What does a good distribution look like?

A good distribution has these properties:

1. **Very few 1-candle phases.** Ideally < 5%. A 1-candle phase
   means the labeler changed its mind on the very next sample.
   That's a false alarm by definition.

2. **Modal duration of 3-8 candles.** This is the sweet spot
   where the labeler captures genuine short-term structure
   without being noise.

3. **Fat tail.** Durations 20+ should be 5-15% of all phases.
   The market does trend. A good labeler captures those trends
   as single long phases, not as a sequence of short ones.

4. **~100-150 phase changes per 1000 candles** (not 340). A
   phase change every 7-10 candles means the labeler is
   resolving structure at the scale of 35-50 minutes on 5-minute
   data. That's a meaningful timescale for intraday BTC.

For reference, a zigzag filter with 2.0 ATR threshold on BTC
5-minute data typically produces 80-120 swings per 1000 candles
with a modal duration of 5-8.

## The deeper question

The proposal asks whether the architecture is right (question 3
in the proposal). Let me address this directly.

The two-state machine is fine. It's a Schmitt trigger. That's a
well-understood and robust structure for detecting level crossings
in noisy data. The problem is not the architecture. The problem
is that you have one Schmitt trigger at one bandwidth, and you're
asking it to see structure at all scales.

You have two good options:

**Option A: Raise the threshold.** Set k = 1.5 or k = 2.0.
Accept that you lose some genuine short-term structure. The
reckoner will learn better from cleaner phases. This is the
minimal change.

**Option B: Multi-scale.** Run two or three labelers at
different k values (say 1.0, 2.0, 4.0). Each observer gets
phases at the scale it cares about. The momentum observer might
want k = 1.0 (it cares about micro-structure). The structure
observer might want k = 2.0 (it cares about swings). The regime
observer might want k = 4.0 (it cares about trends). This is
more work but it's the correct answer to "the market has structure
at multiple scales."

I would not do a minimum phase duration. That's a band-aid that
throws away information without addressing why the information
was garbage. If the phases are too short, the filter bandwidth
is wrong. Fix the filter, not the output.

I would not filter phases before encoding in the Sequential.
The Sequential's permutation-based ordering is sensitive to
sequence length. Dropping items changes the geometry in ways
that are hard to reason about. Better to give it clean phases
from a correctly-tuned filter.

## Summary

The math is correct. The distribution is diagnostic: it says
you're operating at the noise floor. The principled fix is to
raise the ATR multiplier to 1.5-2.0, which you can validate by
checking that single-candle phases drop below 5% and the phase
duration survival function shows a clear departure from geometric.
The elegant fix is multi-scale labeling, one per observer lens.

-- Brian Beckman
