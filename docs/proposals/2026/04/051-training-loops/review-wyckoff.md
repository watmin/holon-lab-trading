# Review: Wyckoff

I have read the tape across proposals 043 through 050 and studied
the code that implements what the proposal describes. Here are my
answers to the six questions.

---

## 1. Are the training labels honest?

The market observer's label is honest but shallow. Directional
accuracy -- did price go up or down from entry -- is a fact. It
is the simplest possible fact about the market. A tape reader
would not object to it, but would observe that it discards the
*character* of the move. A 0.01% creep upward and a 3% surge
both get labeled "Up." The observer cannot learn that the surge
was the real information. It learns direction stripped of effort.

The position observer's label is where the trouble lives. The
rolling percentile median for journey grading is a self-
referential benchmark. When the observer improves, the median
improves, and everything that was previously Grace becomes
Violence. This is not honest grading -- it is a moving goalpost.
The oscillation to 0.0 grace_rate described in question 3 is
the expected behavior of this design, not a bug. A rolling
percentile over your own predictions will always converge to
labeling exactly half your predictions as Violence, and if the
distribution of errors is lumpy (as it will be across market
regimes), you get long stretches where everything exceeds the
median. The label is measuring self-consistency, not market
truth.

The broker's label -- Grace/Violence from paper outcomes -- is
the most honest of the three. Did money flow in or flow out?
This is the tape. The tape does not lie. But the broker
composes its thought from the other two observers, so it is
learning accountability over unreliable inputs.

**Verdict:** Market labels are honest but information-poor.
Position labels are dishonest by construction. Broker labels
are honest but downstream of the dishonesty.

---

## 2. Is weight modulation the right coupling?

Yes. The 2x weight at phase boundaries is exactly the right
level of coupling. A tape reader would say: the character of
the market changes at the turn. The candles at the turn carry
more information per unit time than candles in the middle of
a trend. The market observer should pay more attention to those
candles without needing to know WHY they matter.

The market observer's job is to read the tape -- the raw
character of each candle through its lens. If you feed it
phase labels directly, you are telling it what the tape means
before it reads the tape. You are replacing observation with
instruction. The observer would learn to parrot the phase
label instead of discovering the structure in momentum,
volume, regime.

Weight modulation preserves the observer's independence. It
says: "this candle matters more." It does not say why. The
observer must discover the why from its own vocabulary. This
is correct.

However, 2x is arbitrary. The information density at a
confirmed phase turn is not twice the mid-phase density --
it may be 5x or 10x. The weight should reflect how rare and
informative the boundary is relative to the base rate. If
phases average 6 candles, the boundary candle is 1 in 6, and
the weight should be proportional to the inverse of that
frequency -- approximately 6x, not 2x. Or better: let the
boundary weight be a function of the *duration* of the phase
that just ended. A turn after a 20-candle trend carries more
information than a turn after a 3-candle chop.

---

## 3. The position observer's grace_rate oscillates to 0.0

This is a grading problem, not a distance-prediction problem.

The rolling percentile median is the wrong benchmark for
Grace/Violence. Here is why: the error ratio (predicted
distance vs optimal distance) is a measurement of calibration,
not of market truth. When the position observer gets better at
predicting distances, the errors shrink, the median shrinks,
and suddenly half the population sits above the new median.
Then the observer learns from Violence signals, adjusts, the
median moves again. This is a control system chasing its own
tail.

A tape reader would say: grade the position observer against
the MARKET, not against itself. The question is not "was this
prediction better than my median prediction?" The question is:
"did this distance setting result in the trade capturing the
available move?"

Concrete proposal: replace the rolling percentile with a
market-derived benchmark. The excursion ratio -- how much of
the available phase move did the paper capture before
resolving? If the phase moved 3% and the paper captured 2%,
that is Grace (66% capture). If the phase moved 3% and the
paper captured 0.2%, that is Violence (7% capture). The phase
labeler already provides the phase's range (close_max -
close_min). Use it. The benchmark should be external to the
observer.

---

## 4. Papers live ~8 candles and resolve 41% Grace

Eight candles is 40 minutes on a 5-minute chart. This is
scalper territory. A tape reader would observe that 40 minutes
is too short to capture a phase. If phases average 6 candles
(30 minutes) and papers live 8, the paper barely survives one
phase transition. It cannot learn anything about the SEQUENCE
of phases -- valley into transition into peak. It dies in the
middle.

The 41% Grace rate is the tape telling you this. More papers
resolve as Violence than Grace because the paper's stop gets
hit before the phase completes its natural arc. The paper is
fighting the noise within a phase instead of riding the phase.

A tape reader would not fix the paper lifecycle. A tape reader
would observe that the paper's exit distances need to be
calibrated to the phase's natural scale. The trailing stop
should be at least one phase's worth of smoothing (1 ATR per
the labeler). The safety stop should survive the normal
retracement within a transition. If the paper's distances are
smaller than the phase's noise floor, the paper will always
die to noise.

The hold architecture from Proposal 038 is the right direction
if it means "hold through the phase, resolve at the phase
boundary." But extending paper life without extending the
stop distances just means dying slower.

---

