# Review: Seykota

Verdict: CONDITIONAL

## The trend follower's read

A system that gets worse the more it learns is a system fighting itself. That
is the one thing a trend-following system cannot afford to do. The whole
philosophy is: get in line with the move, stay with it, and get out when the
move is done. Your exit distances are the mechanism for staying with the trend
and cutting when it ends. If those distances degrade with experience, the
system is destroying its own ability to ride winners and cut losers.

91% error in the first thousand candles is already poor. 722% by the end means
the system is hallucinating distances. A trailing stop that is seven times
wrong is not a trailing stop. It is noise with a name.

## Answers to the five questions

### 1. Is the noise subspace the cause?

Yes. Run the experiment. Turn off noise stripping for the position observer
and measure error growth. The proposal already describes the mechanism clearly:
the subspace evolves, the anomaly definition shifts, the reckoner's prototypes
are orphaned. The decay at 0.999 does not help because even the recent
prototypes were accumulated under a drifting reference frame.

The market observer may survive this because its reckoner is discrete (Up/Down).
A discrete reckoner only needs to know which SIDE of a boundary the anomaly
falls on. Continuous reckoners need to know WHERE in the space the anomaly
lives. Drift in the reference frame shifts the absolute position of anomalies.
That kills continuous interpolation while leaving binary classification
relatively intact.

But verify. Do not theorize. Run the ablation.

### 2. Should the reckoner see the raw thought instead of the anomaly?

Yes. The position observer should see the raw thought.

Here is the trend-following argument: the exit distance is about the market's
current structure. How volatile is it. How extended is the move. How crowded
is the trade. These are properties of the RAW market state, not properties
of what is unusual about the market state. A trailing stop does not care
whether today's volatility is normal or anomalous. It cares what the
volatility IS.

Noise stripping makes sense for direction prediction. The market observer
needs to find the signal that distinguishes this candle from the background.
The unusual fact IS the signal for direction. But exit distances are not about
surprise. They are about structure. The raw thought is the right input.

The raw thought is also stable. It depends only on the candle data and the
deterministic encoding. No evolving subspace. No drift. The reckoner's
prototypes and the query vectors live in the same space forever.

### 3. Can the reckoner realign?

Not with the current decay mechanism. Decay shrinks old prototypes toward
zero. It does not rotate them to match the current subspace orientation.
The prototypes need to be re-expressed in the current coordinate system,
not just faded.

The engram snapshot idea (freeze the subspace, score against the frozen
version) would work mechanically. But it adds complexity that the system
does not need if the answer to question 2 is "use the raw thought."

If you insist on keeping noise stripping for exit observers, the engram
approach is the minimum viable fix. Periodic snapshots. Reckoner queries
against the snapshot that was active during learning. But I would not
go there. Simpler systems survive longer.

### 4. Is this a fundamental tension between stripping and learning?

Yes. Online subspace learning and downstream continuous learning are
coupled oscillators with different frequencies. The subspace changes its
basis vectors as it absorbs more data. Any downstream learner that
accumulated prototypes in the old basis is now misaligned. This is not a
bug. It is a property of the coupling.

The tension resolves two ways:

- **Decouple them.** Feed the reckoner the raw thought. No subspace, no drift.
- **Synchronize them.** Engram snapshots, periodic realignment, coordinated resets.

Decoupling is simpler, more robust, and more honest about what the exit
observer needs. The noise subspace was designed for the market observer's
problem (find the unusual signal for direction). It was applied to the
position observer by analogy, not by necessity. Remove the analogy.

### 5. Does the market observer have the same problem?

Likely less severe, possibly negligible. The market observer's reckoner is
discrete. It classifies into Up or Down. Classification is robust to smooth
transformations of the input space because it only needs the BOUNDARY to be
approximately correct. Continuous interpolation needs the entire geometry to
be stable.

But check it. The market observer tracks `recalib_wins / recalib_total`.
Plot that ratio over time. If it degrades late in the run, the market
observer has the same drift. If it holds steady while the position observer
degrades, the discrete/continuous distinction is confirmed.

## The prescription

1. **Run the ablation.** Position observer without noise stripping. Measure
   error over time. This takes one run. Do it before anything else.

2. **If confirmed: remove noise stripping from position observers.** Feed
   the raw position thought to the reckoners. Keep the noise subspace on
   the market observer where it serves its purpose.

3. **Do not reach for engrams yet.** Engrams solve a synchronization problem
   that goes away when you remove the coupling. If a future observer genuinely
   needs anomaly-based continuous learning, then engram snapshots are the
   right tool. Not today.

4. **Measure the market observer's accuracy over time.** Even if it is not
   degrading now, the mechanism exists. Know your exposure.

The condition: I approve this as a finding and a direction. The ablation
must be run before any code changes ship. Do not assume the mechanism is
the cause until the measurement confirms it. Measure before you cut.

The trend is your friend. The exit is how you keep the friendship. Do not
let a drifting reference frame corrupt your exits.
