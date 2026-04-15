# Review: Hickey

Verdict: CONDITIONAL

## What I like

The treasury is a value. It holds data. It applies predicates. It does
not reason. This is the right separation. The broker thinks; the treasury
counts. Two different concerns that never touch. Clean.

Paper is almost a value. Immutable fields, one mutable flag (resolved),
one slot (outcome). In practice this is a state machine with two
transitions: unresolved -> Grace, unresolved -> Violence. That is
fine. But call it what it is. A Paper is born open and dies resolved.
It never goes back. Make `resolved` and `outcome` a single enum:
`Active | Grace(f64) | Violence`. One field. No boolean-Option pair
that can disagree.

The ExitProposal is minimal. paper_id and current_price. The broker
does not explain itself. The treasury does not ask. This is correct.
The proposal is a value — it carries data, not intent.

validate_exit is pure arithmetic on the treasury's own copy. The
broker's copy is irrelevant to the decision. The treasury never
trusts the broker's accounting. Good.

The flow is honest: deadline check is the only autonomous act.
Everything else is response to a proposal. Reactive systems are
simpler than proactive ones because they have fewer reasons to run.

## What concerns me

**054 says interest. 055 says deadline.** These are different
mechanisms. 054's violence is economic death — interest erodes value
continuously. 055's violence is a clock — the deadline expires. The
proposal says it implements 054, but it replaced the core mechanism.
Interest-as-anxiety became deadline-as-anxiety. The anxiety atoms
changed from `interest-accrued` and `residue-vs-interest` to
`candles-remaining` and `time-pressure`. This is a design decision
hiding inside an implementation proposal. Name it. Defend it. Or
acknowledge that 055 supersedes the interest model from 054.

**The residue split is new policy.** Half to proposer, half to pool.
054 says nothing about splitting. 055 introduces it as settled fact.
This is a significant economic decision — it changes the incentive
structure. It deserves its own section explaining why 50/50 and not
some other ratio. The ratio is a parameter pretending to be a constant.

**is_real boolean in issue_paper.** One function with a boolean
that changes its behavior is two functions wearing a trenchcoat.
`issue_paper_trade` and `issue_real_trade` would be simpler. The
boolean creates a branch that the type system should enforce.

**papers_by_owner is derived state.** It can be computed from
papers. Storing it means two things that must agree. Either compute
it on demand (it is a query, not state) or accept the coordination
cost and be explicit about when it updates.

**The eight-step flow.** Steps 2 and 5 are both "broker receives
verdicts." Steps 3-4 are exit. Steps 6-7 are entry. This is four
logical steps with substeps, not eight. The numbering obscures
the structure. Simplify: (1) treasury enforces deadlines,
(2) brokers propose exits, treasury validates, (3) brokers propose
entries, treasury issues, (4) brokers propagate learns.

**Gate 4 can override gate 2.** The proposal says the position
observer's experience overrides the arithmetic. But gate 3 (residue
math) is also arithmetic and presumably cannot be overridden — you
cannot exit at a loss. So the gates are not a simple AND. Gates 1-3
are prerequisites. Gate 4 is the decision. Say that. "Three
prerequisites and one decision" is simpler than "four gates where
one can override another."

## The question I would ask

The deadline replaces interest. Why? Interest creates continuous
pressure that varies with position performance. A deadline creates
binary pressure that varies with nothing. Interest selects for
runners — 054's strongest insight. A deadline selects for trades
that happen to resolve before an arbitrary clock. The deadline is
simpler, yes. But is it the same game? If not, this is Proposal
055, not "implementation of 054."

The condition: reconcile the interest-to-deadline shift explicitly,
or rename the proposal to acknowledge it replaces 054's economic
model with a temporal one.
