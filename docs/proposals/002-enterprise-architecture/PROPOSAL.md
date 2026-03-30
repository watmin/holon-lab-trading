# Proposal 002: Enterprise Architecture Review

**Scope:** userland — how the trading application uses the six primitives.

## 1. The current state

The enterprise is a self-organizing BTC trading system built from six primitives: atom, bind, bundle, cosine, journal, curve. Two templates (prediction via Journal, reaction via OnlineSubspace) compose through a tree of roles.

### The fold

The enterprise is a fold over `Stream<Event>`:

```
(state, event) → state
```

`EnterpriseState` is the carrier type (~40 fields). `Event` is a sum: `Candle | Deposit | Withdraw`. The loop lives outside the enterprise — the enterprise is a reducer that doesn't know its source (backtest, websocket, test harness).

Two entry points:
- `on_event(Event)` — the public interface for Deposit/Withdraw
- `on_candle(i, &Candle, thought_vec, fact_labels, observer_vecs)` — the fast path for pre-encoded candles (backtest runner pre-encodes via rayon in parallel, then calls this sequentially)

### The tree

```
Treasury (root — holds assets, executes swaps)
│
├── Market branch (Template 1: prediction)
│   ├── Manager (reads expert opinions, learns which configurations profit)
│   │   ├── Momentum observer (own window, own journal, own vocab)
│   │   ├── Structure observer (own window, own journal, own vocab)
│   │   ├── Volume observer (own window, own journal, own vocab)
│   │   ├── Narrative observer (own window, own journal, own vocab)
│   │   ├── Regime observer (own window, own journal, own vocab)
│   │   └── Generalist (fixed window, all facts)
│   └── Exit expert (encodes position state, learns hold/exit)
│
├── Risk branch (Template 2: reaction)
│   ├── Drawdown subspace
│   ├── Accuracy subspace
│   ├── Volatility subspace
│   ├── Correlation subspace
│   └── Panel subspace
│
└── Ledger (pure accounting — records everything, decides nothing)
```

### The encoding pipeline

1. Candle arrives → ThoughtEncoder produces ~150 named facts per candle
2. Each observer encodes at its own sampled window [12, 2016]
3. Observers predict direction (Buy/Sell) via their Journal discriminant
4. Manager encodes the signed expert configuration as a Holon vector
5. Manager predicts deployment direction from intensity patterns
6. Risk branches measure portfolio health via OnlineSubspace residuals
7. Treasury deploys capital when manager proves edge in a sigma-band

### The labels

Each level has its own reward signal:
- **Observers**: Buy/Sell (price direction at first threshold crossing)
- **Manager**: Buy/Sell (raw price direction — did it go up or down?)
- **Exit expert**: Hold/Exit (did holding improve the position?)
- **Risk branches**: no labels (Template 2 — anomaly detection, not prediction)

### The proof gates

Nothing acts on unvalidated information:
- Observers must prove direction accuracy > 52% before their opinions enter the manager's encoding
- Manager must find a sigma-band where accuracy > 51% with 200+ samples before the treasury deploys
- Risk branches learn only from healthy states (gated updates)

## 2. The problem

The architecture works for single-asset (BTC/USDC). The streaming foundation is built (Event, Desk, on_event). But we haven't asked: **does the full architecture compose algebraically?**

Specific concerns:

**A. The encoding split.** Thought encoding (candle → vector) happens outside the enterprise (rayon batch in the binary). The enterprise receives pre-encoded thoughts. This means the enterprise is not a pure fold — it depends on an external encoding step that has its own state (ThoughtEncoder, VectorManager, window samplers). Is this a leak in the algebra?

**B. The two entry points.** `on_event` handles Deposit/Withdraw. `on_candle` handles pre-encoded candles. A pure streaming enterprise would have one entry point. The split exists for performance (batch encoding). Does this complect the interface?

**C. The `i` parameter.** `on_candle` still takes a candle index `i` for age tracking, ledger keys, and pending expiry. In a true stream, there's no global index — just a tick counter. Is `i` a leak from the batch model?

**D. The Pending queue.** Resolved entries look back at entry-time data stored on `Pending`. The queue grows to `horizon * max_concurrent_trades` entries. In a streaming model, this is state. In a fold, this is the accumulator. Is the Pending queue the right structure for the fold's memory?

**E. Risk on Portfolio.** The risk branch feature extraction (`risk_branch_wat`) lives on the Portfolio struct, not in the risk module. The risk branches measure trade-sequence patterns (loss clustering, streaks), not treasury-level state as the spec envisions. Is this the right boundary?

**F. The generalist's identity crisis.** The generalist uses the same encoding as observers but with a fixed window and all facts. Its curve_valid flag is driven by the manager's resolved predictions, not its own. Is the generalist a distinct entity or a vestige of the single-journal era?

## 3. The proposed change

No change proposed. This is a review of the existing architecture. We want the designers to assess whether the current composition is sound and where it leaks.

## 4. The algebraic question

The enterprise claims to be a fold: `(state, event) → state`. But:
- The encoding step lives outside the fold
- The fold has two entry points (on_event, on_candle)
- The state carries a pending queue that grows unbounded in theory
- The `i` parameter is a non-algebraic index from the batch model

Does the enterprise close as a monoid over events? Or does it have algebraic escapes?

## 5. The simplicity question

The enterprise uses only the six primitives. But:
- The encoding pipeline has 21 eval methods producing ~150 facts
- The resolution loop is ~180 lines of sequential concerns
- The Pending struct has 20 fields
- The CandleContext has ~30 fields of immutable config

Is the complexity in the domain (markets are complex) or in the machinery (we've over-engineered the fold)?

## 6. Questions for designers

1. **The encoding split**: should thought encoding live inside or outside the fold? Is the external encoding step a valid optimization or an algebraic escape?

2. **Two entry points**: should on_event and on_candle be unified? If so, how — without losing batch encoding performance?

3. **The pending queue**: is a VecDeque of 20-field structs the right accumulator for a fold over events? Is there a simpler structure that serves the same purpose?

4. **Risk boundaries**: should risk features come from the treasury (as the spec says) or from the portfolio's trade history (as the code does)? Which is more composable?

5. **The generalist**: should it exist as a separate entity, or should it be dissolved — its facts distributed to the specialist observers, its curve replaced by the manager's proof gate?

6. **Desk composition**: when we add a second asset (ETH, SOL), does the architecture compose? Each desk has its own observer tree, its own manager, its own risk branches. The treasury is shared. Does this fractal structure close?
