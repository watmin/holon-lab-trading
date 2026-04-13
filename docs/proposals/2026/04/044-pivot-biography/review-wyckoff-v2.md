# Review: Wyckoff (v2 — sequence encoding + gaps)
Verdict: APPROVED

## The condition is met

The pivot thought now carries `pivot-volume-ratio` and
`pivot-effort-result`. Both are Linear scalars. Both sit inside
the pivot thought bundle alongside conviction, duration, direction,
and close-avg. The effort is no longer missing. The reckoner can now
distinguish a markup on declining volume (no demand — distribution
forming) from a markup on expanding volume (demand overwhelming
supply — the move is real). That was the condition. It is satisfied.

The gap thought carries `gap-volume` as well. That is a bonus I did
not ask for, and it is correct. Volume during the pause tells you
whether the composite operator is resting or repositioning. Low
volume in the gap means indifference — the participants have stepped
away. Normal volume in the gap with sideways drift means quiet
accumulation. The gap volume atom gives the reckoner the tool to
read this.

## The gaps

Question 7 asked: what does a trader see in the pause between pivots?

The proposal answers with three atoms: `gap-duration`, `gap-drift`,
and `gap-volume`. Let me evaluate each against what the tape actually
shows between active periods.

**Duration.** Correct. The length of the pause is the first thing
you notice on the tape. A 3-candle gap between pivots means the
market barely paused — the next event followed immediately. A
47-candle gap means the market went quiet for nearly four hours on
5-minute bars. In Wyckoff terms, the duration of the trading range
between markup phases IS the accumulation or distribution period.
Short pauses during markup mean the trend is intact — buyers absorb
every dip immediately. Long pauses after a climax mean the character
has changed. The duration atom captures this.

**Drift.** Correct. The price movement during the gap tells you
whether the pause is healthy or dangerous. A gap that drifts in the
direction of the prior trend is a normal reaction — profit-taking
that does not attract new supply. A gap that drifts against the
trend is pressure building. In the example: gap-3 is 47 candles
with +$1,300 drift. That is a slow grind upward. On the surface
it looks bullish. But look at what follows: down-2 with conviction
0.04 and volume-ratio 0.7. The long quiet grind exhausted the
remaining demand. The next active period was weak. The gap told
you the energy was leaving, not building. The drift atom captures
this.

**Volume.** Correct, and this is where my original condition
intersects with the gap design. The gap volume ratio of 0.3-0.6
in the examples means volume contracted to 30-60% of average
during the pause. In Wyckoff terms, low volume on a reaction is
BULLISH — supply is drying up. But low volume on a rally (gap
drifting up) is BEARISH — there is no demand behind the move.
The gap volume combined with gap drift gives the reckoner enough
to distinguish these two cases. The geometry handles it:
permute(gap-thought, position) encodes the gap at its position in
the sequence. The reckoner sees the gap-volume and gap-drift atoms
in the context of what came before and after.

**What is missing from the gap?** One thing, and it is minor enough
that I do not condition on it: the gap's internal volatility. A
47-candle gap where price drifted +$1,300 could be a smooth grind
(each candle +$28, no reversals) or a choppy range (swinging $500
up and down, netting +$1,300). The smooth grind is orderly
withdrawal of supply. The choppy range is contested ground — buyers
and sellers fighting. A single atom like `gap-chop` (standard
deviation of candle returns within the gap, normalized) would
distinguish these. But the existing three atoms cover 90% of what
the tape shows. The reckoner can partially infer choppiness from
the combination of duration and drift — a long gap with small drift
implies either very smooth or very choppy. Not perfect. Good enough
for now.

## The Sequential encoding

This is the part that matters most for the Wyckoff reading. Does
the positional encoding preserve accumulation, markup, distribution,
markdown as a sequence?

Yes. Here is why.

The Wyckoff method reads the tape as a NARRATIVE. Each event
follows the prior event. The meaning of event N depends on events
0 through N-1. A higher low after a selling climax means something
completely different from a higher low after an upthrust. The
position in the sequence IS the meaning.

The Sequential encoding does exactly this. `permute(thought, i)`
rotates the thought vector by position i. Position 0 is
geometrically distinct from position 3. The bundle of all permuted
thoughts produces a single vector where the ORDER of events is
encoded in the geometry. Two sequences with the same events in
different order produce different vectors. ABC is not CBA. That
is precisely what the tape reader needs.

Consider the accumulation-to-markup transition:

```
Position 0: down (conviction 0.12, vol-ratio 1.8) — selling climax
Position 1: gap (3 candles, drift -$200, vol 0.3) — brief pause
Position 2: up (conviction 0.06, vol-ratio 0.9) — automatic rally
Position 3: gap (12 candles, drift -$500, vol 0.4) — testing
Position 4: down (conviction 0.04, vol-ratio 0.5) — secondary test
             ^ LOW volume on the retest. Supply exhausted.
Position 5: gap (8 candles, drift +$100, vol 0.3) — quiet
Position 6: up (conviction 0.09, vol-ratio 1.4) — sign of strength
             ^ HIGH volume on the rally. Demand entering.
```

The positional encoding preserves the SHAPE of this sequence. The
selling climax at position 0, the weak secondary test at position 4,
the strong sign of strength at position 6 — each at its own
position in the permutation space. The reckoner sees this as one
vector. If it has seen this geometric signature before and the
outcome was markup, it will recognize it again. It does not need
to know the names "selling climax" or "sign of strength." It needs
the geometry. The Sequential provides the geometry.

Now consider distribution:

