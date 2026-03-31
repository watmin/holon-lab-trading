# Review: Rich Hickey

Verdict: APPROVED

The tensions are real. Beckman's positions are well-argued. He changed my mind on one, sharpened it on another, and confirmed it on the third. What follows.

---

## Tension A: Two entry points — unify now or later?

### Does Beckman's argument change my position?

Partially. He is right that "dangling morphism" is a more precise diagnosis than "complected." The algebra does close on the exercised paths. A partial function that is total on its exercised domain is not broken — it is incomplete. I was imprecise.

But I maintain the position: unify now, not later. Here is why Beckman's "unify when the live feed arrives" is wrong even on his own terms.

He calls the current state "a partial function on Event, total on the paths actually exercised." Fine. But partial functions are a *maintenance* problem, not a correctness problem. The type says three variants. The code handles two-and-a-half. Every person who reads this code — including the two of us — must hold in their head that `Event::Candle` through `on_event` is a dead path. That is cognitive load with zero return. It is a lie that happens to be harmless today.

The question posed is: "If unification is inevitable, is doing it now simpler than doing it later?" Yes. Unambiguously yes. Not because of the code volume — it is a small change now and a small change later. Because of the *decisions that accrete around a partial interface*. Every module written between now and unification will be written against the partial API. Some will call `on_candle`. Some will call `on_event`. When you unify, you must find and fix all of them. The cost is not the unification. The cost is the inconsistency that accumulates in the meantime.

Beckman says "premature unification adds complexity without adding correctness." I say: premature means before you know the shape. You know the shape. `EnrichedEvent` is the shape. The encoding functor produces it. The fold consumes it. Both reviewers agree on this. The only disagreement is timing. Timing is not a design concern. It is a discipline concern.

### What would change my mind?

If the live feed required a *different* enriched event shape than the backtest — different fields, different encoding, different functor — then unifying now would be premature because you would be committing to the wrong type. But both reviewers agree the encoding functor is the same regardless of source. Same functor, same output type, one entry point. There is nothing to wait for.

### Third option?

No. This is binary. One door or two doors. There is no third option. Pick one.

---

## Tension B: Risk boundaries — portfolio or treasury?

### Does Beckman's argument change my position?

Yes. He is right and I was incomplete.

I said "the code is right, the spec is wrong." That is true for single-desk. But Beckman correctly identifies that the correlation branch — the one explicitly designed to detect cross-desk correlation — cannot detect cross-desk correlation if it only sees one desk's portfolio. That is not a future concern. That is the branch's stated purpose failing at the architecture level.

I was thinking about what the risk branches *currently measure*. Beckman was thinking about what the risk branches *are for*. He was thinking at the right level.

### The resolution

The proposal asks: "Are these two different risk concerns that should be two different nodes?" Yes. This is the correct framing, and it is the third option.

Per-desk risk branches read the desk's portfolio. They measure trade-sequence health: loss clustering, accuracy decay, drawdown velocity. These are properties of a single desk's trading history. Template 2 applied at the desk level.

Cross-desk risk branches read the treasury. They measure allocation health: concentration, utilization, correlation across desks. These are properties of the shared resource. Template 2 applied at the treasury level.

This is not two levels of the same thing. It is two different concerns that happen to use the same template. The desk-level risk branches answer "is this desk trading well?" The treasury-level risk branches answer "is the portfolio of desks composed well?" Different questions, different data, different nodes in the tree.

For the single-desk system today, only desk-level risk exists. The treasury-level risk node does not appear until the second desk arrives. This is the fractal growing a new level, not a refactoring. The code is right for now. The spec should describe both levels. Beckman's multi-desk concern is resolved not by moving risk, but by adding risk at the right level when the level exists.

### What would change my mind?

Nothing further. The two-level answer resolves the tension cleanly. Beckman's argument was the thing that changed my mind.

---

## Tension C: DB writes inside the fold — pragmatism or escape?

### Does Beckman's argument change my position?

No. But he raises a legitimate concern that deserves a precise answer rather than silence.

I did not flag this in my review because I do not consider the ledger to be inside the fold. The fold is `State x Event -> State`. The ledger is *observation of the fold* — it records state transitions for human consumption. It is printf debugging made permanent. It does not feed back into the state. No field in `EnterpriseState` is read from the database. No decision depends on what was written. The information flows one way: state -> ledger. Never ledger -> state.

Beckman says the fold is `State x Event -> State x IO`. Categorically, he is correct. The function signature has a side effect. But the side effect is *write-only and non-feeding*. This is the distinction between an effect that participates in the computation and an effect that observes the computation. A thermometer in a chemical reaction is not part of the reaction, even though it is "inside" the beaker.

