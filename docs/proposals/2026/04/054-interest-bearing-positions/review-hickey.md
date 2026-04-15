# Review: Hickey

Verdict: CONDITIONAL

## Summary

The core insight is sound: replacing distance prediction (continuous,
drifting, self-reinforcing failure) with a time-cost mechanism (interest)
that creates natural selection pressure. This is simpler than what it
replaces. The exit changes from "predict a number" to "answer a yes/no
at a structurally meaningful moment." That is a genuine simplification.

But the proposal then re-complects by bolting on a favor system, a
rehabilitation protocol, and a penalty decay curve. You removed one
mechanism and grew three in its place.

## The 10 Questions

**1. The lending rate.** ATR-proportional. Not fixed, not "discovered."
The rate must breathe with the market because the cost of holding
through a 2% ATR regime is categorically different from a 0.3% ATR
regime. A fixed rate either kills everything in calm markets or
permits everything in volatile ones. One parameter: the rate as a
fraction of ATR. That fraction can be fixed.

**2. Entry frequency.** Let the interest decide. One per candle is fine.
The broker that enters too often pays more interest across more
positions. The interest IS the gate. Adding a second gate (treasury
limiting entries) is a mechanism solving a problem that the economics
already solve. Don't add a mechanism where a value suffices.

**3. The reckoner's new question.** Discrete is correct. "Exit or hold"
at a trigger point is a classification problem. "How much longer"
is a regression problem masquerading as a prediction. You are good
at classification. You are bad at regression. Play to your strength.

**4. Treasury reclaim.** Automatic. No "one more transition." When the
math says the position is dead, it is dead. Giving the broker one
more chance is sentiment, not arithmetic. The interest exceeded the
value. There is nothing to evaluate. The position is already Violence.

**5. The residue threshold.** The reckoner learns it. Do not add a
minimum residue parameter. The exit fee is arithmetic (0.35% — hard
constraint). Everything above that is judgment, and judgment is what
the reckoner is for. A minimum residue threshold is a magic number.
You just removed magic numbers. Don't add one back.

**6. Both sides simultaneously.** Correct. The treasury lends to both
sides. Old shorts and new longs coexist. The phase labeler's near-
symmetry (2891 buy vs 2843 sell) handles the balance over time. The
treasury's exposure is bounded by the interest clock — adverse
positions die. Restricting to one direction is a constraint born from
fear, not from the data.

**7. The interest as thought.** Three of the four atoms are right.
`interest-accrued` (cost), `candles-since-entry` (duration),
`unrealized-residue` (reward). Drop `residue-vs-interest` — it is
a derived ratio of the other two. The reckoner can discover that
relationship. Encoding it explicitly is telling the reckoner the
answer before it learns. Let it compose.

**8. The denomination.** Per-candle is the right granularity — it matches
the heartbeat. The rate should breathe with ATR (see question 1).
Fixed rate in a volatile asset is a place, not a value.

**9. Rebalancing risk.** The phase labeler's symmetry is necessary but
not sufficient. A directional exposure limit is warranted — not as a
mechanism, but as a hard constraint: the treasury will not lend more
than X% of either asset. This is not fear. This is the treasury
protecting its ability to lend. A bank that lent all its USDC cannot
fund the next long. The limit is arithmetic, not policy.

**10. Paper erosion as the only gate.** Sufficient. The survival rate
against interest IS the EV gate, expressed differently. A broker whose
papers outrun the interest has positive expected value by definition —
the interest is the hurdle rate. Adding a secondary EV check is
measuring the same thing twice with different instruments. One
measurement. One gate.

## What is simple

The three-condition AND for exit is genuinely simple. Each condition is
independently observable. Each is a different concern: structure (phase),
direction (market observer), arithmetic (residue). They compose without
entanglement. This is separation of concerns done right.

The paper-as-proof model composes cleanly. Papers and real positions
follow identical code paths. The only difference is whether capital
moves. This is polymorphism through data, not through mechanism.

The treasury-as-lender is the right abstraction. Lending is simpler
than "managing positions." The treasury's job reduces to: lend, accrue,
reclaim. Three verbs. The broker's job reduces to: borrow, hold, return.
Three verbs. The concerns are properly separated.

## What is not simple

The favor system (rising, falling, rehabilitation, penalty decay) is
a mechanism where measurement would suffice. The survival rate is the
measurement. The gate threshold is the policy. That is two things.
The proposal adds: variable interest rates based on history, penalty
periods, decay curves, "the treasury remembers." That is five more
things solving the same problem the survival rate already solved.

A broker with a 70% survival rate gets the gate. A broker with a 20%
survival rate does not. That is the entire policy. Whether the broker
was previously at 70% and fell to 20% is not relevant — the current
survival rate IS the current truth. History is in the ledger for
humans to read. The machine needs one number: current survival rate.

The on-chain narrative (gas costs, Solana contracts, verifiable ledger)
is aspirational architecture. It belongs in a vision document, not in
a proposal that needs to ship. It is complecting the current design
with a future deployment target. Build the game. Win the game. Then
put it on-chain.

## Condition

Remove the favor system. Remove the variable interest rate based on
broker history. Remove the penalty decay. Remove the on-chain narrative.

The proposal without those sections is clean: interest as natural
selection, three-condition exit, paper survival as proof, treasury as
lender. Ship that. Measure. If you need variable rates later, the
data will tell you. Don't design the rehabilitation clinic before you
know anyone gets sick.

Simplicity is not about having fewer features. It is about not
interleaving things that can be independent.
