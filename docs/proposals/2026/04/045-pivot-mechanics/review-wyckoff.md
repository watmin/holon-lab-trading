# Review: Wyckoff / Verdict: CONDITIONAL

Reviewer: Richard Wyckoff (tape reader, market analyst)

Conditional on resolving the ownership question and the spring
problem. The mechanics are sound but two answers need correction.

---

## Question 1: The 80th percentile threshold

**Correct in principle. Wrong as a fixed number.**

The 80th percentile is the right IDEA. A pivot is relative to
recent experience -- this is exactly how I read the tape. What
constitutes unusual volume or unusual price action depends on
what the market has been doing lately. A 50,000-share bar means
nothing in a stock that trades 2 million a day. The same bar in
a stock that trades 100,000 a day is a campaign beginning.

But 80th percentile is too generous. One candle in five becomes
a pivot. That is not a pivot -- that is noise with a name.

In a Wyckoff accumulation phase, the pivots are the TESTS.
The preliminary support. The selling climax. The automatic
rally. The secondary test. The spring. The sign of strength.
The last point of support. That is 6-8 events across hundreds
of candles. In a 500-candle window, 6-8 pivots means the 98th
percentile, not the 80th.

But I do not recommend 98th either. The machine should discover
this. Each exit observer has its own reckoner, its own learned
distances. Let each exit observer discover its own percentile.
Start at 80. Let the reckoner learn that 80 produces too many
pivots (the sequence becomes noise, Violence rises). The
threshold that produces Grace survives. The threshold that
produces Violence dies. The machine finds the right percentile
the same way I found the right tape reading sensitivity -- by
losing money at the wrong one.

**Recommendation:** The 80th percentile is the initial value,
not the final value. Add the threshold as a learnable parameter
on the exit observer. The reckoner sees the pivot frequency as
an atom. Too many pivots degrades the signal. The reckoner
learns to trust the exit observer that found the right frequency.

---

## Question 2: Conviction window N=500

**Too short for a full Wyckoff phase. Correct for a sub-phase.**

A complete Wyckoff cycle -- accumulation through distribution --
takes months. In BTC at 5-minute candles:

- Accumulation: 2-6 weeks = 4,000-12,000 candles
- Markup: 1-4 weeks = 2,000-8,000 candles
- Distribution: 2-6 weeks = 4,000-12,000 candles
- Markdown: 1-4 weeks = 2,000-8,000 candles

500 candles is roughly 42 hours. That covers one SUB-PHASE.
A secondary test. A spring and its confirmation. A backup to
the creek. This is not a flaw -- it is a feature you have not
named correctly.

The 500-candle window does not detect the full Wyckoff phase.
It detects what is locally unusual within the current phase.
During accumulation, a spring is locally unusual. During markup,
a shakeout is locally unusual. The window breathes with the
phase because the phase itself shapes what "normal conviction"
looks like.

During a quiet accumulation range, low conviction is normal.
A spike to 80th percentile catches the spring -- exactly right.
During an aggressive markup, high conviction is normal. The
threshold rises. Only the shakeout or the buying climax exceeds
it -- exactly right.

**Recommendation:** 500 is acceptable. Document that this is a
sub-phase window, not a full-cycle window. The full Wyckoff
cycle emerges from the SEQUENCE of sub-phase pivots, not from
a single window that spans the whole cycle. The sequential
encoding from 044 is what captures the full phase -- each pivot
in the sequence is a sub-phase event, and the sequence of events
IS the phase.

---

## Question 3: Direction changes within a pivot — the spring problem

**Two events. Always two events. This is the most important
answer in this review.**

A Wyckoff spring is the most profitable event in all of market
analysis. The price breaks below support -- every amateur sells,
every stop is hit, the composite operator absorbs the supply.
Then the price reverses sharply upward. The breakdown and the
reversal happen in rapid succession. Conviction is high through
both -- the volume is enormous in both directions.

If you treat this as one pivot, you lose the spring. The machine
sees "high conviction period, direction: ???" -- the directions
cancel. The spring becomes invisible. You have destroyed the
most valuable signal in the tape.

If you treat this as two pivots, the machine sees:

```
pivot-down: high conviction, high volume, price breaks support
gap: 0-2 candles (or none at all)
pivot-up: high conviction, HIGH volume, price reverses hard
```

The sequential encoding captures the PATTERN. Down then up in
rapid succession with high volume on the reversal. That IS the
spring. The reckoner can learn that this specific positional
pattern -- down-pivot immediately followed by up-pivot with
higher volume -- predicts the markup phase. The geometry
preserves the spring.

The same logic applies to the upthrust (false breakout in
distribution). Up then down, rapidly. Two events.

**Recommendation:** A direction change within a high-conviction
period MUST split the period into two pivots. The conviction
threshold is not the only trigger for a new period. Direction
reversal is the other trigger. The state machine needs a third
transition:

```
Currently in a pivot, conviction still high, direction changed
→ close the current pivot, start a new pivot with the new direction
```

This is not optional. Without it, springs and upthrusts are
invisible to the machine.

