# Debate Round 2: Seykota

Verdict: **SETTLED. Build it.**

## What converged

The five voices found the same answer from different directions.
That is how you know the answer is real.

1. **The favor system is dead.** I withdrew approval in round 1.
   Hickey killed it on principle. Beckman killed it on algebra --
   path dependence violates the equivalence-class property of the
   headless treasury. Van Tharp called it premature. Wyckoff tried
   to save it with two rolling windows, but even his version is
   more mechanism than the headless treasury needs. The proposal
   now replaces favor with "earning favor" -- a proposer struct
   built from the ledger, a uniform predicate, no identity-based
   preferences. One rate. One gate. Same for everyone. The headless
   treasury is headless. This is resolved.

2. **Discrete exit.** Unanimous. No one argued for continuous.
   "Exit or hold at this trigger" is classification. The system
   is good at classification. It is bad at regression. Proposal
   053 proved this. Do not revisit it.

3. **ATR-proportional rate with feedback.** Beckman's anchor
   (zero-move position dies in one phase duration) gives the
   initial condition. The survival distribution shifts the rate.
   Everyone agreed the rate must breathe. This is the mechanism.

4. **Automatic Violence.** Unanimous. No grace period. When the
   interest exceeds position value, the claim is revoked. The
   math decides. No appeals.

5. **Both sides simultaneously.** Unanimous. The treasury lends
   to longs and shorts. Independent clocks. Independent claims.

## What remains in tension

Two items. Neither blocks construction. Both require measurement.

**Correlated samples.** Van Tharp says the denominator is wrong --
53 entries in one phase window is one observation, not fifty-three.
Wyckoff says the interest clock decorrelates them. Beckman proposes
cluster-aware counting from timestamps the treasury already has.
I sided with Beckman in round 1. I still do. The fix is measurement,
not architecture. Build the ledger. Compute survival over clusters.
If the clusters show the raw count was honest, relax. If they show
Van Tharp was right, tighten. The data will settle this. Not debate.

**Expectancy vs survival.** Van Tharp wants the full calculation.
Beckman showed that survival rate plus mean Grace residue captures
it -- two numbers, both derivable from the ledger. Hickey says
expose both as observables, not as a gate mechanism. I agree with
Beckman's refinement: track survival rate AND mean residue. Two
numbers. Two thresholds. Still headless. This is a one-line
addition to the gate predicate, not a redesign.

## The proposal as it stands

The "earning favor" section resolves the central contradiction from
round 1. The treasury no longer remembers grudges. It computes a
struct from the ledger. It applies a predicate. Fund or deny. The
struct is headless -- it contains measurements, not strategy. The
predicate is uniform -- same threshold for every proposer. The
proposer who reveals nothing and produces Grace is funded. The
proposer who publishes everything and produces Violence is denied.
Outcomes are public. Strategy is private. That is the correct
separation.

The headless treasury is the architectural constraint that resolved
the debate. Everything that required the treasury to have opinions
about brokers is gone. What remains is a program with a record.

## Final word

The trend is your friend until it ends. The interest tells you
when it ended -- not by prediction, but by cost. The trades that
survive the interest ARE the trends. Everything else was noise
pretending to be signal, and the interest charged it rent until
it admitted the truth.

The proposal is settled. Build the headless treasury. Let the
ledger be the judge. The blind judge is the only honest one.
