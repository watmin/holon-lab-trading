# Review — Brian Beckman (Addendum: Coupled Messages)

**1. observe-candle returning curve-valid:** Yes. It's a type error not to. The curve-valid flag is the observer's statement about whether its output is geometrically meaningful. Stripping it away is like returning a vector without its basis. Couple them. The output is self-describing.

**2. recommended-distances returning experience:** Yes. Experience is the denominator — the sample size behind the learned quantity. The consumer cannot recover it without reaching into the producer's internals. Return (Distances, usize).

**3. Universal principle:** No to "universal." Yes to a typing discipline. The rule: if the output is a function of learning, the track record of that learning is part of the return type. Raw data (candles) has no track record — it's a datum, not an opinion. Opinions without credibility are untyped. Each layer attaches its own track record, not the sum of the parts'.
