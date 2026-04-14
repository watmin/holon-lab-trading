# Review: Wyckoff

Verdict: CONDITIONAL

The builder has diagnosed a real disease, not a phantom. The tape is
shifting underneath the reckoner, and the reckoner does not know it.
I have read the proposal, the position observer code in
`src/domain/position_observer.rs`, the position observer program in
`src/programs/app/position_observer_program.rs`, the market observer
in `src/domain/market_observer.rs`, and the continuous reckoner
implementation in `holon-rs/src/memory/reckoner.rs`. Here are my
answers to the five questions.

---

## 1. Is the noise subspace the cause?

Yes. And the code proves it more precisely than the proposal states.

The position observer program (line 221-222) calls
`noise_subspace.update()` then `anomalous_component()` on every
candle. The resulting `position_anomaly` is what the broker stores
on the paper trade. When the trade resolves -- possibly hundreds or
thousands of candles later -- the broker sends back that STORED
anomaly vector as `position_thought` in the PositionLearn signal.
The reckoner's `observe_scalar()` accumulates this stale anomaly
into its bucket prototypes.

But at query time, the reckoner receives the CURRENT anomaly --
stripped by a subspace that has absorbed thousands more candles of
"normal." The current anomaly and the stored anomaly were computed
under different definitions of normal. The dot product between the
current query and the old bucket prototypes degrades because the
vectors live in different coordinate frames.

This is exactly what a tape reader sees when the market changes
character. During accumulation, the background is range-bound
chop -- that is "normal." The anomaly is the spring, the sharp
test of the low. During markup, the background shifts -- trending
price action becomes "normal." Now the anomaly is the reaction,
the pullback that tests the rising creek. The spring that was
anomalous during accumulation would NOT be anomalous during markup.
The definition of "unusual" is phase-dependent.

The subspace is the cause. Run without stripping to confirm, but
the mechanism is clear from the code.

---

## 2. Should the reckoner see the raw thought instead of the anomaly?

This is the right question, and the answer requires understanding
what the noise subspace is actually doing for the reckoner.

The noise subspace serves two masters. For the market observer, it
separates signal from noise so the discrete reckoner can predict
direction. Direction prediction is a classification task -- the
reckoner needs to see what is DISTINCTIVE about this moment. The
anomaly highlights the distinctive part. This is valuable.

For the position observer, the task is different. The reckoner
predicts DISTANCES -- continuous values. How far should the trail
be? How far should the stop be? These distances depend on the
STRUCTURE of the market: is it volatile or quiet, trending or
choppy, compressed or expanded? That structure is in the RAW
thought. It is the BACKGROUND, not the anomaly. The noise subspace
strips away exactly the information the distance reckoner needs.

A trending market (markup phase) has wide trails and tight stops.
A choppy market (accumulation/distribution) has tight trails and
wide stops. These characteristics are STRUCTURAL -- they are what
the subspace learns as "normal." By stripping the normal, the
position observer blinds itself to the very thing that determines
optimal distances.

Feed the reckoner the raw thought. The raw thought is stable,
carries the structural information, and does not drift. If the
reckoner still needs to see what is unusual, give it BOTH -- the
raw thought and the anomaly as separate inputs. But the primary
signal for distance prediction is structure, not deviation.

---

## 3. Can the reckoner realign?

No. Not with the current mechanism. The decay (0.999 per
observation, effective window ~1000) shrinks old prototypes but
does not ROTATE them. The bucket prototypes are accumulated sums
of anomaly vectors. When the subspace shifts, the anomaly vectors
rotate in high-dimensional space. Decay makes the old prototypes
smaller. It does not make them point in the new direction.

Consider: the reckoner has 10 buckets. Each bucket's prototype is
a weighted sum of anomaly vectors. At candle 5000, the subspace
shifts because the market moves from accumulation to markup. The
anomaly vectors rotate. The bucket prototypes still point toward
the old anomaly direction. Decay shrinks them by 0.999 per tick.
After 1000 ticks, the old prototypes are at 37% of their original
magnitude. But the direction is unchanged. The new observations
are accumulated into the same buckets, but the new anomaly vectors
point in a different direction. The bucket prototype becomes the
SUM of two non-aligned vectors. The resulting prototype points
somewhere between the old and new directions -- it represents
NEITHER regime well.

This is the effort-result failure that kills traders. The reckoner
puts in effort (132K observations) but the result (prediction
accuracy) degrades. Effort without result means the wrong tool
is being applied. The decay is the wrong tool for this problem.
The problem is not magnitude. The problem is alignment.

---

## 4. Is this a fundamental tension between stripping and learning?

