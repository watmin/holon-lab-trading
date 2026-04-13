# Review: Wyckoff / Verdict: CONDITIONAL

## The reading

This proposal IS the Wyckoff cycle. The author may not have intended
it, but valley is accumulation, peak is distribution, transition-up
is markup, transition-down is markdown. Four phases. Three labels.
The mapping is exact.

The conviction-based pivot detection from 045 was looking for the
wrong thing. It was looking for EVENTS — single candles where the
tape screamed. But phases are not events. Accumulation is not a
candle. It is a ZONE. A period of time where supply is being
absorbed at a price level. The proposal corrects this by labeling
zones, not candles. That correction alone justifies replacing
everything from 044-048.

The smoothing-as-confirmation is correct Wyckoff. A turn is not
real until the price has moved meaningfully away from the extreme.
In tape reading, we call this the "creek" — the price crosses the
creek and we know the phase has changed. The smoothing threshold
IS the creek. Below it, you are still in the phase. Above it, you
have left.

## Answers to the four questions

### 1. Smoothing: real turn vs noise

The Wyckoff method determines a real turn by CONFIRMATION. The
price must demonstrate, through sustained movement, that the prior
phase is over. Not a single candle. Not a spike. A campaign of
movement away from the extreme.

Option C is the correct choice. Here is why:

Option A (ATR-based) breathes with volatility but does not breathe
with STRUCTURE. ATR measures the size of individual candles. A
smoothing of 1x ATR means "the turn must exceed one typical candle."
But in a high-volatility accumulation, individual candles are large
while the structural turn may be small relative to the range. ATR
conflates candle noise with structural significance.

Option B (fixed percentage) does not breathe at all. 0.5% in a
trending market is too small. 0.5% in a tight range is too large.
This is an average masquerading as a parameter.

Option C (adaptive percentile of recent swing sizes) measures what
the market IS ACTUALLY DOING. If recent swings have been 2%, then
a move of 1% is below the median — still noise within the current
phase. A move of 3% exceeds it — a real structural change. The
smoothing adapts not to volatility (candle size) but to STRUCTURE
(swing size). That is the correct unit.

Use the 50th percentile of the last 20 confirmed swings. The
smoothing IS the market's current definition of "meaningful." Not
our definition. The market's.

One refinement: the percentile should be computed from CONFIRMED
swings only — swings that themselves exceeded the prior smoothing.
This prevents the smoothing from collapsing during a tight range.
The smoothing has memory. It should not forget what a real swing
looks like just because the last 20 swings were small.

### 2. Zone definition: how wide is accumulation?

In Wyckoff terms, the accumulation zone is the ENTIRE trading range
from the selling climax to the sign of strength. That range is
defined by the lowest low (the spring) and the highest reaction
rally within the range. The zone is not a fixed distance from the
extreme. It is the region where the price DWELLS — where supply
and demand are in equilibrium.

For the labeler, the zone should be the smoothing distance from the
confirmed extreme. Here is the reasoning:

The smoothing is the minimum size of a meaningful swing. If the
price is within one smoothing distance of the low, it has not yet
demonstrated a meaningful move away from that low. It is still IN
the valley. It is still being tested. Supply is still being
absorbed at that level. Once the price exceeds the smoothing
distance, it has LEFT the zone — the creek has been crossed.

Not half the smoothing. The full smoothing. Half would create zones
too narrow — the price would "leave" the valley before the turn is
confirmed, creating an awkward gap where the price is neither in the
valley nor in a confirmed transition. The zone boundary and the
confirmation threshold should be THE SAME LINE. When you leave the
zone, you are in transition. When you are in transition and the
reverse happens, you enter the next zone. One threshold. One line.
One creek.

This means the valley zone will be wider when the market is
swinging large and narrower when the market is quiet. The zone
breathes with the smoothing. The smoothing breathes with the
structure. The structure breathes with the market. Correct.

### 3. Phase attributes: what does Wyckoff measure?

The proposal captures duration, range, average close, open/close
of phase, and average volume. This is a good start but incomplete.
Here is what Wyckoff measures at each phase:

**Valley (accumulation):**
- Duration — how long supply takes to be absorbed. Longer = deeper
  accumulation = stronger eventual markup.
- Volume profile — is volume declining through the valley? That
  means supply is drying up. Is it spiking at the low? That is the
  selling climax — panic selling into prepared buyers.
- Number of tests — how many times does the price touch the low
  and hold? Each test that holds on lower volume confirms absorption.
  The proposal does not capture test count. It should.
- Range narrowing — is the valley tightening? A narrowing range
  within the valley means the equilibrium is resolving. Something
  is about to happen.

**Peak (distribution):**
- Duration — how long it takes to distribute. Shorter distribution
  than accumulation = the operator is in a hurry = sharp markdown
  ahead.
- Volume profile — is volume expanding on rallies to the high but
  price failing to make new highs? Effort without result. The
  classic sign of distribution.
- Upthrust count — false breaks above the range that fail. Each
  failed breakout is a distribution event.

**Transition (markup/markdown):**
- Speed — move divided by duration. A healthy markup accelerates
  in the middle and decelerates at the end. A climactic markup
  accelerates at the end — that is the buying climax, the first
  event of distribution.
- Volume trend — is volume rising or falling through the
  transition? Rising volume on markup = demand. Falling volume on
  markup = no demand, the rally is living on fumes.
- Internal retracements — how far does the price pull back within
  the transition before resuming? Shallow pullbacks on low volume
  = strong trend. Deep pullbacks on high volume = supply entering.

