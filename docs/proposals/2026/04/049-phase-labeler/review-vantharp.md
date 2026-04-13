# Review: Van Tharp / Verdict: CONDITIONAL

Reviewer: Van Tharp (position sizing, expectancy, R-multiples)
Proposal: 049 — The Phase Labeler

The concept is sound. A structural phase classifier from confirmed
price reversals is exactly the kind of objective labeling that
position sizing needs. No prediction. No opinion. Just structure.

I approve the architecture. I withhold full approval on four
specifics that need resolution before implementation.

---

## 1. Smoothing: what's the statistical basis for the threshold?

The proposal offers three options (ATR, fixed percentage, adaptive
percentile) but doesn't commit. This matters enormously for position
sizing because **the smoothing parameter determines your trade
frequency**, and trade frequency determines your sample size per
unit time, which determines how fast expectancy converges.

**The answer is ATR-based, but the multiplier must be derived from
your R-multiple distribution, not chosen arbitrarily.**

Here's the statistical basis: Your smoothing threshold is your
minimum swing size. Your minimum swing size determines the smallest
R you'll ever capture. If your average winner is 2R and your
smoothing is set so tight that you're labeling 0.3R wiggles as
phases, you'll generate dozens of trades that can never reach 1R
before the next phase change. You're manufacturing losers.

The sweet spot: **the smoothing should equal approximately 1R at
your intended position size.** If your initial risk (stop distance)
is 1 ATR, then the smoothing should be at minimum 1 ATR. This
ensures that every confirmed phase transition represents a move
large enough to contain at least one R-unit of opportunity.

For BTC at 5-minute candles:

- **Below 0.5 ATR:** Scalping. You'll get 50+ phases per day.
  Venue costs (0.35% per swap from the Jupiter analysis) will
  destroy you. Each phase is too short for expectancy to express.
- **0.5-1.0 ATR:** Day-trading frequency. Manageable if venue
  costs are low. ~10-20 phases per day. Sample sizes build in
  weeks.
- **1.0-2.0 ATR:** Swing frequency. This is where most positive
  expectancy systems live. ~3-8 phases per day. Each phase has
  enough duration for a meaningful move. Venue costs become a
  small fraction of the average win.
- **Above 3.0 ATR:** Position trading. Too few samples. Expectancy
  takes months to converge. Fine for large accounts, wrong for
  a learning machine that needs feedback density.

**Recommendation:** Start at 1.5 ATR. This is not arbitrary — it's
the point where a confirmed reversal has already moved 1.5x your
typical noise band, giving you high confidence the turn is real,
while still producing enough phases to learn from. The adaptive
option (percentile of recent swings) is interesting as a second
iteration but introduces a feedback loop — your smoothing depends
on your phases which depend on your smoothing. Start fixed-ratio
to ATR. Adapt later when you have ground truth.

---

## 2. Zone definition: what's the boundary?

The proposal asks: how close to the confirmed extreme does price
need to be to count as "in the zone" vs having transitioned?

**The zone boundary should be half the smoothing threshold.**

Here's why. The smoothing threshold is your minimum reversal size.
The zone is the region around the extreme where price is
"consolidating at the turn." If the zone equals the full smoothing
distance, then the instant a zone ends, a new phase is confirmed —
there's no transition, just zone-to-zone. The transition phase
disappears.

Half the smoothing gives you three distinct regions with clear
statistical character:

- **Zone (peak/valley):** price within 0.5 × smoothing of the
  extreme. Low directional velocity. High indecision. This is
  where you EXIT, not enter. Position sizing should be defensive
  here — reduce exposure, tighten stops.

- **Transition:** price has left the zone but hasn't confirmed the
  next turn. Directional. Trending. This is where you HOLD. The
  R-multiple is growing. Let it run.

- **Confirmation (next zone):** the transition has reversed by
  more than the smoothing. New zone. New phase. This is where you
  ENTER the next trade or EXIT the current one.

The half-smoothing boundary also gives you a natural trailing stop
anchor: when price is in a transition-up phase, a stop at "current
close minus zone boundary distance (0.5 × smoothing)" keeps you
in the trend while cutting you at the edge of the next potential
valley zone.

---

## 3. Phase attributes: what does a position sizing expert measure?

The proposal lists duration, range, volume, open-close move, and
average close. Good start. Incomplete for sizing.

**What a position sizing expert needs at each phase:**

For **valleys and peaks** (the zones):
- **Duration** — how many candles at the turn. Longer zones mean
  more accumulation/distribution. More conviction in the turn.