Yes. And no. It is fundamental IF you insist that the same
evolving subspace serves both the noise filter and the reckoner's
input frame. It is NOT fundamental if you decouple them.

The tape reader sees this pattern constantly. The composite
operator accumulates stock at one price level (the background is
range-bound). Then the operator marks up (the background shifts to
trending). A system that learned "range-bound is normal" during
accumulation will flag the markup as anomalous. That is correct --
the markup IS unusual relative to the accumulation phase. But the
system must also learn what DISTANCES to use during markup. If it
learned distances under the old definition of anomalous, those
distances are wrong for the new regime.

The engram idea in the proposal has the right shape. A frozen
subspace is a frozen definition of "normal." The reckoner learns
distances under that frozen definition. Query and learning use the
same coordinate frame. The drift vanishes because the frame does
not move.

But the simpler path is what I said in question 2: feed the
reckoner raw thoughts. The raw thought does not HAVE a coordinate
frame that drifts. The structural information that determines
distances -- volatility, trend strength, range compression -- is
encoded in the raw thought directly. The noise subspace adds a
layer of interpretation that the distance reckoner does not need.

The fundamental tension is real, but it dissolves when you stop
asking the reckoner to interpret the subspace's interpretation.
Let the reckoner read the tape directly.

---

## 5. Does the market observer have the same problem?

Yes. The code in `src/domain/market_observer.rs` (lines 98-107)
follows the identical pattern: update the subspace, extract the
anomaly, predict on the anomaly. The resolve path (line 131-151)
learns from a stored anomaly vector that was captured when the
trade opened. The same drift applies.

But the market observer may be MORE RESILIENT to this drift for
two reasons:

First, the market observer's task is classification (Up/Down),
not regression (distance). Classification needs to distinguish
two categories. Even if the anomaly vectors rotate, the RELATIVE
difference between Up-anomalies and Down-anomalies may be
preserved. The rotation affects both classes equally -- both are
anomalous relative to the same drifting subspace. The boundary
between them may remain stable even as both classes rotate. For
continuous prediction, there is no boundary to preserve. The
absolute position of the vector in the bucket space matters.
Rotation destroys absolute position.

Second, the market observer has a curve (conviction-accuracy
mapping) and engram gating that provide feedback loops. These
may partially compensate for drift by down-weighting predictions
when the reckoner's confidence degrades. The position observer
has neither -- its reckoner queries are used directly.

The builder should measure the market observer's accuracy over
time the same way the position observer's error was measured.
The numbers in `recalib_wins / recalib_total` are available. If
the market observer's accuracy degrades over time, the same fix
applies: consider feeding raw thoughts instead of anomalies. If
it stays stable, the classification task is robust to drift and
only the regression task needs the fix.

---

## The prescription

The disease is diagnosed correctly. The subspace drifts, the
prototypes misalign, the predictions degrade. The mechanism is
proven by the code. Now the treatment.

The conditional verdict rests on one thing: **verify before you
engineer.** The proposal asks the right verification question --
run without noise stripping and measure. Do that first. Do not
build engram synchronization, periodic snapshots, or regime-
specific subspaces until the verification confirms the diagnosis.

If the verification confirms (and it will):

1. **Feed the position observer's reckoner the raw thought, not
   the anomaly.** The raw thought carries the structural signal
   that determines distances. The noise subspace should still
   learn (it may serve other purposes later), but the reckoner
   queries and learns on the raw thought. This is one line change
   in the position observer program: pass `position_raw` instead
   of `position_anomaly` to `reckoner_distances()` and store
   `position_raw` as `position_thought` on the paper trade.

2. **Measure the market observer's accuracy degradation over
   time.** If it degrades, apply the same fix. If it does not,
   the classification task is drift-robust and the anomaly input
   is correct for direction prediction.

3. **Do not build the engram synchronization yet.** It is the
   right architecture for a different problem -- regime-specific
   learning, where different market phases need different distance
   models. That problem exists, but it is downstream of this one.
   Fix the drift first. Then decide whether regime-specific models
   are worth the complexity.

The market transitions between accumulation, markup, distribution,
and markdown. Each phase has a different definition of "normal"
and different optimal distances. The noise subspace correctly
learns each phase's background -- that is its job. The mistake is
feeding the reckoner the RESIDUAL of that evolving background
when the reckoner needs the STRUCTURE of the background itself.

The tape reader does not study what the market ignores. The tape
reader studies what the market IS DOING. The raw thought is what
the market is doing. The anomaly is what the market is ignoring.
For distance prediction, the reckoner needs to read the tape, not
the margins.

One verification. One line change. Then measure again.
