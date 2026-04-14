# Review: Wyckoff

The builder has read the tape of his own machine and found what
every tape reader finds when the filter is too fine: noise
masquerading as signal. A phase that lasts one candle is not a
phase. It is a tick. The machine is calling every ripple a wave.

I have read the proposal, the phase labeler implementation in
`src/types/pivot.rs`, the encoding in `src/vocab/exit/phase.rs`,
and the original Proposal 049 where this design was born. Here
are my answers to the six questions.

---

## 1. Is 1.0 ATR the right smoothing?

No. And I said this in my review of 049. ATR measures the size of
individual candles — the noise floor of the tape. A smoothing of
1.0 ATR means "a move must exceed one typical candle to be a
turn." But one typical candle is NOT a structural event. It is a
breath. The market breathes in and out by one ATR routinely. That
is what ATR measures — the routine.

The measurement proves it: 34% single-candle phases. The smoothing
confirms turns that are barely larger than a single candle's range.
Of course the labeler sees a turn every 3 candles. It is calibrated
to see turns at the scale of individual candles. That is not
structure. That is resolution.

The right smoothing for 5-minute BTC is not a fixed multiple of
ATR. It is the 50th percentile of recent CONFIRMED swing sizes,
as I recommended in 049. But the builder chose 1.0 ATR, and now
the measurement shows what that choice costs.

If the builder insists on ATR-based smoothing rather than
adaptive, the multiple must be at least **2.5 ATR**. Here is why:

A structural turn on 5-minute BTC requires the price to traverse
the noise floor (1 ATR), overshoot (another 0.5-1.0 ATR), and
then reverse demonstrably (another 1.0 ATR from the extreme).
The total displacement from the prior extreme that confirms a
real turn is roughly 2.5 ATR. Below that, you are measuring the
market's breathing. Above that, the market has made a decision.

At 2.5 ATR, if ATR is $20, the threshold is $50. A $50 move on
5-minute BTC is not a candle — it is a campaign of 5-15 candles.
That is the minimum grain of a structural phase.

But I still say: use the adaptive percentile. The market knows
what a meaningful swing is. We do not. Let the market define it.

---

## 2. Should the labeler have a minimum phase duration?

Yes. But the minimum duration is a CONSEQUENCE of the correct
smoothing, not an independent parameter. If the smoothing is
right, one-candle phases become mathematically impossible —
the price cannot traverse 2.5 ATR in a single 5-minute candle
under normal conditions.

Adding a minimum duration as a separate parameter is a patch.
It hides the symptom without curing the disease. The disease
is that the smoothing is too small. Fix the smoothing and the
duration distribution follows naturally.

That said, there is one case where a minimum duration guard is
justified: the flash crash. A $500 drop in one candle followed
by a $500 recovery in the next would correctly trigger two
phase changes at any smoothing level. That is not a phase —
it is a spasm. A minimum of **3 candles** before a phase can be
confirmed prevents spasms from entering the phase record. Three
candles is 15 minutes. If the market cannot sustain a direction
for 15 minutes, it has not made a structural decision.

Implementation: do not suppress the phase DETECTION. Let the
state machine track the extreme normally. But do not CLOSE the
prior phase and OPEN a new one until the new direction has
persisted for 3 candles. This preserves the tracking accuracy
(the extreme is still correct) while preventing the record from
filling with debris.

---

## 3. Is the architecture right?

The two-state architecture (Rising/Falling) with derived labels
is the correct skeleton. It mirrors how a tape reader works:
you track the direction of the campaign and you measure where
the price is relative to the extreme. The three labels fall out
naturally.

The problem is not the architecture. The problem is the
threshold. The architecture is a zigzag filter. Every zigzag
filter has a minimum swing parameter. Your minimum swing
parameter is 1.0 ATR. That is too small for structure on
5-minute candles.

A multi-scale labeler — running the same algorithm at multiple
smoothing levels — is architecturally elegant but operationally
premature. The machine cannot yet learn from ONE scale of phases.
Adding three scales triples the vocabulary and triples the noise
that the reckoner must sort through. Master one scale first. The
correct scale. Then add others.

If the builder wants hierarchy later, the architecture supports
it naturally: run one PhaseState at 2.5 ATR (tactical — the
5-15 candle swing) and another at 10 ATR (strategic — the
50-200 candle trend). The position observer sees both. But that
is Proposal 053 or 054, not 052. Solve the single-scale problem
first.

---

## 4. What does a good phase distribution look like?