- **Range** — max-min within the zone. Tight zones are springs.
  Wide zones are indecision. Tight zones with high volume are the
  highest-quality setups.
- **Volume relative to transition volume** — is volume expanding
  or contracting at the turn? Expansion at valleys = accumulation.
  Expansion at peaks = distribution. This is Wyckoff's territory
  but it feeds directly into sizing confidence.
- **Depth from previous peak/valley** — the R-multiple of the
  completed swing. This is the realized R that feeds expectancy.

For **transitions** (the moves):
- **Speed (move / duration)** — the R-per-candle. Fast transitions
  suggest momentum. Slow transitions suggest grinding. Momentum
  transitions deserve wider trailing stops. Grinding transitions
  deserve tighter ones.
- **Linearity** — how straight is the move? The ratio of
  (start-to-end distance) / (sum of candle-to-candle distances).
  A ratio near 1.0 = clean trend. Near 0.5 = choppy trend. Clean
  trends sustain. Choppy trends fail. This directly affects
  position sizing confidence.
- **Internal drawdown** — the largest pullback during the
  transition that did NOT trigger a new phase. This is your
  realized MAE within a winning move. It calibrates stop distance
  for future transitions.
- **R-multiple at completion** — when the transition ends (next
  zone confirmed), what was the total move in R-units? This is
  the MFE of the phase. It feeds the distribution of winners.

For **the series** (cross-phase):
- **Swing-to-swing trend** — are consecutive valleys rising? Are
  consecutive peaks rising? Both rising = uptrend. Valleys rising,
  peaks falling = compression. This is the regime.
- **Duration trend** — are transitions getting shorter or longer?
  Shortening transitions in an uptrend = exhaustion. The position
  sizing response is to reduce size.
- **Expectancy by phase type** — what's the average R-multiple of
  trades entered at valleys vs entered during transitions vs
  entered at peaks? This is the foundation of the whole system.
  You should have radically different sizing for each.

---

## 4. Transition character: what distinguishes transitions statistically?

The proposal notes that "a slow grind up vs a sharp spike up are
both transitions." Correct, and they demand completely different
position management.

**The four statistical signatures of transition character:**

**Velocity (move / duration):** The primary discriminator. Fast
transitions (> 2 standard deviations of historical transition
velocity) are impulse moves. Slow transitions (< 0.5 SD) are
grinding moves. Impulse moves tend to retrace. Grinding moves
tend to persist. Size smaller into impulse transitions (the
retracement risk is high). Size larger into grinding transitions
(the persistence probability is higher).

**Acceleration (change in velocity over the transition):**
Accelerating transitions are parabolic — they end violently.
Decelerating transitions are exhaustion — they end with a whimper.
Acceleration tells you how the transition will END, which is when
your trade resolves. Encode it.

**Volume profile (average volume in first half vs second half):**
Front-loaded volume (high early, low late) = the move is spent.
Back-loaded volume (low early, high late) = the move is
accelerating on participation. This is the classic Wyckoff
distinction between effort and result. Back-loaded volume
transitions have higher continuation probability.

**Retracement ratio (largest internal pullback / total move so
far):** A transition that retraces 60% of its move mid-flight is
a different animal than one that retraces 10%. Low retracement
ratio = clean impulse, high confidence. High retracement ratio =
contested move, lower confidence. This is your intra-phase MAE
and it directly calibrates stop distance.

These four — velocity, acceleration, volume profile, retracement
ratio — are the minimum set. All are computable from the candle
data already available. All produce continuous scalars. All have
direct position sizing implications.

---

## Summary of conditions

1. **Commit to 1.5 ATR smoothing** as the starting point. Derive
   from R-multiple analysis, not intuition.

2. **Zone boundary at 0.5 × smoothing.** Three distinct regions
   with distinct sizing implications.

3. **Add the missing phase attributes:** linearity, internal
   drawdown, R-multiple at completion, swing-to-swing trend,
   expectancy by phase type.

4. **Encode transition character as four scalars:** velocity,
   acceleration, volume profile (first-half vs second-half ratio),
   retracement ratio.

The labeler is the right abstraction. Phases are zones, not
points. The smoothing determines trade frequency. Get these four
things right and the downstream sizing will have something real
to work with. Get them wrong and you'll be sizing noise.

The conviction-based approach from 045 was looking at the wrong
thing — individual candle intensity instead of structural
confirmation. This proposal corrects that. The structure IS the
signal. The smoothing IS the timeframe. The phase IS the context
for sizing.

Approved with the four conditions above.
