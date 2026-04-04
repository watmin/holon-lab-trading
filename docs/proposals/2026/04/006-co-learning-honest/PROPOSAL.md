# Proposal 006: Honest Labels via Dual-Sided Excursion

**Scope: userland** -- uses existing forms (observer, journal, online-subspace, pending, classify-excursion). No new language forms.

---

## 1. The current state

Each candle, the market observers encode thoughts through their vocabulary lens, strip noise via OnlineSubspace, and predict direction via Journal. The prediction is buffered as a Pending entry. Every candle while the entry is alive, the system tracks MFE (max favorable excursion) and MAE (max adverse excursion) in the predicted direction. At horizon drain (10x horizon candles), the entry resolves: MFE > |MAE| means Win, otherwise Loss. Weight = |MFE - |MAE||. The journal learns from these labels.

This replaced the old simulation labels (91/9 imbalance) and produces approximately 50/50 Win/Loss in a random walk. Deviations from 50/50 are real signal. The architecture works.

The exit observer exists in `market/exit.rs`. It encodes position state (P&L, MFE, MAE, hold duration, stop distance, ATR shift, phase, direction) and learns Hold/Exit. It is aspirational -- it learns but does not feed back into anything. Its vocabulary is position-centric: it sees a ManagedPosition and the current ATR.

Seven market observers (five specialists, two generalists) each with their own Journal, noise subspace, window sampler, and proof curve. One manager journal aggregates their opinions. The pipeline is proven and stable.

## 2. The problem

The market observers track MFE/MAE in ONE direction -- the direction the observer predicted (or the manager called). If the prediction was Buy, MFE tracks upward moves and MAE tracks downward moves. If the prediction was Sell, the opposite.

This creates a circular dependency: the label quality depends on the prediction quality. A bad prediction means MFE and MAE are measured in the wrong direction, producing a noisy label. The observer learns from the noise. The noise perpetuates.

The horizon (10x the window) is arbitrary. It is long enough to capture most excursions but it is still a parameter. The binary split (MFE > |MAE|?) is crude -- a candle where both sides experienced similar excursion gets a strong label in whichever direction happened to edge ahead.

The exit observer thinks about positions, not candles. It needs an open ManagedPosition to encode a thought. But the interesting question -- "was this candle a better entry for buying or selling?" -- does not require a position. It requires the same candle data the market observers already see. The exit observer and the market observer are asking different questions about the same input. The exit observer's current vocabulary (position state) forces it into a different data stream when it should be looking at the same one.

## 3. The proposed change

### Same candles, different question

The exit observer does not encode its own thoughts from candles. It RECEIVES the market observers' already-encoded thought vectors and judges them. "Given that the generalist thought THIS at candle N, was that a buy-grace or sell-grace thought?"

- Market observer asks: "which direction?"
- Exit observer asks: "given these market thoughts, which side was better?"

### Two vocabularies, composed

The market observers and the exit observer have overlapping but distinct vocabularies — a Venn diagram:

**Market vocabulary** (the market observers' circles): RSI, MACD, harmonics, regime, divergence, persistence, flow. Each specialist sees a subset. The generalist sees all. These facts describe what the market IS doing.

**Exit vocabulary** (the exit observer's circle): ATR regime, volatility state, market structure quality, spread conditions. These facts describe whether the environment is favorable for ANY entry, regardless of direction. Not "which way?" but "is now a good time?"

**Shared vocabulary** (the overlap): calendar (hour, day), regime indicators that appear in both. The nuance lives in the overlaps.

The exit observer receives the market thought (the generalist's encoded vector) and BINDS its own judgment facts to it. The result is a composed thought: market state + environment quality. The exit observer's noise subspace strips what's normal about this composition. The exit observer's journal predicts from the residual: buy-was-grace or sell-was-grace.

The market thought passes THROUGH the exit observer. It goes in as a vector. It comes back as a vector + label. The exit observer doesn't remake the thought. It judges it.

### Dual-sided excursion tracking

Every candle, the exit observer plays BOTH sides:

- **Buy-side hypothesis**: track MFE (upward moves) and MAE (downward moves) as if a buy was entered at this candle.
- **Sell-side hypothesis**: track MFE (downward moves) and MAE (upward moves) as if a sell was entered at this candle.

Both hypotheses live in the same ring buffer as the current Pending entries. Both track excursions every candle as prices evolve. No positions are opened. No capital is deployed. No treasury interaction. Just two counters per buffered candle, ticking with the market.

At resolution (when the entry drains from the buffer), both sides have their MFE and MAE. The label is determined by which side experienced more grace:

```
buy_grace  = buy_mfe - |buy_mae|
sell_grace = sell_mfe - |sell_mae|

if buy_grace > sell_grace:
    label = Buy,  weight = buy_grace - sell_grace
elif sell_grace > buy_grace:
    label = Sell,  weight = sell_grace - buy_grace
else:
    label = Buy,  weight = 0.01  // tiebreaker, minimal weight
```

The label is honest because BOTH sides were played. No prediction decided which direction to measure. The market decided. The weight is honest because it measures how decisively one side won over the other -- not how far it went, but how much better one side was than the other.

### What drains the buffer

The ring buffer has a fixed capacity (same as the current pending buffer). Entries drain when they reach the buffer's age limit. No horizon parameter -- the buffer size IS the horizon. The oldest entry is always the one that drains. This is the same mechanism as today, just named honestly: it is a ring buffer with a capacity, not a "horizon."

### The exit observer's label feeds the market observers

The exit observer resolves a candle as Buy or Sell with a weight. This is the market observers' Win/Loss signal:

- If the exit observer says "Buy" and the market observer predicted Buy: Win, weight from exit.
- If the exit observer says "Buy" and the market observer predicted Sell: Loss, weight from exit.
- If the exit observer says "Sell" and the market observer predicted Sell: Win, weight from exit.
- If the exit observer says "Sell" and the market observer predicted Buy: Loss, weight from exit.

The exit observer does not touch the market observers' journals directly. It produces a label (Buy or Sell) and a weight. The existing resolution code in `desk.rs` translates this into Win/Loss per observer based on what each observer predicted at that candle. The plumbing already exists -- `classify_excursion` returns an outcome and a weight, and `resolve` consumes it. The change is what produces the outcome: dual-sided excursion instead of single-sided.

### One exit observer, judgment vocabulary

Start with one exit observer. It receives the generalist's thought vector and binds its own judgment facts (ATR regime, volatility state, structure quality). It has its own Journal (labels: Buy/Sell, not Win/Loss), its own noise subspace, its own proof curve.

The exit observer's input is: `bundle(market_thought, bind(exit_atom, exit_fact) for each exit fact)`. The market thought is handed to it — not derived by it. The exit facts are its own. The composition is the judgment.

The exit observer must prove edge through its own curve before its labels replace the current MFE/MAE single-sided labels. Until the curve validates, the current single-sided labeling continues. This is the bootstrap: single-sided labels run until dual-sided labels prove they are better. No deadlock. No starvation. The market observers always have labels.

### What changes in the code

1. **New struct**: `DualExcursion` -- tracks buy-side and sell-side MFE/MAE for a candle. Four floats, updated every candle in the pending entry loop.

2. **Exit observer in Desk**: One Observer instance with Buy/Sell labels instead of Win/Loss. Receives the generalist's thought vector, binds its own judgment facts (exit vocabulary), composes the two via bundle. Predicts every candle. Resolves at drain.

3. **Resolution path**: When a pending entry drains, compute `buy_grace` and `sell_grace` from `DualExcursion`. If the exit observer's curve is valid, use the dual-sided label. If not, fall back to the current single-sided `classify_excursion`.

4. **No changes to**: Observer template, Journal, OnlineSubspace, manager encoding, position management, treasury, risk branches, accumulation model.

### What this replaces

The single-sided MFE/MAE labeling in `classify_excursion`. The exit observer in `market/exit.rs` that encodes position state. The aspirational trail modulation.

The exit observer's role shrinks and sharpens: it does not manage positions, it does not modulate trails, it does not need treasury state. It receives market thoughts. It binds its own judgment. It plays both sides. It tells the market observers which side was right. That is all it does.

## 4. The algebraic question

No new algebraic structures. The exit observer uses the existing observer template:

- **Bundle**: superposition of facts into thought vector (same `encode_thought`).
- **Bind**: role-filler binding (same atoms, same vocabulary).
- **Journal**: prediction + resolution. Labels are Buy/Sell instead of Win/Loss. The journal does not care -- labels are atoms.
- **OnlineSubspace**: noise stripping (same two-stage pipeline).
- **Cosine**: similarity scoring for predictions.
- **Curve**: proof gate for the exit observer. Must prove edge before its labels feed the market observers.

The dual-sided excursion tracking is arithmetic, not algebra. Four floats tracked per pending entry, updated with `max()` every candle. The label derivation is a comparison and a subtraction. No vector operations. No new primitives.

The label routing from exit observer to market observers is a function call that maps (exit label, observer prediction) to (Win/Loss, weight). This is the same kind of translation that `classify_excursion` already performs -- it maps excursion data to an outcome. The function signature changes but the pattern does not.

The coupling between exit observer and market observers is through the pending entry buffer, which already exists. The exit observer writes a label at drain time. The market observers read it at drain time. Same buffer, same drain event, same resolution code path. No new communication channel.

## 5. The simplicity question

**Is this simple or easy?** Simple. One new observer instance (same template). Four new floats per pending entry (buy MFE, buy MAE, sell MFE, sell MAE). One new comparison at drain time. One fallback path (curve not yet valid, use single-sided).

**What's being complected?** The risk is complecting the exit observer's learning with the market observers' learning -- making them depend on each other. This is avoided by the fallback: the market observers always have labels (single-sided until dual-sided proves itself). The exit observer learns independently. When it proves edge, its labels replace the approximation. The dependency is one-directional and gated by proof.

**Could existing forms solve it?** The dual-sided excursion tracking could be done without an observer -- just compute both sides and pick the winner. That would improve labels without any learning. The exit observer adds the ability to PREDICT which side will win before the excursion plays out. But the immediate value is in the honest labeling, not the prediction. The exit observer earns its prediction role over time, through the same proof curve every other observer uses.

**What 005 got wrong that this avoids:**
- 005 confused per-position and per-portfolio observation. This proposal observes candles, not positions.
- 005 used the CSP/position-as-channel metaphor. This drops it. The channel is the pending buffer, which already exists.
- 005 proposed trail modulation. This proposes labels only. The exit observer produces data (a label and weight), not a side effect.
- 005 proposed a full exit panel (six specialists). This starts with one observer.
- 005 had a bootstrap deadlock (market panel starved until exit panel proves edge). This has no deadlock -- single-sided labels run continuously, dual-sided labels phase in when proven.

## 6. Questions for designers

1. **Buffer size as implicit horizon.** The ring buffer capacity determines how long excursions are tracked. The current system uses `horizon * 10` (360 candles at horizon=36). Should the dual-sided buffer use the same capacity? Or should the exit observer have its own buffer with a different capacity, since it is asking a different question? The buffer size affects label quality: too short and excursions are truncated, too long and the labels are stale.

2. **Exit observer window sampling.** The market observers use `WindowSampler` to select their own observation windows (log-uniform between 12 and 2016 candles). The exit observer sees the same candle window as the generalist. Should it have its own `WindowSampler`, or should it always use the same window as the generalist? A separate sampler means it might discover a different time scale for the "which side was better?" question. The same sampler means it sees exactly the same data the generalist sees, making the label directly comparable.

3. **Transition from single-sided to dual-sided.** The proposal says: use single-sided until the exit observer's curve validates, then switch. Should the transition be a hard switch or a blend? A hard switch means labels change character overnight -- the journal has learned from single-sided labels, and now it sees dual-sided labels. A blend (weighted average of single-sided and dual-sided, weighted by exit curve accuracy) would be smoother but introduces a mixing parameter. Which is simpler?

4. **The exit observer predicts before the market observers resolve.** Every candle, the exit observer predicts Buy or Sell. This prediction is not used for labeling (the dual-sided excursion is). But it IS a prediction that can be evaluated: at drain time, was the exit observer's prediction the same as the dual-sided label? This gives the exit observer its own accuracy metric, separate from the market observers. The question: is this prediction useful for anything beyond validating the exit observer's curve? Should the exit observer's conviction weight the label it provides to the market observers, or should the label always come from the raw excursion arithmetic?

5. **Relationship to the existing exit observer.** The current exit observer in `market/exit.rs` encodes position state and learns Hold/Exit. This proposal replaces the exit observer concept entirely -- candle observation instead of position observation, Buy/Sell instead of Hold/Exit. The old exit atoms (position-pnl, position-hold, etc.) become unused. Should the old exit encoding be preserved for a future position management observer, or should it be removed? It is dead code under this proposal.

6. **Weight normalization.** The dual-sided weight is `|buy_grace - sell_grace|`. The single-sided weight is `|MFE - |MAE||`. These have different scales -- the dual-sided weight is the gap between two grace values, the single-sided weight is the absolute excursion imbalance. When the exit observer's curve validates and dual-sided labels phase in, should the weights be normalized to match the single-sided distribution? Or should the journal adapt naturally (it has seen thousands of single-sided weights, now it sees dual-sided weights with different magnitudes)?