## 5. Should the broker think about phases directly?

No. The broker's job is accountability -- did this (market,
position) pairing produce residue? The portfolio biography
already carries the phase structure as derived facts: valley
trend, peak trend, regularity, entry ratio, spacing. These
are the right atoms for the broker.

The broker should not have its own phase atoms because the
broker is not reading the tape. The broker is reading its own
ledger. "Did I enter at favorable phases?" (entry-ratio) is a
broker question. "Is the market in a valley?" is an observer
question. The boundary is correct.

What the broker SHOULD think about, and currently does not,
is the *concordance* between its observers. The market observer
predicted Up. The position observer set distances for a certain
move size. Did those two predictions agree in scale? A market
observer predicting a weak Up and a position observer setting
wide trailing distances is a disagreement. The broker should
feel that disagreement as a fact. This is effort vs result at
the observer level: did the effort of the market prediction
match the result of the position distances?

---

## 6. What's missing?

Three things.

### A. Volume-price divergence at phase boundaries

The phase labeler classifies from price alone. It tracks
volume_avg per phase but does not use volume in the detection.
A tape reader's primary tool is effort vs result: volume is
the effort, price movement is the result. When volume increases
but the price fails to extend -- that is exhaustion. When the
price extends on diminishing volume -- that is distribution
masquerading as markup.

The system has OBV, MFI, volume SMA, and volume acceleration
on the candle. But none of these are compared to the phase
structure. The missing signal is: what did volume do DURING
this phase compared to the PREVIOUS phase of the same type?
Did the latest peak have more volume than the previous peak
(confirmation) or less (distribution)? Did the latest valley
have more volume than the previous valley (capitulation --
accumulation starting) or less (just a pullback)?

This is the Wyckoff cycle. Accumulation: valleys with
increasing volume, peaks with decreasing volume. Distribution:
peaks with increasing volume, valleys with decreasing volume.
The phase labeler has the phase records. The phase records
have volume_avg. Nobody computes the cross-phase volume
comparison. This should be a set of atoms on the position
observer's phase vocabulary or the broker's portfolio
biography:

- `volume-valley-trend`: ratio of latest valley volume to
  previous valley volume
- `volume-peak-trend`: ratio of latest peak volume to previous
  peak volume  
- `volume-effort-ratio`: (volume change) / (price change)
  across consecutive phases -- effort vs result as a scalar

### B. The accumulation/distribution phase

The labeler has three labels: valley, peak, transition. This
is the price structure. But the Wyckoff cycle has four phases:
accumulation, markup, distribution, markdown. The system's
three labels map roughly to valley=accumulation/markdown-end,
peak=distribution/markup-end, transition=markup/markdown. But
the mapping is lossy because it ignores the *sequence context*.

A valley AFTER a long markdown with increasing volume on the
valley is accumulation. A valley AFTER a short transition with
decreasing volume is just a pullback. Same label, different
meaning. The system encodes the Sequential of phase records,
which should in principle capture this. But the learners would
need many observations to discover that the PATTERN of phases
matters, not just the current phase.

What would help: a derived atom that measures the Wyckoff
position explicitly. Count the last N phase records. Compare
volume trends across valleys vs peaks. If valley volume is
rising and peak volume is falling, label it "accumulation
zone." If peak volume is rising and valley volume is falling,
label it "distribution zone." This is not a new learner -- it
is a new fact on the candle, derived from the phase history,
that the observers can think about. The reckoner discovers
whether it predicts.

### C. The missing feedback loop: phase-outcome correlation

No component currently asks: "When I enter during an
accumulation pattern, what is my Grace rate? When I enter
during distribution, what is my Grace rate?" The broker
tracks entry-ratio (fraction of entries in favorable phases)
but does not track the OUTCOME conditional on phase type.

The broker should maintain per-phase-type statistics:
grace_rate_at_valley, grace_rate_at_peak,
grace_rate_at_transition. This gives the broker the ability
to discover that entering at valleys during accumulation is
profitable and entering at peaks during distribution is
catastrophic. Currently the broker sees the aggregate
Grace/Violence rate without knowing which phase type
contributed to it.

This is a training signal that exists implicitly in the data
but has no explicit path to a learner. The broker resolves
papers and knows what phase the entry was in (from
entry_candle vs phase_history). It just does not accumulate
that knowledge into atoms the reckoner can use.

---

## Summary for the builder

The infrastructure is sound. The wiring is correct. The phase
labeler is a good structural classifier. Three things are
stopping the system from learning the Wyckoff cycle:

1. **The position observer grades itself against itself.**
   Replace the rolling percentile with a market-derived
   benchmark (phase capture ratio).

2. **Volume is absent from the phase analysis.** The
   cross-phase volume comparison is the heart of
   accumulation/distribution detection. Add volume trend
   atoms to the phase vocabulary.

3. **No component explicitly models the Wyckoff position.**
   The sequence of phase records contains the information
   but no fact extracts it. A derived accumulation/distribution
   atom -- computed from the volume-price divergence across
   consecutive phases -- would give every observer the ground
   truth about where the market is in its cycle.

The system reads the tape. It just does not yet read the
volume column of the tape.
