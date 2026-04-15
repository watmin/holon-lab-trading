# Debate Round 2: Hickey

Verdict: APPROVED. The condition is met.

## What changed

The favor system is gone. In its place: "Earning favor" — a proposer
struct built from the ledger, a uniform predicate, no identity
preferences. The treasury applies the same function to every proposer.
No asymmetric decay. No penalty periods. No rehabilitation narrative.
No variable rates based on history. The struct passes or it does not.

This is what I asked for. The survival rate (and whatever else the
struct contains) is computed from the ledger. The predicate is applied
uniformly. The treasury remains headless — blind to strategy, deaf to
reasoning, memoryless with respect to path. Two proposers with identical
structs get identical treatment. The equivalence-class property holds.

## What the proposer record adds over raw survival rate

In my first debate I said: one number, current survival rate. The
proposer struct is more than one number — it contains survival rate,
mean Grace residue, paper count. That is acceptable. These are all
folds over the ledger. They are stateless computations of state. They
compose. They do not introduce path dependence. The struct is a
snapshot of the trailing window, not a biography.

Beckman's point lands here: survival rate plus mean residue is the
minimal pair that guards against Van Tharp's edge case (high survival,
tiny residues, negative expectancy). Two numbers. Two thresholds.
Still headless. The proposer struct is the right container for these
numbers. I withdraw my insistence on exactly one number.

## The headless treasury is now consistent

In round one, the proposal contained two treasuries: the headless
arbiter and the remembering punisher. That tension is resolved. The
"Earning favor" section and the "Headless treasury" section now agree.
The treasury computes from the ledger. The treasury applies a uniform
predicate. The treasury does not remember grudges. The treasury does
not price risk by identity. The treasury is a program with a record.

The critical line: "The proposer who reveals nothing and produces
Grace is funded." That is headless. Strategy is private. Outcomes are
public. The treasury judges the public part. This composes to
multiplayer without modification.

## Remaining observations (not conditions)

Seykota conceded the favor system was inconsistent with the headless
treasury. Wyckoff proposed two windows (short for gate, long for rate)
as a compromise. I note that two windows computing the same struct
from different spans is still a stateless fold — it does not violate
headlessness. But it is a refinement for later, not a condition for
now. Build the single trailing window first. Measure. If the data
shows that trajectory information improves capital allocation, add
the second window. Do not design it in advance.

Van Tharp's correlated-samples concern remains valid. The proposer
struct should be computed over independent clusters, not raw paper
count. Beckman's suggestion — cluster by phase window, count per
cluster — is the right measurement adjustment. This is arithmetic
on the ledger, not a new mechanism.

## Final position

The favor system is replaced with a uniform predicate over a
ledger-derived struct. The headless treasury is internally consistent.
The interest mechanism, three-condition exit, discrete reckoner, and
paper survival as proof are unchanged and clean. Five independent,
composable concerns.

APPROVED. Build it.