The proposal needs these additional attributes in the phase record:

```scheme
;; Volume trend within the phase (rising or falling)
volume-trend        ;; slope of volume through the phase

;; Number of reversals within the phase (tests/thrusts)
internal-tests      ;; count of sub-threshold reversals

;; Speed of the phase (for transitions)
speed               ;; (close-final - close-open) / duration

;; Range compression (for valleys/peaks)
range-compression   ;; ratio of second-half range to first-half range
```

These are not exotic. They are computable from the closes and
volumes already in the window. They just need to be tracked.

### 4. Transition character: healthy trend vs exhaustion

A healthy markup (Wyckoff "sign of strength" followed by "last
point of support" followed by sustained advance) looks like this
on the tape:

- Steady speed. Not accelerating, not decelerating. The composite
  operator is marking up the price methodically, absorbing supply
  at each level before advancing.
- Volume rises on advances, falls on reactions. Demand is present
  on the moves up. Supply dries up on the pullbacks. Effort
  confirms result.
- Shallow internal retracements. The pullbacks within the markup
  are 1/3 to 1/2 of the prior swing. Not deeper. Deeper
  retracements mean supply is entering — the distribution may have
  already begun WITHIN the markup.
- Duration proportional to the prior valley. A valley that lasted
  30 candles should produce a markup that lasts at least 30 candles.
  If the markup exhausts in 10 candles, the accumulation was
  insufficient. The energy was not there.

An exhausting markup (Wyckoff "buying climax") looks like this:

- Accelerating speed. The price moves faster and faster. This is
  the public rushing in. The composite operator is not buying here.
  The composite operator is SELLING to the public.
- Volume spikes at the end, not the beginning. The climax. Maximum
  effort at the top. After the climax, the price cannot advance
  further despite maximum volume. Effort without result.
- Wide internal swings. The price moves violently in both
  directions. Volatility expands. This is the battle between
  informed sellers and uninformed buyers.
- Duration too short relative to the prior valley. A 30-candle
  accumulation that produces a 5-candle markup is a climax, not a
  trend. The energy was released all at once instead of sustained.

The atoms that distinguish these:

```scheme
;; Speed acceleration (second half speed vs first half speed)
(linear "transition-acceleration"
  (/ speed-second-half speed-first-half) 1.0)
;; < 1.0 = decelerating (healthy), > 1.0 = accelerating (climax)

;; Volume-price alignment
(linear "transition-effort-result"
  (/ volume-trend-slope price-trend-slope) 1.0)
;; Positive = volume confirms price. Negative = divergence.

;; Retracement depth (max internal pullback as fraction of move)
(linear "transition-deepest-pullback"
  (/ max-internal-retracement total-phase-move) 1.0)
;; < 0.5 = shallow (healthy), > 0.5 = deep (supply entering)

;; Duration ratio to prior accumulation/distribution
(log "transition-duration-ratio"
  (/ transition-duration prior-zone-duration))
;; < 0.3 = too fast (climax), 0.5-2.0 = healthy proportion
```

Markdown mirrors markup. A healthy markdown is sustained, steady,
with volume on the declines and low volume on the rallies. A
climactic markdown (selling climax) is sharp, fast, with a volume
spike at the bottom. The selling climax is the FIRST EVENT of
accumulation. The system should recognize that a climactic markdown
does not mean "more down." It means "the valley is forming." The
reckoner must learn this from the atoms. The vocabulary must give
it the tools.

## What is right

The three-label scheme is exactly the Wyckoff four-phase cycle with
the correct compression. Valley and peak are the consolidation
phases. Transition is the directional phase. The direction attribute
on transition gives you all four Wyckoff phases from three labels.
This is not a simplification — it is the correct abstraction. The
two consolidation phases (accumulation and distribution) differ not
in their label but in their CONTEXT — what came before and what
comes after. A valley after a markdown is accumulation. A peak
after a markup is distribution. The context is already captured by
the phase sequence. The label does not need to carry it.

The replacement of conviction-based detection with price-structure
detection is correct. Conviction measures the observer's surprise.
Price structure measures the market's behavior. The observer should
be surprised BY the phase labels, not the source OF them.

The phase series as thoughts — encoding each phase into a vector
and composing them sequentially — this IS the Wyckoff chart. Each
phase is an event in the campaign. The sequence of events tells the
story. The reckoner reads the story. The geometry of the story
determines the trade.

## The condition

The proposal captures price structure but underweights volume.
Volume appears only as `volume-avg` — the average volume during
the phase. That is the LEAST interesting thing about volume. What
matters is:

1. **Volume trend within the phase** — rising or falling. Is
   effort increasing or withdrawing?
2. **Volume at phase boundaries** — the volume at the turn. Was
   the turn a climax (high volume) or an exhaustion (low volume)?
3. **Effort vs result** — volume direction compared to price
   direction. Divergence is the earliest warning of phase change.

These are three more scalars per phase. They cost nothing to
compute. They are already available from the candle stream. Without
them, the labeler sees shape but not substance. It sees the chart
but not the tape.

Add these three volume attributes to the phase record and the
corresponding atoms to the phase thought encoding. The reckoner
needs the full tape — price AND volume — to read each phase.

If volume attributes are added: APPROVED. This is the correct
replacement for 044-048. The three labels ARE the Wyckoff cycle.
The smoothing IS the creek. The phase series IS the campaign. Build
it.

Without volume: the labeler is reading with one eye closed. Price
tells you what happened. Volume tells you whether it was real.
