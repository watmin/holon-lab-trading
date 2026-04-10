# Review: Proposal 011 — Paper Lifetime

**Reviewer:** Brian Beckman
**Verdict:** REJECTED

---

The proposal asks: should papers have a lifetime cap? This is the
wrong question. The right question is: why is a paper a product type?

A paper today is `(BuySide, SellSide)`. It resolves when BOTH sides
fire. That word "both" is a categorical tell. You have constructed a
product — a conjunction — where the domain gives you a coproduct — a
disjunction.

Consider what actually happens. The buy side fires: price rose then
retraced by the trail distance. That is an observation. It is complete
in itself. It says: "from this context, the market went Up by this
much before reversing." The sell side firing is a symmetric,
*independent* observation about the Down direction.

These are two morphisms with independent domains:

```
buy_resolve  : Paper × PriceHistory → Resolution(Up, distance)
sell_resolve : Paper × PriceHistory → Resolution(Down, distance)
```

You have forced them into a single morphism:

```
resolve : Paper × PriceHistory → Resolution(Up, distance) × Resolution(Down, distance)
```

This is the product of two independent arrows. The product demands
both components. One side waits for the other. In a trending market,
one side fires in a few candles and the other side *may never fire*.
The paper accumulates not because resolution is slow, but because
you are requiring a joint event whose probability is the *product* of
two marginal probabilities. You manufactured your own rarity.

If each side resolves independently, a paper is born, both sides
begin trailing, and each side fires within the trail distance — a
few candles at most. The deque is bounded by *trail distance*, not by
market cooperation. Papers do not accumulate. The O(candles × brokers)
term vanishes. The performance problem is not solved by a cap. It is
dissolved by the correct algebraic structure.

Rich is right that 9/s is a bug. But a lifetime cap treats the
symptom. The bug is the product type. Replace it with a coproduct —
each side is its own resolution event, its own learning event, its
own morphism — and the deque stays bounded by construction.

No cap to tune. No partial resolution to design. No stale papers to
evict. The structure *is* the solution.

**Reject the cap. Decompose the paper.**
