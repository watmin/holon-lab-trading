# Proposal 005: Co-Learning Panels — Positions as Message Queues

## Problem

The market observers predict direction. But they cannot validate their own predictions. The label that says "you were right" or "you were wrong" comes from somewhere else — the position lifecycle. Today that "somewhere else" is an arbitrary horizon timeout with MFE/MAE comparison. The observers learn, but the quality of their learning depends entirely on the resolution mechanism, which is uncoupled from any learning of its own.

Meanwhile, the exit expert learns Hold/Exit but is never queried. It accumulates knowledge about position management that nobody uses. The stop loss and take profit are fixed ATR multipliers — parameters, not predictions.

Two halves of a conversation, neither listening to the other.

## Insight

The position IS the message queue.

Market observers produce a message: "enter here, this direction, this conviction." That message becomes a ManagedPosition. The position lives, accumulates state — P&L, MFE, MAE, hold duration, distance to stop, distance to TP. The exit observers read that state every candle. When the exit panel says "exit" (or the safety stop fires), it produces a message back: "this is how it ended." That message becomes the learning label for the market observers.

Two independent processes. One shared queue. The position struct is the message format. The treasury is the backpressure. The ring buffer is the bounded channel.

CSP all the way down.

## Architecture

### Two Panels

```
                    ┌─────────────────┐
                    │   Market Panel   │
                    │                  │
                    │  momentum        │
                    │  structure       │
                    │  volume          │
                    │  narrative       │
                    │  regime          │
                    │  generalist      │
                    │       ↓          │
                    │  market manager  │
                    └────────┬─────────┘
                             │
                     "enter here"
                             │
                             ▼
                    ┌─────────────────┐
                    │    Position      │
                    │   (the message)  │
                    │                  │
                    │  lives, breathes │
                    │  accumulates     │
                    └────────┬─────────┘
                             │
                     "this is how it ended"
                             │
                             ▼
                    ┌─────────────────┐
                    │   Exit Panel     │
                    │                  │
                    │  pnl observer    │
                    │  duration obs    │
                    │  excursion obs   │
                    │  volatility obs  │
                    │       ↓          │
                    │  exit manager    │
                    └────────┬─────────┘
                             │
                     resolution label
                             │
                             ▼
                     market panel learns
```

### Market Panel (exists today)

- **Vocabulary**: RSI, MACD, regime, harmonics, divergence, etc.
- **Labels**: Win / Loss (from exit panel resolution)
- **Question**: "Is this a good time to enter, and which direction?"
- **Grace**: the exit panel's confidence in the Win — how decisively favorable
- **Violence**: the exit panel's confidence in the Loss — how decisively adverse

### Exit Panel (new)

- **Vocabulary**: TBD — the open question
  - P&L trajectory (current return, rate of change)
  - Excursion state (MFE, MAE, MFE/MAE ratio)
  - Hold duration (candles since entry)
  - Volatility since entry (ATR change, regime shift)
  - Distance to stop / TP (in ATR units)
  - Market context at current candle (not at entry — the world changed)
- **Labels**: Hold / Exit
  - Hold: the position improved after this observation
  - Exit: the position deteriorated after this observation
- **Question**: "Should this position stay open or close now?"
- **Grace**: how much the position improved because we held (reward for patience)
- **Violence**: how much the position lost because we held when we should have exited

### The Co-Learning Loop

1. Market panel predicts direction → position opens
2. Exit panel observes position every candle → predicts Hold/Exit
3. When exit panel says Exit (or safety stop fires) → position closes
4. The resolution (how the position ended) flows back as the market panel's label
5. The market panel learns from the label → makes better entry predictions
6. Better entries → cleaner positions → better exit learning
7. Goto 1

The panels don't share journals. They don't see each other's thoughts. They communicate ONLY through the position lifecycle. This is the Grothendieck construction — they operate on fibers over a shared base (the position), coupled through the projection, independent in their own spaces.

### Positions as the Message Queue

- **Producer**: market panel (creates position)
- **Consumer**: exit panel (reads position state each candle)
- **Message format**: ManagedPosition struct
- **Acknowledgment**: position resolution (Win/Loss label sent back to market panel)
- **Backpressure**: treasury (won't fund more positions than available capital)
- **Bounded channel**: ring buffer on pending entries (safety valve, not a learning mechanism)
- **Protocol**: the position lifecycle (Active → Runner → Closed)

No horizon. No timeout. The exit panel decides when the position is done. The safety stop (k_stop × ATR) is the last resort — the exit panel should learn to exit before the stop fires.

## Open Questions

1. **Exit vocabulary**: What does an exit observer think in? The list above is a starting point, not a spec. Which facts are predictive of "should I hold or exit"?

2. **Exit observer specialization**: Should exit observers have lenses like market observers? One that thinks in P&L trajectory, another in volatility regime, another in excursion patterns? Or one generalist?

3. **Grace and violence for exit**: When the exit panel says "hold" and it was right, grace = position improvement. When it says "hold" and it was wrong, violence = position deterioration. But over what window? One candle? Until the next exit prediction? Until resolution?

4. **Label feedback timing**: The market panel learns when a position resolves. But positions may be open for hundreds of candles. The market panel doesn't learn in real time — it learns in position time. Is this too slow? Should there be intermediate feedback?

5. **Safety stop vs learned exit**: The safety stop (k_stop × ATR) exists today as a hard floor. When the exit panel learns, does it replace the safety stop? Tighten it? Or does the safety stop remain as an invariant that the exit panel operates above?

6. **Paper positions**: Today, every candle creates a pending entry for learning even without real capital. In the co-learning model, the exit panel needs real positions to observe. Do we create paper positions for exit learning? Or does the exit panel only learn from live trades?

## What Doesn't Change

- Six primitives (atom, bind, bundle, cosine, journal, curve)
- Two templates (prediction journal + reaction subspace)
- The noise subspace / residual pipeline per observer
- The enterprise tree structure
- The accumulation model
- Treasury, portfolio, ledger
- The thought encoding vocabulary for market observers

## What This Enables

If the exit panel learns to manage positions well:
- Stops tighten when the exit panel detects deterioration (not fixed ATR)
- TPs extend when the exit panel detects continued strength (not fixed ATR)
- The market panel receives high-quality labels (from learned exits, not parameters)
- Both panels improve each other through the lifecycle
- The system discovers its own stop/TP strategy rather than us hardcoding one

The fixed k_stop/k_tp/k_trail become safety floors, not the strategy. The exit panel learns the strategy. The parameters become guardrails.
