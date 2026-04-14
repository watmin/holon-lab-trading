# Review: Hickey

The builder measured. 34% single-candle phases. A phase change every
3 candles. That's honest. Most proposals arrive with a solution and
work backward to justify it. This one arrives with a measurement and
says "I don't know." That's the right starting point.

But I want to challenge the premise before answering the questions.
The proposal frames this as a smoothing problem. I think it's a
concept problem.

---

## 2. Should the labeler have a minimum phase duration?

No.

A minimum duration is a filter bolted onto a broken classifier. If the
classifier produces phases that last one candle, the classifier is wrong.
Clamping its output to "at least 3 candles" doesn't make it right — it
makes it wrong *and* delayed. You've added latency without adding signal.

Think about what a minimum duration actually does. The labeler says
"peak" on candle N. Then "valley" on candle N+1. With a minimum-3 rule,
the labeler holds "peak" through N+1 and N+2 even though it already
knows it's wrong. Every downstream consumer — the Sequential, the phase
scalars, the boundary weight — gets a label the labeler itself doesn't
believe. You're lying to your own system for three candles.

The real question is: why does the labeler change its mind every candle?
Because the threshold is too small relative to the noise. That's a
threshold problem, not a duration problem. Fix the classifier. Don't
clamp its output.

---

## 3. Is the architecture right?

The two-state machine (Rising/Falling) with derived labels is fine. It's
a zigzag detector with an ATR-based reversal threshold. Zigzag is one of
the oldest tools in technical analysis. The architecture isn't the problem.

The problem is what you're asking it to detect.

At 1.0 ATR on 5-minute candles, you're asking: "has price moved one
average-candle-range from its extreme?" That's not a structural question.
That's a noise question. A 5-minute candle's range IS noise at the
structural level. You're detecting candle-scale wiggles and calling them
phases.

The proposal mentions Wyckoff's adaptive approach (percentile of recent
swings). That's closer, but it's still parameterizing the same concept.
The concept is: "how big must a reversal be to count?" Every answer to
that question is arbitrary at a single timescale.

Here's what I'd actually consider: the labeler doesn't need to change.
The *input* needs to change. Right now you feed it raw 5-minute closes.
What if you feed it a smoothed series? Not smoothed-then-labeled (which
adds lag). Rather: the labeler runs on the same 5-minute tick, but
instead of `close`, it sees `ema(close, 12)` or even `ema(close, 48)`.
The smoothing happens in the *input*, not in the *threshold* and not in
the *output*. The state machine stays simple. The question it answers
changes from "did this candle move?" to "did the trend move?"

That separates two concerns the current design conflates:
1. What timescale of structure am I detecting?
2. How do I detect structure at that timescale?

Right now both are controlled by the single `smoothing` parameter. The
ATR multiplier controls both the noise floor AND the structural scale.
They shouldn't be the same knob.

---

## 5. Should the Sequential encode all phases or filter?

The Sequential should encode what it receives. It's an encoder, not a
curator.

If you put filtering in the Sequential, you've given it a policy. Now
it decides what matters. That decision belongs upstream — in the labeler
or in what the labeler sees. The Sequential's job is to turn a sequence
of phase records into geometry. If the phase records are noise, the
Sequential faithfully encodes noise. That's correct behavior. The bug
is in the records, not the encoder.

This is the general principle: don't put intelligence in the pipe.
The pipe transforms. The source decides what enters the pipe. If the
source is noisy, fix the source.

There's a deeper issue. If you filter "insignificant" phases from the
Sequential, you need a definition of "significant." That definition is
itself a model — a model of what the market cares about. Now you have
two models: the labeler (which decides what a phase is) and the filter
(which decides what a phase means). Two models that must agree on what
structure is. That's complecting. One model, one opinion, one place to
fix it.

---

## 6. Does the phase labeler belong at 1.0 ATR at all?

This is the real question and the proposal almost reaches it.

The 5-minute candle is not the wrong timescale. It's the timescale you
have. You can't change it — 5-minute candles are what the exchange gives
you. But the labeler doesn't have to operate at the timescale of the
data. It can operate at any timescale that can be derived from the data.

Three options, in order of simplicity:

**Option A: Smooth the input.** Feed `ema(close, N)` to the labeler
instead of `close`. The labeler keeps its 1.0 ATR threshold. But ATR
is computed on the smoothed series, not the raw series. This filters
noise before classification. N becomes the timescale knob. The threshold
stays structural. No architectural change — just wire a different input.

**Option B: Scale the threshold.** Use 2.0 or 3.0 ATR. This is the
blunt instrument. It works, but it conflates "how big is noise?" with
"what timescale of structure do I care about?" You'll be back here in a
month tuning the multiplier.

**Option C: Multi-scale.** Run two labelers on different inputs. One on
`ema(close, 12)` (short structure), one on `ema(close, 48)` (longer
structure). Two phase streams. Two Sequential thoughts. Let the observer
see both and let the reckoner decide which matters.

Option A is the one I'd do first. It requires zero architectural change.
The indicator bank already computes EMAs. You already have `ema_20` on
the candle. Feed that to the labeler instead of `close`. Measure the
phase distribution. If 34% single-candle phases drops to 10%, you have
your answer. If it doesn't, the problem is deeper than smoothing.

Option C is where this eventually goes — it has to, because question 2
in the proposal is correct: the market has structure at multiple scales.
But don't build multi-scale until single-scale works. Right now
single-scale is broken. Fix it first.

---

## The deeper observation

The proposal says "the builder doesn't trust the phases." That's the
right instinct. But the distrust isn't about the smoothing parameter.
It's about what the labeler is classifying.

A phase is a *regime* — a period where the market behaves consistently.
Trending up. Consolidating. Breaking down. These persist for tens or
hundreds of candles, not one or two.

What the labeler currently detects is not regimes. It's reversals —
the point where price turns. A peak is "price just turned from going up
to going down." A valley is the opposite. Reversals are events. Regimes
are durations. The labeler is producing events at the rate it should
produce durations.

That's why 34% are single-candle. The labeler correctly identifies that
price bumped off a local extreme. It incorrectly calls that a "phase."
A bump is not a phase. A phase is what happens between bumps.

The fix might not be smoothing at all. It might be relabeling. What if
the labeler emits the *transition* as the primary label, and the peak/
valley as punctuation? Right now the distribution is roughly Valley 33%,
Peak 33%, Transition 33%. What if Transition is the phase and Peak/Valley
are the boundaries? Then a "phase" is "the stretch between the last
reversal and the next one" — and that stretch is the thing that persists,
the thing that has duration, the thing worth encoding in a Sequential.

That's a concept change, not a parameter change. And it might be the
one that matters.