---

## Question 4: Gap minimum duration

**One candle is enough to start a gap. But a gap is not real
until it has had time to breathe.**

In Wyckoff analysis, the pauses between tests matter. A one-
candle pause between two high-conviction bars is not a gap --
it is a breath within the same move. A 10-candle pause is a
real gap -- the market is digesting, the composite operator is
resting, supply and demand are reaching temporary equilibrium.

But I do not recommend a hard minimum. The gap's DURATION is
already an atom in the gap thought (Proposal 044, `gap-duration`).
A 1-candle gap is encoded with `(Log "gap-duration" 1)`. A
50-candle gap is encoded with `(Log "gap-duration" 50)`. The
reckoner sees both. The reckoner learns which gap durations
matter and which are noise.

However, there is a practical concern: flickering. If conviction
oscillates around the threshold -- above, below, above, below --
you get a sequence of 1-candle pivots and 1-candle gaps. The
sequential encoding fills with meaningless entries. The bounded
memory of 20 entries fills with noise instead of structure.

**Recommendation:** Use a 3-candle minimum for gaps. If conviction
drops below threshold for fewer than 3 candles and then rises
again, treat the entire span as one continuous pivot. This
prevents flickering without losing real gaps. Three candles at
5-minute intervals is 15 minutes. Any real pause in a campaign
lasts at least 15 minutes. If the composite operator is done
acting for the moment, 15 minutes of silence proves it.

The state machine becomes: when conviction drops below threshold,
do not immediately start a gap. Instead, mark the candle as
"tentative gap." If conviction rises again within 3 candles,
extend the current pivot to cover the dip. If conviction stays
below for 3 candles, retroactively start the gap from the first
below-threshold candle.

---

## The ownership question

**Neither the exit observer nor the broker. A dedicated tape reader.**

I have spent my career reading the tape. The tape reader is a
SPECIFIC SKILL. It is not trade management (the exit observer's
job). It is not accountability (the broker's job). The tape
reader watches the composite operator's footprints -- the volume,
the price action, the effort vs result, the rhythm of tests and
responses. The tape reader says "something happened here" and
"this is the pattern of what has been happening."

The proposal places pivot detection on the exit observer because
the exit acts on pivots. But this confuses detection with action.
The detective who finds the evidence is not the judge who acts on
it. The tape reader detects. The exit acts.

The proposal also considers the broker because the broker sees
the portfolio. But the broker's job is accountability -- Grace
and Violence. Adding tape reading to the broker overloads its
concern.

**The pivot state belongs to the post.** The post is the
per-asset-pair unit. Market structure -- the rhythm of pivots
and gaps -- is an asset-level concern. It is the same for ALL
brokers and ALL exit observers on that post. Every broker sees
the same pivots. Every exit observer receives the same pivot
classification. The detection happens once, at the post level.

The post maintains:
1. The conviction history (rolling window)
2. The current period state (pivot or gap)
3. The pivot memory (bounded VecDeque of completed periods)
4. The sequential encoding of the series

The post passes the pivot classification and the sequential
encoding DOWN to each broker. Each broker passes it to its exit
observer. The exit observer adds its per-trade biography atoms
and acts. The broker adds its portfolio biography atoms and
grades.

This is separation of concerns:
- **Post** detects pivots (tape reader)
- **Exit observer** acts on pivots (trade manager)
- **Broker** grades actions at pivots (accountant)

The market observer does not change. It still predicts direction
and produces conviction. The post reads the conviction and
classifies pivot vs gap. One classification, shared by all.

This also solves a problem the proposal does not mention: if
each exit observer tracks its own pivot state with its own
learned threshold, different exit observers will disagree about
whether a candle is a pivot. Broker A's exit says pivot. Broker
B's exit says gap. The sequential encoding diverges. The brokers
are no longer looking at the same market structure. That is
wrong. The market structure is one thing. The interpretation
differs. The observation should not.

**Recommendation:** Pivot detection lives on the post. The post
is the tape reader. The exit observers and brokers consume the
classification. They do not produce it.

If the learnable threshold (Question 1) is desired -- and I
believe it should be -- then the post learns one threshold for
the asset pair, not N thresholds for N exit observers. The
post's threshold is graded by aggregate Grace across all brokers.
The tape reader gets better at reading the tape for THIS asset.

---

## Summary

| Question | Answer |
|----------|--------|
| Threshold | 80th percentile as starting point, learnable per post |
| Window | 500 is correct for sub-phase detection |
| Direction change | MUST split into two pivots (spring/upthrust) |
| Gap minimum | 3 candles to prevent flickering |
| Ownership | The post, not the exit or broker |

The spring answer and the ownership answer are the two conditions.
Without direction-change splitting, the machine cannot see the
most valuable Wyckoff pattern. Without post-level ownership, the
machine disagrees with itself about what the market looks like.

Both are fixable within the existing architecture. The Sequential
encoding, the pivot vocabulary, the biography atoms -- all sound.
The mechanics work. The detection just needs to live in the right
place and handle direction reversals correctly.

Richard D. Wyckoff
