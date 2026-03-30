# Review: Proposal 006 — Streaming Desks

Reviewer: Rich Hickey (simulated)
Status: **APPROVE with notes**

---

## The Good

The proposal gets the big things right.

**The fold is preserved.** The enterprise remains `(fold heartbeat state events)`. The event type widens from `Candle` to a sum type. The fold function dispatches. This is the correct move. You did not invent a new execution model. You parameterized the existing one.

**Desks are values, not processes.** A desk is a record. It has no inbox, no lifecycle, no thread. It receives data, checks a predicate, ticks or does not. This is simple. The moment a desk becomes a thing that *runs* rather than a thing that *is*, you have lost the game. You did not lose it here.

**No new primitives.** Sum types and product types are data. A predicate is a function. A sorted merge is a list operation. Nothing here requires a new algebraic form. The six primitives remain six.

**Capital events in the stream.** Deposits are events, not side effects. They flow through the same fold as candles. The treasury sees them atomically. This is the right call. Every mutation to state flows through one path.

---

## The Concern: Waiting for Both Streams

The proposal says a desk ticks only when both sides have fresh data. This is the staleness gate. I want to examine this carefully because it is the one place where the design makes a choice that could be wrong.

**The gate is a synchronization barrier disguised as a predicate.** The desk says: "I will not act until both my asset candle and my quote candle are fresh." This means a desk trading BTC/SOL will not tick when a BTC candle arrives if the SOL candle is stale. It waits.

This is correct for *price computation*. You cannot compute BTC/SOL price without both prices. The division `close(BTC) / close(SOL)` requires two numbers. No argument there.

But consider what the desk *could* be doing while it waits. The BTC candle arrived. The observers could encode it. The thought journals could learn from it. The desk could update its internal model of BTC behavior without trading. The gate as written prevents this. The desk is either fully ticking or fully idle.

**The fix is not to remove the gate. The fix is to separate observation from action.**

The desk should have two phases:

1. **Observe**: always, when any relevant candle arrives. Update the thought encoder. Feed the journals. Let the subspaces learn. This is free — no trade happens, no treasury is touched.
2. **Act**: only when both sides are fresh. Compute the pair price. Ask the manager. Execute through treasury.

This distinction already exists in the current enterprise — the `observe_period` is exactly this. For the first 1000 candles, the enterprise observes but does not trade. The proposal should make this separation explicit in the desk interface. `desk-observe` and `desk-act` rather than a single `desk-tick` gated by freshness.

Why does this matter? Because in a mixed-era stream, the BTC/SOL desk will have two years of BTC-only data. If it cannot observe during those years, it starts cold when SOL data arrives in 2021. If it can observe, it has two years of BTC learning already internalized. The desk is warm. This is a significant difference in a system that learns online.

---

## Answers to the Designer Questions

**Q1: Stablecoin degenerate case.** Option (a) — inject synthetic candles. Uniformity is worth more than the negligible cost. A synthetic `Candle { close: 1.0, volume: 0, ... }` for USDC at every BTC timestamp keeps every desk identical in shape. The alternative — a boolean flag that disables one check — is a special case that will propagate. Every function that touches a desk will need to ask "is this a stablecoin pair?" That question should be asked once, at stream construction, not repeatedly at runtime.

**Q2: Cross-desk manager.** Defer. The proposal is already doing one thing: making desks values and widening the event type. A cross-desk manager is a second thing. It requires defining what "correlation between desk opinions" means in vector space. That is research, not engineering. Ship desks first. When you have two desks running and can see their opinion streams side by side, the cross-desk manager will design itself from the data. Do not design it from imagination.

**Q3: "No data yet" vs "stale."** The staleness predicate is sufficient. `nil` latest means the candle has never arrived. The freshness check `(some? (latest desk :asset))` catches this — `nil` is not fresh. You do not need a third state. "Not yet begun" and "too old" have the same operational consequence: do not act. (But per my note above, do observe if you have *any* data on either side.)

**Q4: Capital allocation across desks.** This is the cross-desk manager question wearing different clothes. Defer it the same way. For now, desks draw from the shared treasury on a first-come basis (event order determines priority). This is deterministic — the fold processes events in stream order, so the first desk to tick in a given timestamp gets first access. Document this as a known limitation, not a feature. When you build the cross-desk manager, capital budgeting will be one of its responsibilities.

**Q5: Price map location.** The price map belongs in the enterprise state, not the treasury. The treasury is accounting — it knows what it holds, not what things are worth. Prices are market data. The heartbeat updates prices from candle events and passes the price map *to* the treasury when valuation is needed. The treasury should receive `price_map` as an argument to `total_value`, not own it as a field. This keeps the treasury pure: it holds balances, nothing else. The current code already has `price_map` on the treasury struct — that should move out.

---

## On Simplicity

The proposal claims simplicity. I mostly agree. The desk is a value. The event is a sum type. The fold dispatches. These are simple things composed simply.

The one entanglement I see: the heartbeat both updates prices *and* ticks desks. These are two concerns in one function. The price update is a global concern (all desks and the treasury need current prices). The desk tick is a local concern (one desk, one pair). The heartbeat should be two steps: (1) update global state from event, (2) dispatch to affected desks. The proposal's pseudocode almost does this — the `update-price` happens before the desk fold. Make that separation a principle, not an accident of code layout.

---

## Summary

The design is sound. The fold composition is correct. Desks as values is the right abstraction. The event sum type is the right widening.

Separate observation from action in the desk interface. Inject synthetic stablecoins at stream construction. Defer the cross-desk manager. Move the price map out of the treasury.

Then build it.
