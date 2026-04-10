# Review: Proposal 011 — Paper Lifetime

**Reviewer:** Rich Hickey
**Verdict:** CONDITIONAL

---

Unbounded growth is not simplicity. It is the absence of a decision
masquerading as generality. You did not choose to accumulate 8,208
paper ticks per candle. You simply never chose not to. That is not
the same as deciding that old papers carry value.

Let me separate two things this proposal conflates: the *information
question* and the *mechanism question*.

**The information question:** Does a paper from 300 candles ago carry
signal? You answered this yourself in the wat expression. The composed
thought was from a different context. The distances were from different
volatility. The entry price is ancient. You are tracking extremes from
a dead regime. This is not patience — it is inertia. A paper that
cannot resolve is not waiting. It is stuck.

**The mechanism question:** Should you cap it with a lifetime counter?
Here I am less comfortable. A counter is a mechanism. It hides the
*reason* for eviction behind a number. Why 100? Why not 80? Why not
200? The number will become a tuning parameter, and tuning parameters
are where simple systems go to become complex ones.

The better question: what *is* a paper? It is a hypothesis about what
the market will do from a specific context. When the context is gone,
the hypothesis is meaningless. The paper should not expire by age. It
should expire by *relevance*. You already have the machinery for this
— you have regimes, you have volatility encoding. A paper born in one
regime is not information in another. It is noise.

But I am a pragmatist. Option C is closest to correct: the paper
tracked real extremes. The MFE/MAE distances are facts about what
the market did. Discarding them silently loses information. Producing
a partial resolution at eviction time — an honest "this is what I
saw before I died" — preserves the value without pretending the
full hypothesis resolved.

**Conditions:**

1. Use a lifetime cap. The performance argument alone justifies it.
   9/s is not a design choice, it is a bug.
2. At eviction, produce a partial resolution. Do not silently drop.
   The excursion data is information. The non-resolution is also
   information — it means the market did not cooperate with the
   hypothesis.
3. Treat the cap as a *floor*, not a *parameter*. Pick a number that
   is generous (100, 150), then stop thinking about it. If you find
   yourself tuning it, you have the wrong abstraction.

The paper is a value. Values are immutable. But relevance is not.
Acknowledge that, and the design follows.
