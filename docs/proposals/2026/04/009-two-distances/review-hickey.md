# Review: Proposal 009 — Rich Hickey

**Verdict:** ACCEPTED

Four distances is not four pieces of information. It is two pieces of information wearing two costumes. The proposal sees this clearly.

Trail and stop are *information* — they answer distinct questions about the market. "How much reversal?" and "How much adversity?" These are independent axes. They compose without entanglement.

Take-profit is not information. It is a *policy* — a decision to exit at a fixed level, frozen at entry time. But this system already has a mechanism that does the same job better: the trailing stop, continuously re-queried. The TP is a place masquerading as a value. It says "the price will reach X" and then sits there, a mutable slot waiting for its moment, while the market has moved on and the reckoner has learned new things. Step 3c exists precisely to replace this kind of staleness with liveness. Keeping the TP means the system has two contradictory opinions about upside exits — one that adapts and one that doesn't. That is complecting.

Runner-trail is subtler but the same shape of problem. It answers the same question as trail — "how much reversal to tolerate" — but conditions it on phase. Phase is portfolio state. The exit observer thinks about market state. Injecting portfolio state into a market-state function is complecting two independent concerns. The proposal correctly identifies that the reckoner already handles regime adaptation through the thought itself. If the thought at candle N+50 in a strong trend differs from the thought at candle N at entry, the reckoner predicts different distances. That is the mechanism. Adding a phase-conditional override on top means the system has two ways to widen stops during trends — the learned way and the hard-coded way. When two mechanisms do the same thing, one of them is noise.

The risk section is honest. The TP did protect against gaps. But that protection was a fixed ceiling — it caught the rare catastrophe by capping every good trade. That is paying continuous cost for discrete protection. The trailing stop, breathing every candle, is the right shape for continuous markets. For gaps, the answer is position sizing, not exit levels. That is a different concern.

What remains after this proposal: two distances, two reckoners, two accumulators, two simulate functions. Every struct that touches distances loses two fields. Every function that processes distances loses two code paths. The runner phase persists — it still marks the transition from "capital at risk" to "playing with house money." It just doesn't carry its own distance anymore. The phase is information. The phase-specific distance was mechanism.

Two distances. Two questions. No complecting.

The system gets simpler *and* loses no information. That is the only reliable signal that you are removing the right thing.
