# Review: Seykota / Verdict: CONDITIONAL

Conditional on ATR-based smoothing and one missing attribute.

## General

This is a good proposal. It does one thing. It labels. It does
not predict. It does not trade. That discipline is rare and I
respect it.

The three-phase model (valley, transition, peak) maps directly
to how I read markets. The transition IS the trend. You ride it.
The valley is where you get on. The peak is where the market
tells you the ride is over. The fact that you are labeling zones
and not points means you understand that turns take time.

Now the questions.

## 1. Smoothing: ATR-based, fixed percentage, or adaptive? How much?

**ATR-based. Option A. 1.0x ATR. No contest.**

A fixed percentage is a lie you tell yourself about the market.
BTC at 0.5% smoothing in a 2% ATR environment filters nothing.
BTC at 0.5% smoothing in a 0.1% ATR environment filters
everything. The parameter means different things on different
days. That is not a parameter. That is a source of confusion.

The adaptive percentile (Option C) is clever but circular. You
are using recent swing sizes to define what counts as a swing.
During a compression, your swings shrink, your threshold shrinks,
you detect tiny swings inside the compression. During an
expansion, your threshold lags the new reality. It chases.

ATR breathes with the market because ATR measures what the market
is actually doing right now. Volatility IS the market's own
smoothing. When ATR is high, you need bigger reversals to confirm
a turn. When ATR is low, smaller moves matter. The market tells
you its own noise floor. Listen to it.

1.0x ATR. Not 0.5 (too sensitive, you will label noise as
structure). Not 2.0 (too sluggish, you will miss real turns
until they are old news). 1.0 is one day's range. A turn that
exceeds one day's range is a structural turn. Below that, it is
noise within the phase.

## 2. Peak/valley zone: how close to the extreme?

**The zone IS the smoothing distance. Full threshold.**

Your algorithm already does this correctly in the pseudocode.
When tracking a high, price must fall by the full threshold to
confirm the peak. Everything between the extreme and the
confirmation is "still near the high" -- that is the peak zone.
This is right.

Do not halve it. Half the threshold creates a dead zone between
the peak zone and the transition zone where the candle belongs
to neither. That is a fourth label you did not intend. Keep it
clean: within one ATR of the extreme = in the zone. Beyond one
ATR = transitioned.

The peak zone will naturally be wider in volatile markets (high
ATR) and tighter in quiet markets (low ATR). This is correct
behavior. In volatile markets, price thrashes around peaks
longer before committing. In quiet markets, even a small move
away from the extreme is meaningful.

## 3. What phase attributes matter most to a trend follower?

You have good attributes. But you are missing the most important
one. Let me rank them and add what is missing.

**What you have, ranked:**

1. **phase-move** (close-final minus close-open, normalized) --
   this is the displacement. How far did price actually travel
   during this phase? For transitions, this IS the trend's
   reward. For valleys and peaks, this should be near zero
   (price arrives and leaves at roughly the same level).

2. **phase-duration** -- time in the phase. A valley that lasts
   3 candles is a V-bottom. A valley that lasts 50 candles is
   accumulation. A transition that lasts 100 candles is a real
   trend. Duration distinguishes character.

3. **phase-range** (max minus min, normalized) -- the volatility
   within the phase. A transition with high range relative to
   its move is choppy. A transition with low range relative to
   its move is clean. Clean trends are easier to ride.

4. **phase-volume** -- confirms or denies the move. High volume
   at a valley is accumulation. High volume at a peak is
   distribution. High volume in a transition is conviction.

**What you are missing:**

5. **phase-speed** -- move divided by duration. You mention it
   in question 4 but do not include it in the struct. Add it.
   Speed is the derivative. It is what separates a grind from a
   spike and a slow top from a crash. Two transitions can have
   the same move and different speeds. Speed is not derivable
   from the other attributes because the move happens unevenly
   within the phase.

Actually, speed IS derivable (move / duration). So encode it
directly as a fact. The reckoner should not have to learn
division.

**What matters at each phase for a trend follower:**

- **At the valley:** duration (how long did it base?), range
  (how tight is the base?), volume (is someone accumulating?).
  A long, tight, high-volume valley is the strongest setup.

- **At the transition:** speed (is the trend accelerating or
  decelerating?), range-to-move ratio (is it clean or choppy?),
  duration (has it gone on long enough to be real?). A trend
  follower enters during the transition, not at the valley. The
  valley is only visible in hindsight. The transition confirms
  the valley was real.

- **At the peak:** duration (how long has it stalled?), volume
  (is distribution happening?), range (is it volatile or
  quiet?). A peak with expanding range and high volume is
  distribution. A peak with contracting range is a continuation
  pattern -- the next transition may resume the trend.

## 4. What distinguishes a slow grind from a sharp spike?

Three atoms. Not one.

**Speed** (move / duration): the primary discriminator. A grind
has low speed. A spike has high speed. Encode it as a `$log`
scalar, not `$linear`. The ratio between a spike and a grind
can be 10x or 100x. Log scaling captures that.

**Internal retracement count**: how many times during the
transition did price retrace more than, say, 0.25x ATR before
resuming? A grind has many small retracements. A spike has zero
or one. This is the "choppiness" of the transition. You do not
need to store each retracement -- just count them. One integer.
One atom.

**Volume profile -- front-loaded vs back-loaded**: a spike has
its highest volume at the start (the impulse). A grind has
roughly even volume throughout, or volume increases at the end
(the final push before the peak). Compare the average volume of
the first half to the average volume of the second half. One
ratio. One atom.

These three together (speed, retracement count, volume profile)
let the reckoner distinguish:

- **Impulse spike**: high speed, zero retracements, front-loaded
  volume. Often followed by a long peak (consolidation).
- **Slow grind**: low speed, many retracements, even volume.
  Often the most reliable trend. Higher highs, higher lows, all
  the way up.
- **Exhaustion move**: high speed, zero retracements, back-loaded
  volume. The blowoff top or the capitulation bottom. The phase
  after this is often the opposite extreme.

The reckoner does not need to learn these categories. It just
needs the atoms. The categories will emerge from the similarity
geometry.

## Summary

The proposal is sound. The three-phase model is correct. The
detection algorithm is correct. The encoding as thoughts is
correct. The connection to the 044 vocabulary is correct.

Three conditions:

1. **Use ATR-based smoothing at 1.0x ATR.** Not fixed, not
   adaptive.
2. **Add phase-speed as an explicit fact.** Move / duration,
   log-scaled.
3. **Add internal retracement count and volume profile ratio**
   to the transition phase. These distinguish the character of
   the move. Without them, all transitions look the same to the
   reckoner.

The labeler does not predict. It classifies. That is its
strength. Give it the right atoms and the downstream learners
will do the rest.

One more thing. The proposal says the sequence alternates
valley-transition-peak-transition-valley. This is the swing
structure. Higher highs and higher lows means the valleys are
rising and the peaks are rising. Lower highs and lower lows
means both are falling. You already note this in the series
scalars section (valley-to-valley trend, peak-to-peak trend).
Good. That IS the trend definition. The transition is the trend.
The valleys and peaks are just the punctuation.