A tape reader thinks in campaigns. An accumulation campaign on
5-minute BTC lasts 2-8 hours (24-96 candles). A markup lasts
1-4 hours (12-48 candles). A distribution campaign mirrors
accumulation. A markdown mirrors markup.

The full Wyckoff cycle at the 5-minute scale is roughly 200-400
candles (16-33 hours). This means:

- **Phases per 1000 candles:** 8-20. Not 340. Each cycle has
  4 phases, so 2-5 complete cycles per 1000 candles. Currently
  the labeler produces 340 phase changes per 1000 candles — 17x
  to 42x too many.

- **Minimum duration that carries signal:** 8-10 candles
  (40-50 minutes). Below that, the phase has not had time to
  develop the internal structure that distinguishes accumulation
  from noise: the tests, the volume profile, the range
  compression. A 3-candle "valley" tells you nothing about
  whether supply has been absorbed. It tells you the price
  dipped and bounced. That is a candle pattern, not a phase.

- **Median phase duration:** 25-50 candles (2-4 hours). This is
  what a genuine structural phase looks like on 5-minute BTC.
  The current median is ~2.4 candles. That is two orders of
  magnitude too short.

The builder should measure the phase distribution at 2.5 ATR
smoothing and compare. If the median rises to 15-30 candles and
phases per 1000 drops to 20-40, the labeler is approaching
structural resolution. If it is still too chatty, increase to
3.0 ATR.

---

## 5. Should the Sequential encode ALL phases or only significant ones?

Encode all of them — at the correct smoothing. If the smoothing
is right, every phase IS significant. That is what "correct
smoothing" means: the filter has already removed the noise. The
phases that survive are the ones the market confirmed through
sustained movement exceeding the threshold.

If you filter before encoding, you have two filters in series —
the smoothing and the significance test. Two filters means two
parameters. Two parameters means two things to tune. Two things
to tune means the builder will spend his time tuning filters
instead of reading the tape. One filter. One threshold. One
creek. The phases that cross the creek are real. Encode them all.

The Sequential should see 4-10 recent phases, not 20 one-candle
flickers. That is what happens naturally when the smoothing is
correct. The 20-element history buffer currently holds 20 phases
spanning roughly 60 candles (20 phases x ~3 candles each). At
correct smoothing, 20 phases would span 500-1000 candles (20
phases x 25-50 candles each). That is 40-80 hours of market
structure in one Sequential thought. That is enough context to
see two full Wyckoff cycles. That is what the reckoner needs.

---

## 6. Does the phase labeler belong at 1.0 ATR at all?

The question answers itself. No. But the question behind the
question is: does the phase labeler belong on 5-minute candles
at all?

Yes. The 5-minute candle is the right input. But the SMOOTHING
must operate at a higher structural level than the candle. This
is not a contradiction. You read every tick of the tape, but you
identify campaigns that span thousands of ticks. The resolution
of your input is not the resolution of your judgment.

Running the labeler on hourly closes would discard 11 out of
every 12 data points. The labeler would miss the spring — the
sharp intracandle test of the low that confirms accumulation.
It would miss the upthrust — the false breakout that confirms
distribution. These events happen on 5-minute candles. They are
invisible on hourly candles.

Running on a smoothed price series (EMA of closes, for example)
would introduce lag. The phase boundaries would be delayed by
the smoothing period of the EMA. The labeler would confirm the
valley 5-10 candles after the tape reader already saw it. The
exit observer would set distances based on stale structure. Lag
kills.

The correct answer: raw 5-minute closes with a structural
smoothing threshold of 2.5 ATR or the adaptive percentile. The
candle is the input. The smoothing is the judgment. They operate
at different scales by design. Do not sacrifice the input to
match the judgment. Raise the judgment to match the structure.

---

## The prescription

The builder measured a 34% single-candle phase rate and correctly
identified it as noise. The cure is one change:

**Increase the smoothing from 1.0 ATR to 2.5 ATR.**

Measure again. The single-candle phase rate should drop below
5%. The median phase duration should rise above 10 candles. The
phase count per 1000 candles should drop below 50.

If the builder prefers the adaptive approach: take the 50th
percentile of the last 20 confirmed swing sizes as the smoothing
threshold. This self-calibrates. In quiet markets the threshold
contracts. In volatile markets it expands. The market defines
what a meaningful swing is. We listen.

Do not add a minimum duration parameter. Do not add a
significance filter. Do not build a multi-scale labeler. Do not
smooth the input. Fix the one parameter that is wrong. Then
measure. The tape will tell you if it is enough.

One number. One measurement. That is how you read the tape.