```
Position 0: up (conviction 0.11, vol-ratio 1.6) — buying climax
Position 1: gap (5 candles, drift +$300, vol 0.5) — calm
Position 2: down (conviction 0.05, vol-ratio 0.8) — automatic reaction
Position 3: gap (15 candles, drift +$800, vol 0.6) — slow grind
Position 4: up (conviction 0.04, vol-ratio 0.5) — upthrust
             ^ LOW volume on the rally. No demand.
Position 5: gap (20 candles, drift -$200, vol 0.4) — heavy pause
Position 6: down (conviction 0.08, vol-ratio 1.3) — sign of weakness
             ^ HIGH volume on the decline. Supply entering.
```

The geometry is DIFFERENT. Not because the atoms are different (the
same vocabulary encodes both sequences) but because the VALUES at
each POSITION are different. The effort-result relationship at
position 4 is inverted between the two cases. The reckoner does not
need to be told "this is distribution." The vector is different.
The subspace is different. The prediction is different.

This is what I mean when I say the Sequential preserves the Wyckoff
reading. The method of reading the tape is: observe the sequence
of events, note the effort at each event, note the position of each
event relative to the prior events, and determine the phase. The
Sequential encoding does all of this in one vector.

## The alternation of pivots and gaps

The interleaving is the right design. In the tape, the market
alternates between activity and silence. The activity is the event.
The silence is the reaction. Both are data. Most systems encode
only the events and discard the silence. This proposal encodes
both.

In Wyckoff terms, the REACTION after the event tells you the
quality of the event. A selling climax followed by a 3-candle
pause with low volume means the selling was absorbed — demand
is present. A selling climax followed by a 47-candle pause with
drifting prices means the selling was not absorbed — there is no
urgency from buyers. The pause IS the diagnosis.

The positional encoding makes the pivot-gap-pivot-gap rhythm a
first-class part of the geometry. The reckoner sees the rhythm,
not just the events. A sequence where gaps are getting longer
has a different vector from one where gaps are getting shorter.
Decelerating rhythm = exhaustion. Accelerating rhythm = urgency.
Both are implicit in the permuted positions.

## The volume atoms within the sequence

The pivot thought now carries:

- `pivot-volume-ratio` — effort at this pivot relative to average
- `pivot-effort-result` — divergence between volume and price

These sit INSIDE the permuted thought at each position. The
reckoner sees the effort at position 0 differently from the effort
at position 6. A high-effort event early in the sequence (climax)
has a different geometric signature from a high-effort event late
(sign of strength or weakness). The positional encoding preserves
this distinction without any special handling. Permutation does
the work.

This is where the Sequential form earns its keep. Without
positional encoding, the volume atoms would be bundled together
and the reckoner would see "there was high volume somewhere in
the last 10 events." With positional encoding, the reckoner sees
"there was high volume at position 0 and again at position 6,
with low volume in between." That is the effort distribution
across the phase. That IS the Wyckoff reading.

## Answer to Question 7

**What does a trader see in the pause between pivots?**

The trader sees three things:

1. **How long the market rested.** Short rest = the participants
   are eager. Long rest = the conviction has faded, or patient
   hands are building lines quietly.

2. **Where price drifted.** Drift with the trend on low volume
   is healthy — the path of least resistance. Drift against the
   trend is pressure that has not yet resolved into a pivot.
   Drift against the trend on rising volume is the warning — the
   next pivot will be violent.

3. **Whether the market was alive or dead during the pause.**
   Volume during the gap distinguishes quiet from dead. Quiet
   means the smart money is waiting. Dead means the smart money
   has left. Both produce low-conviction candles. The volume
   tells you which.

The proposal's three gap atoms (duration, drift, volume) capture
all three. The one nuance missing is internal choppiness — was the
pause smooth or contested — but this can be added later as a
fourth gap atom without changing the architecture. The Sequential
encoding handles any number of atoms per gap thought.

The deeper answer to Question 7: the pause is not silence. The
pause is the market's JUDGMENT on the prior event. The selling
climax happens. Then the market pauses. The length and character
of that pause is the market's verdict: "Was that selling climax
absorbed? Is demand present? Or did that selling climax create
more supply?" The pause ANSWERS the question that the pivot ASKED.
Encoding both is encoding the conversation.

## The AST form

`Sequential(Vec<ThoughtAST>)` is the correct choice. It is sugar
for `permute` + `bundle`, but sugar that makes the intent
undeniable. A vocabulary module that returns a Sequential is
declaring: "this is ordered data." A vocabulary module that
returns a Bundle of explicitly permuted binds is doing the same
thing with more ceremony and more room for error (forgetting to
permute one element, permuting by the wrong index). The Sequential
form is a constraint that guarantees correctness. Keep it.

## Summary

The original condition was volume. Volume is present — both in
pivot thoughts (`pivot-volume-ratio`, `pivot-effort-result`) and
in gap thoughts (`gap-volume`). The effort side of the tape is
now readable.

The gap encoding is sound. Duration, drift, and volume cover
what the tape reader needs to evaluate the pause between events.

The Sequential encoding preserves the Wyckoff reading. The
positional permutation makes order matter. The interleaving of
pivots and gaps encodes the rhythm. The reckoner sees one vector
that carries the full narrative of the phase.

The system can now distinguish accumulation from distribution
not by naming them, but by recognizing that the geometric
signature of "declining volume on retests followed by expanding
volume on rallies" is different from the geometric signature of
"declining volume on rallies followed by expanding volume on
declines." The names are ours. The geometry is the machine's.

APPROVED. No conditions.
