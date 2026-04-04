# Proposal 005: Co-Learning Panels — Positions as Message Queues

**Scope: userland** — uses existing forms (journal, observer, predict, resolve, online-subspace). No new language forms.

---

## 1. The current state

The enterprise has two observer pipelines, both using the same two templates (prediction journal + noise subspace):

**Market panel** (six observers: momentum, structure, volume, narrative, regime, generalist). Each observer encodes candle-derived thoughts through its lens, strips noise via OnlineSubspace, predicts direction via Journal. Labels are Win/Loss, determined by MFE vs MAE at horizon drain. The manager aggregates opinions and the desk opens positions when conviction is sufficient.

**Exit observer** (one, in `market/exit.rs`). Encodes position state every N candles (P&L, MFE, MAE, hold duration, stop distance, ATR shift, phase, direction). Learns Hold/Exit from whether the position improved or deteriorated over the next interval. Currently aspirational — it learns but does not yet modulate the trailing stop. The safety stop (k_stop x ATR) and take-profit (k_tp x ATR) are fixed parameters.

**Position lifecycle** follows the accumulation model: deploy source, swap to target, manage via trailing stop and take-profit, recover principal on TP (keeping residue as accumulation), close on stop or runner trail. Phases: Active, Runner, Closed.

The two halves exist. The templates are proven. The plumbing works.

## 2. The problem

The market observers cannot validate their own predictions. The label that says "you were right" comes from the position lifecycle — specifically from horizon drain, where MFE vs MAE is compared after a fixed number of candles. The quality of market observer learning depends entirely on the resolution mechanism, and the resolution mechanism learns nothing.

The exit observer accumulates knowledge about position management but nobody consults it. It can distinguish "this position is deteriorating" from "this position is improving" but the trailing stop ignores it. The stop/TP levels are fixed ATR multiples — parameters, not predictions.

Two learning systems, neither coupled to the other. The market panel produces entries that the exit observer could evaluate, but the exit observer's judgment never flows back as market panel labels. The exit observer sees positions that the market panel created, but has no channel to say "this entry was easy to manage" or "this entry was a disaster from candle one."

## 3. The proposed change

### Positions as the message queue

The position IS the communication channel between two independent panels. This is CSP: two processes, one bounded channel, messages passed through the position lifecycle.

```
Market Panel                    Exit Panel
(predict direction)             (predict hold/exit)
      │                               │
      │   "enter here, this           │
      │    direction, this             │
      │    conviction"                 │
      ▼                               │
┌──────────────┐                      │
│   Position   │◄─────────────────────┘
│  (the message)   reads state each candle
│              │
│  lives, accumulates state:
│  P&L, MFE, MAE, duration,
│  stop distance, ATR shift
└──────┬───────┘
       │
       │  "this is how it ended"
       │  (resolution label)
       ▼
Market Panel learns
```

