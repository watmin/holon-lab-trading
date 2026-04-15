# Debate: Hickey

Verdict: **APPROVED**

## Conditions met

**1. Interest vs deadline — acknowledged explicitly.** The proposal now
contains a section "Deadline, not interest" that says it plainly:
"Interest was a proxy for time the whole time. The deadline IS the time
pressure." It does not pretend to implement 054's interest model. It
names the replacement and defends it. The anxiety atoms encode
candles-remaining and time-pressure — continuous gradients, not a
binary clock. The mechanism is simpler. The game is the same: outrun
the cost or die. This is honest. Condition satisfied.

**2. Paper struct as enum.** `PositionState { Active, Grace { residue },
Violence }` replaces the boolean-Option pair. One field. No impossible
states. The type now closes the state machine. Exactly what I asked for.

**3. Two functions, not one with a boolean.** `issue_paper` and
`issue_real` are distinct functions with distinct signatures. Paper
always succeeds, fixed reference amount, no capital moves. Real checks
the record, checks the balance, moves capital. The type system enforces
the difference. `PaperPosition` and `RealPosition` are separate structs.
The trenchcoat is off.

**4. 50/50 acknowledged as parameter.** The proposal now states "The
50/50 split is a parameter, not a law." It explains why: proposers must
be rewarded, passive depositors must benefit, the split is the alignment
mechanism. I would still like to see this discovered through simulation
rather than asserted, but the proposal no longer pretends it is a
constant. Adequate.

## What improved beyond my conditions

The Proof of Grace staking model is new and well-structured. Depositors
stake capital, proposers do work, yield comes from measured outcomes.
The conservation invariant is stated explicitly and declared testable
every candle. Beckman asked for this too — it is here. The broker
proposes exits, the treasury validates arithmetic only — the headless
separation is cleaner than before.

## What I would still watch

The `papers_by_owner` index is still derived state that must agree with
`papers`. Accept the coordination cost or compute it on demand. Minor.

The eight-step flow is still eight steps. It is four logical steps with
substeps. The numbering obscures the structure. But this is presentation,
not architecture.

## Summary

The four conditions I raised are addressed. The deadline replacement is
named and defended, not hidden. The type system closes the state machine.
Paper and real are distinct types with distinct issuance. The split is
a parameter. The proposal is honest about what it is and what it changed.

Approved.
