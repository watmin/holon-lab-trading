# Debate: Hickey

## Does the headless treasury resolve the condition?

Partially. The headless treasury section is the strongest writing in
the proposal. Blind to strategy. Deaf to reasoning. Evaluates outcomes
only. A program with a record, no one home. That is exactly what I
asked for. The treasury cannot implement a favor system because it
cannot see what it would need to favor. It sees entries, interest,
and resolutions. It computes a survival rate. It opens or closes
the gate. That is simple. That composes. That scales to multiplayer.

But the favor section still sits in the same document. Read them
back to back. The favor section says: "the rate never drops as fast
as it rose after the fall. The treasury remembers." The headless
section says: "the treasury has no mind. It knows nothing about the
broker's reasoning." These are in tension. The favor system requires
the treasury to implement asymmetric decay curves, penalty periods,
rehabilitation protocols. The headless treasury computes a survival
rate from a ledger. Pick one. They cannot both be the treasury.

The headless section is the right one. Strip the favor section. The
survival rate is the gate. The interest rate is a function of the
ledger's statistics -- not of narrative concepts like "trust" and
"rehabilitation." If you want variable rates, make them a pure
function of trailing survival rate. That is a fold over the ledger.
Folds are stateless transformations of state. The favor section is
stateful narrative dressed as mechanism.

With the favor section removed: the condition is met. The headless
treasury plus interest-as-selection plus three-condition exit plus
paper survival is a clean, composable system.

## Responding to the four voices

### Seykota

Seykota approves without reservation. I respect the instinct -- the
interest mechanism IS natural selection, and trend followers know
natural selection. But "build it" without addressing the favor
contradiction is premature. The proposal as written contains two
treasuries: the headless arbiter and the remembering punisher. You
cannot build both. You must choose. Seykota chose by ignoring the
contradiction. That works in practice. It does not work in architecture.

His suggestion to add residue-vs-interest rate of change as an
anxiety atom is sound. Trajectory matters. But it should be a
vocabulary decision, not a proposal mandate.

### Van Tharp

Van Tharp identifies the real statistical risk: correlated samples.
He is right. One entry per candle during a 53-candle window produces
53 positions measuring the same market move. The survival rate of
those 53 papers is one observation, not fifty-three. This matters
for the gate. The treasury's ledger must track which papers share
a phase window. The effective sample size is the number of independent
phase entries, not the number of papers.

His demand for explicit expectancy calculation is where I disagree.
Beckman has the right framing: survival rate against interest IS
expectancy measured differently. The interest is the hurdle rate.
Papers that survive have positive R by definition -- they outran
the cost. Papers that die have negative R by definition -- the cost
outran them. Survival rate times average survivor residue minus loss
rate times average Violence loss IS expectancy. Computing it
separately is redundant. But Van Tharp's instinct to verify is
healthy. The treasury should expose both numbers from the ledger.
Not as a gate. As an observable.

His conditional on making the favor system "mechanical and
expectancy-driven" is the right direction but still too complex.
The favor system should not be made mechanical. It should be removed.
The survival rate is the mechanism. The interest rate is the
parameter. Two things. Not seven.

### Wyckoff

Wyckoff reads the proposal through Wyckoff phases and finds it
consonant. The accumulation/distribution mapping is insightful but
I will note: the proposal does not need Wyckoff's framework to be
correct. The interest mechanism works whether you call the entry
"accumulation detection" or "three higher lows." The naming does
not change the algebra.

His suggestion to publish treasury exposure as a fact rather than
impose a hard limit is elegant. Exposure-as-thought rather than
exposure-as-constraint. The brokers self-correct from awareness.
That preserves independence between positions while giving the
system the information it needs to self-balance. I endorse this
over hard directional limits.

### Beckman

Beckman sees the algebra cleanly. The state machine
{Active, Grace, Violence} with deterministic transitions is the
correct formalization. His observation that the favor system is
"visible state -- a fold over the broker's history" is technically
accurate but misses the point. The question is not whether the
fold is well-defined. The question is whether it is necessary.
A fold that computes asymmetric decay over a penalty period is a
well-defined fold that you do not need. The survival rate is a
simpler fold over the same data that answers the same question.

His rate discovery mechanism -- start from median phase duration,
adjust from survival distribution -- is the most principled answer
to Question 1. Better than "ATR-proportional" (which is a place)
and better than "fixed" (which ignores regime). The rate as a
feedback loop from the ledger is a proper morphism. I endorse it.

## Final position

Remove the favor section. Keep the headless treasury. The proposal
then contains: interest as natural selection, three-condition exit,
discrete reckoner, paper survival as proof, treasury as headless
lender. Five things. Each independent. Each composable.

With that excision: APPROVED.
