# Proposal 003: Enterprise Tensions

**Scope:** userland — resolving the tensions between Hickey and Beckman on proposal 002.

## Origin

Proposal 002 asked the designers to review the enterprise architecture for the first time. Both returned CONDITIONAL. They agreed on four points and diverged on three. This proposal presents the divergences and asks each designer to respond to the other's position.

## What they agreed on

These are settled. No debate needed.

1. **Encoding split is valid.** Map-then-fold. The encoding functor commutes with the fold. Not a leak.
2. **Pending queue is correct.** The right accumulator for a learning fold with delayed labels. 20 fields are domain complexity.
3. **Generalist is a vestige.** Dissolve it. It borrows the manager's proof gate instead of earning its own. Categorical orphan.
4. **`i` parameter is an escape.** Replace with the fold's own cursor. The candle index is the batch runner's concern.
5. **Desk composition fractals.** The product category closes with scoped atoms and per-desk state.

## The three tensions

### Tension A: Two entry points — unify now or later?

**Hickey** says this is complected. Two functions advance the state machine. The caller must know which to call. Unify into one `on_event(EnrichedEvent)` where the Candle variant carries pre-encoded thoughts. Do it now — simplicity is not a future concern.

**Beckman** says this is a dangling morphism, not a leak. `on_candle` is `on_event` post-composed with the encoding functor. The algebra closes on the paths actually exercised. The partial function on Event is fine for a backtest-first system. Unify when the live feed arrives.

**The tension:** Is a partial function on a sum type acceptable in a system that claims to be a fold? Hickey says no — the type is the contract, a dead variant violates it. Beckman says yes — partiality is documented, the exercised paths close, premature unification adds complexity without adding correctness.

**Question for both:** Given that we ARE building toward a live feed (not hypothetically — websocket is the next domain after multi-asset), does the timeline change the answer? If unification is inevitable, is doing it now simpler than doing it later when there's more code to change?

### Tension B: Risk boundaries — portfolio or treasury?

**Hickey** says the code is right and the spec is wrong. Risk features measure trade-sequence patterns (loss clustering, streaks, accuracy decay). These are properties of trading history. The portfolio is the right home. For multi-desk, each desk has its own portfolio and its own risk branches. Treasury-level risk (utilization, concentration, cross-desk correlation) is a different concern — a future node between treasury and desks.

**Beckman** says the algebra closes either way, but the natural transformation's domain is wrong for multi-desk. If risk reads the portfolio, each desk's risk branch sees only that desk's history. If risk reads the treasury, it sees aggregate exposure. The correlation branch is supposed to detect cross-desk correlation — it can't if it only sees one desk's trades.

**The tension:** Both are right about different things. Hickey is right that current risk features ARE trade-sequence patterns and the portfolio IS the natural home. Beckman is right that multi-desk correlation REQUIRES a treasury-level view.

**Question for both:** Are these two different risk concerns that should be two different nodes? Per-desk risk (trade history, portfolio) AND cross-desk risk (treasury-level allocation, correlation)? If so, Template 2 applied at two levels — exactly the fractal pattern the architecture already uses. Does this resolve the tension or create a new one?

### Tension C: DB writes inside the fold — pragmatism or escape?

**Hickey** did not flag this. The ledger is measurement — it records, it doesn't decide. The fold produces state; the ledger observes the state. This is instrumentation, not computation.

**Beckman** flags it as the second algebraic escape. The fold is `State x Event → State x IO`, not `State x Event → State`. A pure fold would return `(new_state, Vec<LogEntry>)` and the caller would write. The current design fuses the fold with its observation, preventing testing without a DB, replay, or composition.

**The tension:** Is the ledger inside or outside the fold? If inside, it's a side effect in the catamorphism. If outside, we collect log entries and batch-write them — which is what we already do for the DB transaction batching (`db_batch >= 5000 → COMMIT`). The infrastructure for external writes exists.

**Question for both:** The ledger is currently the ONLY side effect in the fold (treasury mutations are state, not IO). If we extracted it, the fold becomes pure: `State x Event → State x Vec<LogEntry>`. The caller writes the log entries. Is this worth the change? The fold step would return richer output, but the caller would need to handle the log entries. Is the purity worth the plumbing?

## What this proposal asks

We are not asking for new architecture. We are asking the designers to address each other's positions on these three tensions. For each:

1. Does the other designer's argument change your position?
2. If not, what would?
3. Is there a third option neither of you considered?

The datamancer will write RESOLUTION.md after reading both responses.
