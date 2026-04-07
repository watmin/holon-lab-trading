# Review — Rich Hickey (Addendum: Coupled Messages)

**1. observe-candle returning curve-valid:** Yes. A prediction without its credibility is an incomplete value. Withholding it forces the consumer to go look it up — a hidden dependency on the observer's internals. The data is already there; you are just refusing to say it out loud.

**2. recommended-distances returning experience:** Yes. Distances without experience is advice without qualification. Stripping the experience count before handing it downstream is information destruction. The consumer should receive (Distances, usize) and decide for itself.

**3. Universal principle:** Yes — but with a precise test. The principle is: a produced value should be a complete value. The test: "if the consumer would be RIGHT to behave differently based on information the producer has and the consumer does not, then you are withholding a fact. Stop withholding facts." But pure functions with no situated knowledge (like encode-candle) have no track record to attach. Don't invent one.
