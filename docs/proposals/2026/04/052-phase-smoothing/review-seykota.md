# Review: Seykota

I look at your phase distribution and I see a system that is
trying to trade every ripple in a pond. 34% single-candle phases.
A phase change every 3 candles. That is not a trend following
system. That is a noise amplifier.

The market is doing what it always does. It trends, and between
trends it chops. Your labeler cannot tell the difference. It
treats a 1-candle wiggle the same as a 200-candle move. Both
get a phase. Both get encoded. Both get learned from. The
reckoner is drinking from a firehose of nothing.

Here is what I see in the data, and here are your answers.

---

## 1. Is 1.0 ATR the right smoothing?

No. 1.0 ATR at 5-minute resolution is one candle of noise. You
measured it yourself — ATR of $20 means a $10 threshold, and a
$10 move is a routine candle. The smoothing must be larger than
the noise.

But the answer is not 1.5 or 2.0. The answer is: **the smoothing
should be a function of the current chop.** When the market is
quiet, ATR is small and 1.0 ATR might work. When the market is
volatile, 1.0 ATR is nothing. The ratio of smoothing to noise
must stay constant. That means adaptive.

Start with 2.0 ATR as a floor and measure. Count phases per 1000
candles. If you still see more than 80-100 phase changes per 1000
candles, the smoothing is still too tight. A 5-minute candle
market with real structure should produce a phase change every
10-20 candles on average — that is 50-100 phases per 1000 candles.
You are at 340. You are 3-4x too sensitive.

---

## 2. Should the labeler have a minimum phase duration?

Yes, but not as a hard floor. A hard minimum of N candles creates
a different problem — it delays recognition of genuine turns by
exactly N candles, every time, even when the turn is real.

Instead: **require confirmation.** A new phase is not declared
until the move exceeds the smoothing threshold AND persists for
at least 2-3 candles. This is not a minimum duration — it is a
confirmation filter. A 1-candle spike that reverses immediately
never becomes a phase. A 1-candle spike that holds for 2 more
candles does. The market is telling you which moves are real.

The distinction matters. A minimum duration is a rule imposed on
the market. A confirmation filter is listening to the market.

---

## 3. Is the architecture right?

Two tracking states with derived labels is fine. The problem is
not the architecture. The problem is the threshold.

A zigzag with minimum swing size is the same idea wearing
different clothes — it still needs a threshold, and that threshold
has the same sensitivity problem. Multi-scale labelers are
interesting but premature. Fix the single-scale labeler first.
If you cannot make one scale work, adding more scales adds
confusion, not clarity.

The architecture is: track the trend, detect when it changes.
Two states (Rising/Falling) with a threshold to declare a change.
That is correct. The threshold is wrong. Fix the threshold.

---

## 4. What does a good phase distribution look like?

You have:
```
1 candle:     34.2%
2 candles:    20.8%
3-5 candles:  29.4%
6-10 candles: 12.8%
11-20:         2.8%
20+:           0.1%
```

A good distribution looks like a power law that starts at 3-5,
not at 1:
```
1-2 candles:   < 10%    (noise that leaked through)
3-5 candles:   25-30%   (short-term structure)
6-15 candles:  35-40%   (the bread and butter)
16-40 candles: 15-20%   (real swings)
40+:           5-10%    (the trends that pay for everything)
```

The key metric: **median phase duration should be 5-10 candles.**
Your median is around 2. That tells you everything. When the
median phase is shorter than your lookback, every pattern the
reckoner finds is a pattern in noise.

Aim for 50-100 phase changes per 1000 candles. You are at 340.
Cut it by 3x-4x.

---

## 5. Should the Sequential encode ALL phases or only significant ones?

Encode all of them. But fix the labeler first so "all of them"
means something.

If you filter at the Sequential, you are building a second labeler
inside the encoder. Two labelers with two thresholds, and now you
have to tune both. That is complexity without insight.

The labeler's job is to say what is real. The Sequential's job is
to encode what the labeler says. The reckoner's job is to find
patterns in what the Sequential encodes. Each does one thing.
If the labeler is wrong, fix the labeler. Do not patch downstream.

Once the labeler produces phases with a median duration of 5-10
candles, the Sequential will encode 50-100 phases per 1000 candles.
That is learnable. The reckoner can find structure in that. It
cannot find structure in 340 coin flips per 1000 candles.

---

## 6. Does the phase labeler belong at 1.0 ATR at all?

The 5-minute candle is the right input. Do not smooth the price
series or aggregate to hourly. You lose information. The labeler
should see every candle — it just should not react to every candle.

The problem is not the timeframe. The problem is that 1.0 ATR at
5-minute resolution is a threshold of approximately one candle of
noise. Raise the threshold to 2.0-2.5 ATR and add the confirmation
filter from question 2. The labeler will still see every 5-minute
candle. It will just stop calling every wiggle a trend change.

Running on hourly closes is the same as using a 12x larger
smoothing (twelve 5-minute candles per hour). You can get the
same effect by raising the ATR multiplier. But you keep the
resolution. You keep the ability to detect a genuine intra-hour
reversal that moves 2.5 ATR in 15 minutes. Aggregation destroys
that.

---

## The trend follower's summary

You have a trend detection system that cannot see trends because
it is distracted by every tick. The fix is simple and it is not
architectural:

1. Raise the ATR multiplier to 2.0-2.5
2. Add a 2-3 candle confirmation filter
3. Measure the phase distribution again
4. Target: median phase duration 5-10 candles, 50-100 changes per 1000

Do not add complexity. Do not build multi-scale systems. Do not
filter downstream. Fix the threshold. Measure. Adjust. The market
will tell you when you have it right — the phase distribution will
look like a power law starting at 3-5 candles instead of a
geometric distribution starting at 1.

The trend is your friend. But first you have to be able to see it.