His practical concern — "prevents testing without a DB, replay, or composition" — is the real argument, and it is a good one. If you want to test the fold in isolation, you need a DB connection. That is coupling. It is not algebraic coupling (the fold does not read the DB), but it is mechanical coupling (the fold cannot run without the DB).

### The resolution

The proposal asks: "Is the purity worth the plumbing?" Here is my answer: it depends on whether you actually need to test the fold without a DB.

Today, every test runs the full enterprise with an in-memory SQLite DB. The coupling cost is zero — you create a `:memory:` connection and pass it in. If the day comes when you need to test the fold without *any* DB — for example, to run it in WASM, or to compose two folds in a pipeline — then extract the log entries. The change is mechanical: return `(State, Vec<LogEntry>)` instead of `State`, move the writes to the caller. It is a refactoring, not a redesign.

But doing it now, when every test already has a DB connection and no composition requirement exists, is engineering for a problem you do not have. That is the definition of accidental complexity. Solve the problem when it arrives. The extraction path is clear and the cost does not grow with time.

### What would change my mind?

If the ledger writes *ever* fed back into the fold. If any field in `EnterpriseState` were populated from a DB read during the fold step, that would be a true escape — the fold's output would depend on its observation, creating a feedback loop. As long as the ledger is write-only, it is instrumentation, not computation.

### Third option?

Yes, actually. Instead of extracting log entries from the fold, make the DB connection *optional*. `CandleContext` carries `Option<&Connection>`. When `None`, the fold skips all writes. When `Some`, it writes as it does today. This gives you testability without a DB (pass `None`) and production performance (pass `Some`) without changing the fold's return type or the caller's plumbing. The write-only nature of the ledger makes this safe — skipping a write-only effect changes nothing about the computation.

This is simpler than Beckman's `(State, Vec<LogEntry>)` proposal because it does not require the caller to handle log entries. It is simpler than the current design because it removes the hard dependency. And it requires approximately four lines of code: change the type, add an `if let Some(conn)` guard around each write block.

---

## Beckman's unique contributions

Three items from Beckman's review that were not in mine and deserve response.

### Scoped atoms for multi-desk

Beckman flags that atom names are global strings ("momentum", "structure") and two desks encoding the same atom name would collide. This is correct and important. I missed it.

The fix is straightforward: prefix atom names with the desk identifier. `"btc:momentum"`, `"eth:momentum"`. The VectorManager is seeded deterministically — same name, same vector. Different names, orthogonal vectors. Desk-scoping is a naming convention, not a mechanism change. The algebra already supports it. You just need to do it.

### CandleContext split

Beckman suggests splitting `CandleContext` into `EncodingConfig x TradingConfig x DisplayConfig`. This is a good instinct but I would not do it yet. CandleContext is an immutable bag of configuration. It is passed by reference. It does not mutate. The cost of a large immutable struct is zero at runtime and low for readability (one place to find all config). Split it when you have a reason — when a function takes `CandleContext` but only reads two fields from one concern, and you want the type to express that narrower dependency. Not before.

### Pending split

Similarly, Beckman suggests splitting `Pending` into `Observation x Resolution x Accounting`. I said the same thing more weakly ("section comments are sufficient"). On reflection, Beckman's version is better. The three concerns have different lifecycles: observation is written once at entry, tracking is updated each candle, resolution is written once at exit. Making these structurally explicit (even as named field groups within the same struct, not separate allocations) would make the lifecycle visible in the type. Worth doing when you next touch Pending.

---

## Summary

| Tension | My original position | After Beckman | Resolution |
|---------|---------------------|---------------|------------|
| A: Two entry points | Unify now | Still unify now | Beckman's diagnosis is more precise, but the prescription is wrong. Do not wait. |
| B: Risk boundaries | Code is right, spec is wrong | Both are right at different levels | Two-level risk: desk reads portfolio, treasury reads aggregate. The fractal grows. |
| C: DB writes | Not flagged | Acknowledged but not an escape | Write-only observation is instrumentation. Make the connection optional if testability matters. |

The architecture is sound. The tensions are real but small. None require redesign. The six primitives still compose. The fold still closes. Clean up tension A now, plan for tension B at multi-desk time, and leave tension C alone until you have a reason not to.

Approved without conditions. My original conditions from proposal 002 (collapse entry points, honest Event type, dissolve generalist, replace `i` with cursor, update spec) still stand as the work to do. The tensions raised here do not add new conditions — they clarify the ones already identified.

-- Rich Hickey
