# Debate Round 2: Beckman

Verdict: **APPROVED**

## The earning-favor struct closes the algebra

The original favor system was path-dependent: two brokers with
identical current survival rates but different histories received
different rates. I objected. Hickey objected. Seykota withdrew
approval. The favor system violated the headless property.

The replacement — "Earning favor" — resolves this cleanly. The
treasury keeps a struct per proposer. The struct is built from
the ledger: papers submitted, papers survived, mean Grace residue.
A predicate reads the struct and returns fund or deny. Same
predicate for every proposer. Same threshold. No variable rates
per identity. No asymmetric decay. No rehabilitation narrative.

This is the fold I asked for. The struct is a product type over
ledger statistics. The predicate is a morphism from that product
to Bool. The composition is: ledger -> struct -> predicate -> gate.
Each arrow is a pure function. No path dependence. No memory beyond
what the trailing window contains. The headless property is preserved.

## Van Tharp's two conditions

**Correlated samples.** The struct contains "papers submitted" and
"papers survived." Van Tharp's concern was that raw paper count
inflates confidence. The struct does not mandate how these are
counted. The implementation can count independent clusters — one
per phase window per broker — without changing the struct's type.
The predicate still reads the same fields. The measurement becomes
honest. This is a calibration detail, not an architectural flaw.

**Expectancy.** The struct contains "mean Grace residue." Combined
with survival rate, this IS expectancy. Beckman round 1 slipped in
"and positive mean residue" — that was the concession. The struct
makes it explicit. Two fields. One fold. Van Tharp's condition is
met by the data the struct already carries.

## Hickey's excision

Hickey demanded: remove the favor system, remove variable rates
by history, remove penalty decay. The earning-favor section does
exactly this. The treasury applies one predicate. The predicate
reads current statistics, not trajectory. A broker denied last
candle whose struct now passes is approved this candle. No memory
of the fall. The sliding window forgets automatically. Hickey's
condition is met.

## Seykota's withdrawal

Seykota withdrew approval of the favor system and adopted Wyckoff's
exposure-as-fact over graduated rates. The earning-favor struct is
consistent with both positions. The treasury publishes facts (the
struct). It does not set differential prices. One rate. One gate.
Seykota can re-approve.

## Wyckoff's two-window proposal

Wyckoff proposed short and long windows to capture trajectory
without narrative. The earning-favor struct does not specify window
length — that is implementation. A struct built from a 200-candle
window and one from a 2000-candle window are the same type with
different parameters. The predicate can require both. This is
compatible. But I note: two windows introduce a form of path
sensitivity that the headless treasury should resist. The short
window alone — current performance — is the cleaner choice. If
the long window proves necessary, the data will show it. Do not
design the memory before you know you need it.

## The headless treasury is algebraically closed

The treasury maps actions to outcomes. The struct maps outcomes to
statistics. The predicate maps statistics to a gate decision. Each
is a pure function. The composition is a functor from the category
of broker actions to the category of {fund, deny}. The functor is
forgetful — it discards strategy, vocabulary, reasoning. It
preserves only what the treasury needs: did you produce Grace or
Violence, and at what magnitude?

The treasury is intentionally ignorant. The proposer is free to
publish or conceal their strategy. The outcomes are public. The
gate is mechanical. The struct is the interface. The predicate is
the contract.

This closes. Build it.
