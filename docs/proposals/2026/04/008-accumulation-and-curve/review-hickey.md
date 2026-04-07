# Review — Rich Hickey

## Question 1: The Runner Phase

**ACCEPTED.**

The datamancer is correct. The runner is a pure state machine extension. Active, PrincipalRecovered, Runner, RunnerSettled — these are values. The transitions between them are functions of observable facts: did principal return? Is the trailing stop on residue hit? The state machine is specifiable without knowing the residue distribution because the states are not parameterized by the distribution — they are parameterized by events. The distribution determines *how often* each transition fires and *how profitable* the runner is. It does not determine *what the transitions are*. You can draw the state machine on a napkin right now. You should.

The minimal specification is this: a position has a phase (a value, not a place). The phase transitions are: Active + stop-hit → Settled(loss). Active + take-profit-hit → PrincipalRecovered. PrincipalRecovered + runner-trail-hit → RunnerSettled(residue). The runner trailing stop distance is a learnable scalar on the exit observer — the same mechanism that learns k_trail learns k_trail_runner. It is wider because the cost of being stopped out of a runner is zero (principal is already home). The exit observer already predicts distances. This is one more distance. The designers who said "observe the distribution first" were conflating the specification of the mechanism with the tuning of its parameters. The mechanism is designable now. The parameters will be learned. That is the whole point of having reckoners.

## Question 2: Curve Meta-Reckoner

**CONDITIONAL.** Condition: demonstrate that the curve parameters are stable enough to be *values* before building machinery to observe them.

The datamancer is right that there is no circular dependency. The meta-reckoner reads curve state. It does not write to the reckoners it monitors. It is a pure observer of a derived quantity. The architecture permits it — a reckoner that takes (amplitude, exponent, band-width, band-center) as facts and predicts (future-edge) is structurally identical to any other reckoner. The separation is clean. I have no objection to the topology.

But here is where I part with the proposal. A reckoner needs facts that are *values* — things that are what they are at a point in time, not things that are still becoming. How fast do curve parameters converge? How stable are they between recalibrations? If the curve shape changes every 200 candles but the meta-reckoner needs 2000 candles to learn the curve-of-curves, you are observing noise. This is not a design question — it is an empirical one, and it is the *right* empirical question, not the one the designers previously raised. The question is not "will it converge" (it will, given stable inputs). The question is "are the inputs stable enough to be worth observing." Run the current system. Log (amplitude, exponent, band-width, band-center) per recalibration epoch. Plot them. If they are values — if they settle, if they have structure — then the meta-reckoner spec writes itself in an afternoon. If they are noise, the meta-reckoner is a reckoner of nothing. **The condition is one run with curve parameters logged as time series. That is the specific observation needed.**

## Summary

The runner phase is a state machine. State machines are specifiable from first principles. Specify it. The curve meta-reckoner is architecturally sound but its inputs are uncharacterized. Characterize them first — not because the design is unclear, but because building a precise instrument to measure fog is not simple, it is merely not easy.
