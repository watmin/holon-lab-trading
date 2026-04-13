# Review: Wyckoff
Verdict: CONDITIONAL

## The reading

This proposal understands something fundamental: the market does not
speak in candles. It speaks in pivots. The candle is the phoneme. The
pivot is the word. The sequence of pivots is the sentence. And the
sentence tells you which phase you are in.

Accumulation is not one event. It is a CAMPAIGN. The composite operator
scales in across multiple tests of support. Each test is a pivot. Each
entry at a rising low is an addition to the line. The proposal captures
this exactly — three entries during a dip, each at a different price,
each with its own trail. This IS how the operator builds a position.
Not all at once. Across pivots. Testing the supply at each level.

The portfolio biography — active count, oldest runner, newest entry,
heat — this is the operator's position sheet. "I have four lots. The
oldest was bought at the spring. The newest was bought at the sign of
strength. My average cost is below the creek." That is a biography.
That is Wyckoff.

## What is right

**The pivot series scalars are the market structure.** Low-to-low trend,
high-to-high trend, range compression, spacing. This IS the sequence
of pivot highs and pivot lows. When the lows stop rising, the phase
changes. When the range compresses, the energy is leaving. When the
spacing accelerates, urgency. When it decelerates, exhaustion. These
four scalars encode the Wyckoff phases without naming them. The
reckoner discovers the phases from the geometry. That is correct.

**"Lower low = get out" is the right instinct.** In Wyckoff terms, a
lower low after a series of higher lows is the sign of weakness. It
means supply has overwhelmed demand. The markup phase is over.
Distribution has begun — or already ended. The pivot series captures
this as `pivot-low-trend` going negative. The exit observer sees it
as a change in the thought vector. The trail tightens. The position
exits. Clean.

**The biography differentiates trades that look identical on price.**
Two trades at the same price, same candle, same direction — but one
is a runner from 5 pivots ago and one is a newborn. In Wyckoff terms,
the runner has survived multiple tests. It has PROVEN itself against
supply. The newborn has proven nothing. The runner deserves a wide
trail. The newborn deserves a tight one. The biography encodes this
distinction. Price alone cannot.

**Multiple brokers acting simultaneously at the same pivot** — this IS
the market. While the composite operator distributes, the next
campaign's accumulation begins. One broker exits its runner at the
buying climax. Another broker enters fresh at the same candle, reading
it as a test of a new range. Both are correct within their own
biography. The capital rotates. The residue stays.

## What is missing

**Volume — effort vs result.** This is the critical gap. In Wyckoff,
the pivot is not just a price event. It is a RELATIONSHIP between
effort (volume) and result (price movement). A pivot high on declining
volume is distribution — the markup continues but the effort is
withdrawing. A pivot low on expanding volume is absorption — supply is
being absorbed by demand. The current pivot series captures the RESULT
(price relationships) but not the EFFORT.

The proposal needs at least two volume-aware atoms in the pivot series:

```scheme
;; Effort at the pivot relative to recent average
(Log "pivot-volume-vs-avg" ...)

;; Effort-result divergence: volume rising while range compressing
;; = absorption. Volume falling while price rising = no demand.
(Linear "pivot-effort-result" ...)
```

Without these, the system sees the price structure degrading but
cannot see WHY. A lower high on heavy volume is different from a
lower high on no volume. The first is active distribution (get out
NOW). The second is simply absence of demand (there may be another
test). The exit observer needs this distinction.

**Springs and upthrusts.** A spring is a false break below support
that reverses — the composite operator shaking out weak hands. An
upthrust is a false break above resistance. These are pivots where
the conviction spikes (correctly) but the ACTION should be the
opposite of what the price suggests. The pivot biography would help
here — a spring looks like a lower low (get out signal) but
REVERSES within 1-2 candles. The proposal should acknowledge that
the "lower low = get out" heuristic is a starting point, not the
complete picture. The reckoner may learn springs from the data. But
the vocabulary should give it the tools.

## Answers to the six questions

### 1. Pivot detection

Market observer conviction is sufficient as the initial mechanism.
In Wyckoff terms, the conviction spike corresponds to a change of
character — the tape says something different from what it has been
saying. That is exactly when you evaluate. The conviction threshold
naturally adapts as the noise subspace learns what "normal" looks
like for each observer's lens. A volume lens will fire on volume
anomalies. A structure lens will fire on price structure changes.
Each observer already detects its own version of "pivot." Let them.

Do NOT build a separate pivot mechanism. The conviction IS the
mechanism. Adding a second detector means two opinions about when
to evaluate, which means arbitration logic, which means complexity
that does not teach.

