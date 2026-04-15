# Debate: Wyckoff

Verdict: APPROVED

## The proposal answered

I re-read the updated proposal against all five reviews. The designers
listened. Not to opinions -- to measurements of what was missing.

**Beckman's impossible state.** Gone. `PositionState { Active, Grace,
Violence }` is a single enum. No boolean-Option pair. The state machine
closes. Beckman asked for this; the proposal delivers it.

**Beckman's conservation invariant.** Stated explicitly. The equation
holds every candle. Fees are the only real cost. The invariant IS the
ward. Beckman's condition #2 is met.

**Beckman and Van Tharp's ATR window.** Specified: 2016 candles. One
week. Spans the full weekly cycle -- Asia, London, New York, weekend.
Seykota's rule: the median window should span one full cycle of the
dominant periodicity. Pinned, not floating.

**Van Tharp's violence tracking.** `total_violence_loss` is in the
ProposerRecord. Full expectancy is now derivable from the struct.

**Hickey's two-functions-in-a-trenchcoat.** Fixed. `issue_paper` and
`issue_real` are separate functions. Paper always succeeds. Real checks
the predicate and the balance. The boolean is gone.

**Hickey's deadline-vs-interest question.** The proposal names it:
"different mechanisms but the same game." The anxiety atoms encode
urgency through `candles-remaining` and `time-pressure`. The residue
math (gate 3) still punishes weak positions -- minimal residue is
minimal reward. The continuous cost curve of interest is replaced by
the discrete pressure of a deadline. Simpler. The position observer
still learns the shape of urgency from the gradient of time-pressure.
Hickey wanted this named and defended. It is named. The defense is
adequate: the deadline IS the time pressure, and the anxiety atoms
carry the gradient information the observer needs.

**Trust-clamped deadlines.** This addresses Seykota's concern about
favor in bad regimes. Untrusted brokers get 288 candles maximum (one
day). Fully trusted get up to 2016 (one week). The ATR ratio adjusts
within those bounds. A good record does not buy infinite time in a
choppy market -- it buys more time within a regime-appropriate ceiling.
The clamp prevents the favor from becoming a liability.

## What remains open

**Van Tharp's sizing questions.** How much per real trade. Maximum
concurrent exposure. These are not specified. For the lab this is
acceptable -- everything reinvests, no withdrawals. For Solana it is
critical. The proposal is a lab proposal. The sizing rules belong in
the contract proposal.

**Van Tharp's paper cap.** No maximum concurrent papers per broker.
The proposal argues the deadline IS the cap -- papers expire on
schedule. This is correct in steady state but permits burst flooding
during active phases. In the lab, this floods the record with noise.
Worth monitoring but not blocking.

**Hickey's residue split provenance.** 054 did not specify splitting.
055 introduces 50/50 as settled. The ratio is a parameter, acknowledged
as such. The incentive alignment is correct. The provenance question
is a process concern, not an architecture flaw.

## The tape reader's verdict

The architecture is a clearinghouse. The broker reads the tape and
proposes. The treasury validates arithmetic and enforces deadlines.
The separation is total. The four gates structure exit decisions
correctly: three prerequisites (phase, direction, arithmetic) and
one learned decision (position observer experience). The retroactive
labeling builds real intuition from real outcomes.

The five reviewers raised twelve concerns. The updated proposal
addresses eight directly in the text. The remaining four are either
lab-vs-contract scope (sizing, paper caps) or acknowledged parameters
(split ratio). Nothing structural remains unresolved.

Build it.