**Producer**: market panel creates positions (via manager + treasury).
**Consumer**: exit panel reads position state each candle the position is open.
**Message format**: ManagedPosition struct — already defined in `position.wat`.
**Acknowledgment**: position resolution flows back as the market panel's Win/Loss label.
**Backpressure**: treasury (won't fund more positions than available capital).
**Bounded channel**: ring buffer on pending entries (safety valve).

### Two independent panels, same template

Both panels use the identical observer architecture from `observer.wat`: facts -> noise subspace -> residual -> journal -> predict. The configuration axes differ:

| Axis        | Market Panel                     | Exit Panel                                   |
|-------------|----------------------------------|----------------------------------------------|
| Vocabulary  | RSI, MACD, harmonics, regime ... | Treasury state: equity, deployed, drawdown, utilization, phase. Position state: P&L, MFE, MAE, hold duration, stop distance. Market context: ATR regime, volatility shift since entry. |
| Labels      | Win / Loss                       | Hold / Exit                                  |
| Question    | "Enter this direction?"          | "Should this position stay open?"            |
| Input       | Candle stream                    | Treasury + position snapshot stream          |
| Resolution  | From exit panel outcomes         | From portfolio improvement/decay             |

The exit observer's vocabulary IS the treasury's state at a point in time. The treasury doesn't know it's being observed — it just IS. The exit observer reads the snapshot the same way market observers read candle indicators. The encoding pipeline is identical: facts bound to atoms, bundled into a thought vector. Different inputs, same algebra.

The exit panel is not one observer — it is a panel of observers, each with a lens over a different aspect of the treasury + position state. Possible specializations: portfolio health (equity trajectory, drawdown, utilization), position dynamics (P&L, MFE/MAE ratio, hold duration), market context since entry (ATR change, regime shift). Same manager aggregation pattern as the market panel. The exit manager reads exit observer opinions, encoded as Holon vectors, and predicts the aggregate Hold/Exit.

### The dependency: exit learns first, market learns from exit

The market observers cannot learn anything honest until the exit observers are trained. This is not a limitation — it is the design.

The exit panel learns from the world directly: did the position improve or deteriorate after this candle? That's a question the market answers every candle. The exit panel doesn't need the market observers for this. It needs open positions and price movement. It learns Hold/Exit from raw outcomes.

The market panel has nothing honest to learn from until the exit panel has proven edge. Before that, any label the market panel receives is either arbitrary (horizon drain) or dishonest (rigged simulation parameters). The market panel is BLOCKED — not by code, but by epistemology. There is no honest label to give it.

Once the exit panel proves edge (its curve validates), its resolutions become the market panel's labels. The exit panel says "this position was a Win because I held through the dip and rode it to accumulation" or "this position was a Loss because it deteriorated from candle one and I couldn't save it." Those are honest labels. The market panel can learn from them.

### The co-learning loop

The positive feedback loop is not poisonous because each side learns from the WORLD, not from each other's predictions:

1. Exit panel learns Hold/Exit from position outcomes (the world).
2. Exit panel proves edge. Its resolutions become honest labels.
3. Market panel learns Win/Loss from exit panel resolutions (the world, filtered through learned management).
4. Market panel makes better entry predictions. Positions are cleaner.
5. Cleaner positions give the exit panel clearer signal. It learns better.
6. Better exit management produces higher-quality labels for the market panel.
7. Goto 4.

Neither panel learns from the other's OPINION. They learn from the other's OUTCOME. The world is the ground truth at every step. The exit panel doesn't ask the market panel "was this a good entry?" — it observes the position and sees for itself. The market panel doesn't ask the exit panel "should I have entered?" — it receives the resolution and learns from what happened.

The panels do not share journals. They do not see each other's thoughts. They communicate ONLY through the position lifecycle. Each operates on its own fiber — the market panel over candle-space, the exit panel over position-space — coupled through the shared base (the position struct).

### The MFE/MAE approximation — and why it must be replaced

The current MFE/MAE labels (proposal 004, revised) are better than the simulation labels they replaced — 50/50 instead of 91/9. But they are still magic numbers. The horizon (360 candles) is arbitrary. The binary split (MFE > |MAE|?) is crude. The weight (|MFE - |MAE||) is a heuristic. These are approximations of what a trained exit panel would provide honestly.

The MFE/MAE calculation IS the exit expert — just a dumb version of it. A fixed window, a fixed comparison, no learning. The exit panel replaces the approximation with a learned resolution. It doesn't ask "after 360 candles, was MFE > MAE?" It asks "right now, should this position stay open?" — and it learns the answer from every position it has ever watched.

The MFE/MAE labels are the bootstrap. They prove the architecture works with honest labels. The exit panel is the convergence — when the approximation is replaced by the thing it was approximating.

### What the exit panel replaces

Today the trailing stop is `k_trail x ATR` from the extreme rate. The exit panel's prediction modulates this:

- Exit with high conviction: tighten the trail (the position is deteriorating).
- Hold with high conviction: loosen the trail (the position is improving).
- Low conviction: trail unchanged (safety parameters hold).

The safety stop (`k_stop x ATR`) remains as an invariant floor. The exit panel operates above it — it can only tighten or loosen the trail, never remove the stop. The stop is the guardrail, not the strategy. The exit panel learns the strategy.

### What the exit panel changes about market labels

Today, market observers learn from horizon drain: MFE vs MAE after N candles. In the co-learning model, market observers learn from position resolution — how the exit panel managed the trade. A position that the exit panel held through a dip and rode to accumulation is a Win with high weight. A position that the exit panel exited early because it detected immediate deterioration is a Loss with high weight. The exit panel's management quality becomes the market panel's label quality.

Grace and violence carry across the channel:
- **Grace** (market panel): how much residue was accumulated — the exit panel held well.
- **Violence** (market panel): how much was lost — the exit panel couldn't save it.
- **Grace** (exit panel): how much the position improved after a Hold prediction.
- **Violence** (exit panel): how much the position lost after a Hold prediction (should have exited).

## 4. The algebraic question

No new algebraic structures. Both panels use the existing monoid:

- **Bundle**: superposition of observer opinions (market manager, exit manager).
- **Bind**: role-filler binding (exit facts bound to position atoms, same as market facts bound to indicator atoms).
- **Journal**: prediction + resolution for both panels. Win/Loss journal for market. Hold/Exit journal for exit.
- **OnlineSubspace**: noise stripping for both panels. Position-space noise model for exit, candle-space noise model for market.
- **Cosine**: similarity scoring for predictions in both panels.
- **Curve**: proof gate for both panels. An exit observer must prove predictive edge before its opinion modulates the trail.

The coupling between panels is not algebraic — it is architectural. The position struct is data, not a vector operation. The label flow is a function call, not a new primitive. The co-learning emerges from how we wire the existing forms, not from extending them.

The accumulation model (`accumulation.wat`) is unchanged. Principal recovery, residue, runner phase — all the same. The exit panel decides WHEN to trigger these transitions, but the transitions themselves are the same operations.

## 5. The simplicity question

**Is this simple or easy?** Simple. Two instances of the same template (observer panel), connected by a data structure that already exists (ManagedPosition). No new types. No new primitives. No new encoding tricks.

**What's being complected?** The risk is complecting position management with prediction. The exit panel predicts Hold/Exit but the ACTION is trail modulation. These must stay separate: the prediction is a vector operation, the trail modulation is arithmetic on the position struct. The exit panel offers an opinion. The desk acts on it (or doesn't). Same boundary as market observers: they perceive, they don't decide.