### 2. Pivot memory size

10 is correct. Here is the Wyckoff reasoning: an accumulation
phase has roughly 6-10 identifiable events (preliminary support,
selling climax, automatic rally, secondary test, spring, sign of
strength, last point of support, breakout). A distribution phase
mirrors this. 10 pivots covers one full phase. That is exactly the
right window — you want to see the current phase, not the previous
one.

Do NOT make it discovered. The pivot memory is a vocabulary
parameter, not a learned parameter. The reckoner learns what the
pivots MEAN. The memory window determines how far back the
vocabulary looks. 10 is a structural choice. Fix it. If you later
want to experiment, make it a configuration constant, not a
learning target.

### 3. Trade biography on the chain

Only the computed atoms should travel. The raw pivot memory (10
records of candle/price/conviction/action/trade-count) is the
BROKER's internal state. The exit observer should not see raw
pivots. It should see what the pivots MEAN for THIS TRADE:
pivots-since-entry, pivots-survived, entry-vs-pivot-avg, plus the
pivot series scalars. These are the digested facts. The exit
observer thinks in terms of its trade's relationship to the pivot
structure, not in terms of the raw structure itself.

Sending raw pivots would be like sending the tape to a trader who
only needs to know "am I underwater?" The exit observer's job is
narrow: set trail and stop distances for this trade. Give it the
biography. Keep the tape with the broker.

### 4. Portfolio biography scope

Compose it with the market thought in the broker's reckoner. The
portfolio state IS part of the broker's context for deciding
whether to enter at this pivot. "I have 4 trades running, the
oldest is deep in profit, the market structure is compressing" —
that is ONE thought. Separating it creates two inputs that must be
reconciled, which means another mechanism for reconciliation.

The portfolio biography is just more atoms in the bundle. The
reckoner handles high-dimensional bundles already. Let it find the
correlations between market state and portfolio state. That is
what reckoners do.

### 5. Entry decisions — maximum concurrent trades

The reckoner learns this through the portfolio-heat atom. No hard
cap. Here is why: in Wyckoff terms, the composite operator adds to
the line AS LONG AS the structure supports it. During accumulation,
each test of support that holds is a signal to add. There is no
fixed number of tests. Sometimes the accumulation has 3 pivots.
Sometimes 8. A hard cap of 4 trades means you miss the sign of
strength entry because you are "full."

The portfolio-heat atom tells the reckoner "I am 80% allocated."
If the reckoner has learned that entries above 80% heat produce
more Violence than Grace, it will stop entering. That is a LEARNED
cap, not a hard one. It adapts to market conditions. During a
trending market, high heat works. During a range, it does not. The
reckoner discovers this.

One guard rail: the treasury already controls maximum exposure
through funding. If the broker proposes a 5th trade but the
treasury has no capital left, it is not funded. That is sufficient.
The treasury IS the hard cap. The reckoner is the soft cap. Both
are already in the architecture.

### 6. Simultaneous buy/sell across brokers

Independent. Fund both. The treasury sees two proposals at the
same candle: Broker A exits (principal returns, residue captured),
Broker B enters (capital reserved). These are DIFFERENT campaigns.
Broker A's campaign is ending. Broker B's campaign is beginning.
Netting them would be like saying "the buyer and seller at the
auction are the same person." They are not. They have different
biographies, different histories, different edge profiles.

The treasury's job is capital allocation, not position netting.
Netting implies a single portfolio view. But the whole point of
22 brokers is 22 independent campaigns. If Broker A's exit
returns 1 BTC of principal and Broker B wants 0.8 BTC for its
entry, the treasury sees: 1 BTC returned, 0.8 BTC requested.
Fund the request from available capital. The residue from A's
exit stays in the treasury. Simple. Independent. Correct.

Netting would also create a coupling between brokers that
violates the "values up" principle. Each broker proposes
independently. The treasury decides independently. No broker
needs to know what another broker is doing.

## The condition

Add volume atoms to the pivot series. The price structure alone
tells you WHAT is happening. The effort tells you WHY. Without
effort, the system cannot distinguish absorption from distribution,
cannot see no-demand rallies, cannot read springs. The pivot series
needs:

1. Volume at the pivot relative to recent average (effort magnitude)
2. Effort-result divergence (volume direction vs price direction)

These are two more Linear atoms. They compose with the existing
pivot series. No new machinery. The reckoner gets the full Wyckoff
picture: price structure AND effort. Without this, you have half
the tape.

If these are added (even as a note for implementation), APPROVED.
Without them, the system reads price but not volume at the pivots,
and that is reading with one eye closed.
