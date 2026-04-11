# Review: Proposal 013
**Reviewer:** Rich Hickey
**Verdict:** CONDITIONAL — Accept D+F now. Accept A later. Reject B, C, E.

## The problem is well-stated

The continuous reckoner accumulates *places* — raw observations, mutable
vectors in a growing Vec — while the discrete reckoner accumulates *values* —
compressed prototypes that are the answer. The proposal correctly identifies
this asymmetry. The continuous reckoner is a lazy collection masquerading as
a learned model. It stores experience as data rather than distilling it into
knowledge. This is the fundamental issue.

## Per-option assessment

**A. Accumulator-based compression.** Simple. One prototype, one direction,
constant cost. The concern about collapsing contextual variation is real but
overstated — if cosine similarity is already your regression kernel, then a
weighted prototype IS the regression compressed into its first moment. You
lose the ability to answer different questions differently, but that is
an honest statement of what one prototype can do. This is the correct
long-term answer. It says: "I know one thing well" instead of "I vaguely
remember everything."

**B. Bucketed accumulators.** Complected. You have braided two concerns:
discretization policy (how many buckets? where are the boundaries?) and
the regression itself. The bucket boundaries are a new parameter that
encodes assumptions about the scalar distribution. You are now tuning
bucket counts instead of solving the problem. Arbitrary parameters are
the opposite of simplicity.

**C. Subspace regression.** Complected. CCIPCA is a fine primitive in
holon's memory layer where it belongs. Importing it into the reckoner
means the reckoner now knows about principal components, projection,
interpolation — three additional concepts interleaved with its job of
"given thought, return scalar." The algebraic honesty argument is
seductive but wrong. Honesty is not the same as simplicity. A
subspace regression is honest about what it captures but complex in
what it requires.

**D. Capped observations with recency.** Simple. It says exactly what it
is: "I remember the last N things." The cost is bounded. The behavior is
obvious. The code change is trivial. Yes, it loses old context — but the
current implementation already does this via `max_observations`. This option
merely makes the cap small enough to matter. It is not algebraically
satisfying. It does not need to be. It needs to work while you figure out
what compression actually means for continuous regression.

**E. Cache the grid's distances.** Complected. The grid should not know
about caching reckoner results. This braids the concerns of "how the grid
composes thoughts" with "how often we query." If the reckoner were fast,
you would not cache. Fix the reckoner, not the caller.

**F. Amortize queries via CSP.** Simple. Each consumer decides independently
whether its question has changed enough to re-ask. This is laziness as a
value — the thought itself carries the information about whether work is
needed. The cosine check is O(D) and the answer is "did my input change?"
which is the consumer's own concern, not the reckoner's. Separation is
clean.

## Verdict

**Do D+F now.** Cap observations low (100-200). Add per-broker staleness
checks. This is two independent changes to two independent concerns.
Together they make the system usable today.

**Do A when you understand the compression.** The single-prototype
continuous reckoner is the right architecture, but only after you have
measured whether one direction captures enough of the regression to be
useful. Run D+F, collect data, then make an informed decision about A.

**Reject B, C, E.** B invents parameters. C imports machinery. E puts
the fix in the wrong place.

The machine that learns should get faster. Agreed. But the path to
faster is through understanding, not through adding more mechanism. D+F
buys you the time. A is where you arrive.