**Could existing forms solve it?** They DO solve it. That is the point. The observer template (`observer.wat`) already supports arbitrary vocabulary and labels. The exit observer encoding (`exit.wat`) already exists. The manager aggregation pattern already works. The proposal is: wire the second instance of what we already have, and connect the two through the position lifecycle.

The only new code is: (a) exit manager aggregation (same pattern as market manager), (b) trail modulation from exit conviction (arithmetic), (c) label routing from position resolution back to market panel (a function call).

## 6. Questions for designers

1. **Exit observer specialization**: Should the exit panel have multiple specialized observers (P&L lens, excursion lens, volatility lens, duration lens) like the market panel? Or start with one generalist exit observer and specialize later when we see what it learns?

2. **Exit observation frequency**: The market panel observes every candle. Should the exit panel also observe every candle, or at a different cadence? Position state changes slowly (one candle of P&L movement) — is every-candle observation too noisy for the exit journal?

3. **Label feedback timing**: Positions may be open for hundreds of candles. The market panel only learns when a position resolves. Is this too slow? Should there be intermediate feedback (e.g., partial resolution at principal recovery, final resolution at close)?

4. **Exit learning without positions**: The exit panel does not need open positions to learn. It needs a snapshot of the portfolio state at the moment a thought was encoded — equity, deployment, drawdown, ATR, phase. That snapshot IS the exit thought. Resolution: did the portfolio state improve or deteriorate N candles later? Same pattern as market observers: encode state, predict, resolve against what actually happened. No paper positions. No simulated lifecycle. Just snapshots and outcomes.

5. **Trail modulation bounds**: When the exit panel says "tighten" or "loosen," how much? Should conviction magnitude map linearly to trail adjustment? Should there be a maximum tightening/loosening factor? Or should the exit panel learn the modulation magnitude as part of its own curve?

6. **Transition from horizon drain**: Today the market panel learns from horizon drain (fixed N candle lookback). In the co-learning model, it learns from position resolution. During warmup (before the exit panel has proven edge), should the market panel continue using horizon drain? When does the switchover happen — when the exit panel's curve validates?
