# Review: Rich Hickey

Verdict: CONDITIONAL

---

## What is good here

The instinct is right. Two independent processes communicating through an immutable value (the position lifecycle) is genuinely simple. The position is data. It flows one direction. Neither process mutates the other's state. This is CSP done honestly, and the proposal knows it.

The epistemological argument in section 3 is the strongest part of the document. You cannot learn honest labels from dishonest sources. The MFE/MAE horizon is an approximation of a thing that should exist but doesn't yet. Building the thing it approximates and then removing the approximation -- that is the right sequence. Most systems never remove their scaffolding. This proposal names the scaffolding and commits to removing it.

The algebraic claim in section 4 is true. No new primitives. No new types. The observer template is genuinely domain-agnostic -- the wat spec already says so, with a table showing Market/Risk/Exit as configuration axes. The proposal instantiates what already exists.

## Where complecting hides

### 1. "Two instances of the same template" is not quite true

The proposal says the two panels are the same template with different configuration. But read the details carefully.

The market panel encodes thoughts from candle data. One candle arrives, all observers encode, the noise subspace updates, the journal predicts. The rhythm is the candle stream. One input, many lenses.

The exit panel encodes thoughts from position state. But positions are not candles. A candle arrives whether you want it or not. A position exists because the market panel created it. The exit panel's input stream is *produced by the other panel's output*. That is not configuration. That is a structural dependency.

Furthermore: how many positions are open? Zero, one, five? The market panel always has exactly one candle to think about per tick. The exit panel has a variable number of positions. This means the exit panel needs a decision the market panel never faces: which position am I thinking about right now? Or am I thinking about all of them at once? The proposal gestures at "treasury + position snapshot stream" but does not specify whether the exit panel thinks per-position or per-portfolio. These are different things. Per-position is genuinely the same template. Per-portfolio is a different animal -- it is aggregation, not observation.

Section 6.1 says "the exit panel is a panel of observers, each with a lens over a different aspect of the treasury + position state." That mixes two levels. Treasury state (equity, drawdown, utilization) is portfolio-level. Position state (P&L, MFE, hold duration) is per-position. An observer that sees portfolio state is not the same template as an observer that sees a single position. One of them requires knowing how many positions exist and combining their states. The other sees one thing at a time.

**This must be resolved before implementation.** Name the unit of observation. If it is per-position, say so and accept that the exit panel fires N times per tick where N is the number of open positions. If it is per-portfolio, acknowledge that the template is being stretched -- the "thought" is now an aggregate, not a direct observation.

### 2. The co-learning loop is value-driven but the bootstrap is not specified

The loop described in section 3 is clean: exit learns from the world, market learns from exit's outcomes, better entries give exit cleaner signal. Each step grounds in observation, not opinion. Good.

But the transition is underspecified. Today: market panel learns from horizon drain. Tomorrow: market panel learns from exit resolutions. When does the switch happen? Section 6.6 says "the horizon drain is removed" and "the market panel is starved until the exit panel can feed it." But:

- How does the exit panel prove edge without the market panel producing good entries?
- If the market panel is starved (no labels), its noise subspace still learns, but its journal accumulates no resolved predictions. The curve never validates. The observers remain unproven.
- Meanwhile, positions still open (from what? the unproven market panel?), the exit panel observes them, and eventually resolves them. But these positions were entered by an untrained market panel.

The proposal says "this is not a limitation, it is the design." I disagree. It is a bootstrap problem that has been named but not solved. The MFE/MAE labels are called "the bootstrap" but the proposal removes them without describing the replacement bootstrap. You need initial positions to train the exit panel. Those positions come from the market panel. The market panel needs labels. If you remove the only label source before the replacement is ready, you have a deadlock, not a design.

**Specify the bootstrap sequence explicitly.** Which comes first? How do you break the cycle? The honest answer might be: keep horizon drain running in parallel until the exit panel's curve validates, then fade it out. That is a transition, not a removal.

### 3. Trail modulation is a place, not a value

Section 3 says the exit panel's prediction "modulates" the trailing stop: tighten on Exit conviction, loosen on Hold conviction. But modulation is mutation. The trailing stop in `position.wat` is a field on a mutable struct (`set! (:trailing-stop pos) stop`). The exit panel's opinion flows into a side effect on a place.

This is not fatal -- the market observers' predictions also flow into a side effect (opening a position). But the proposal should be honest about it. The exit panel does not produce a value that is consumed downstream. It produces an opinion that mutates a field on a struct that is being ticked every candle. The trail modulation and the normal trailing logic in `tick` both write to the same place. Who wins? What is the reconciliation?

`tick` in `position.wat` already ratchets the trailing stop upward: `(max (:trailing-stop pos) new-stop)`. If the exit panel loosens the trail (sets it lower), the next `tick` will ratchet it back up. If the exit panel tightens the trail (sets it higher), `tick` will preserve it. This means loosening does not work with the current `tick` logic. The proposal either needs to change `tick` or acknowledge that "loosen" is inert.

**This is the kind of thing that should be a value.** The exit panel should produce a trail-factor (a scalar), and `tick` should consume it. The opinion is a value. The application of the opinion to the position is a separate step. Do not let the exit panel reach into the position and mutate its stop. Let it produce data. Let the desk apply it.

### 4. "Exit learning without positions" contradicts the channel metaphor

Section 6.4 says the exit panel "does not need open positions to learn" -- it can learn from treasury snapshots alone, resolving against whether the portfolio improved N candles later. But section 3 calls the position "the message queue" and "the communication channel." If the exit panel can learn without positions, then positions are not the channel. The channel is the treasury state stream, and positions are one thing the exit panel happens to observe.

This is not wrong, but it is two different designs presented as one. Pick one:

- **Positions are the channel.** The exit panel thinks about positions. It produces Hold/Exit per position. It needs open positions to function.
- **Treasury state is the input.** The exit panel thinks about portfolio health. It produces a portfolio-level opinion. Positions are data it reads, not messages it receives.

Both are valid. They are not the same. The CSP metaphor is honest for the first. It is a metaphor stretched past usefulness for the second.

### 5. The word "panel" is doing too much work

The market panel is six observers plus a manager. The exit panel is described as "a panel of observers" but also as "one observer in `market/exit.rs`" that already exists. The proposal promotes the single exit observer to a full panel by analogy with the market panel, but the analogy is not justified by evidence.

The market panel has six specialists because the vocabulary is large enough to warrant specialization. Sixty-plus facts across oscillators, flow, persistence, regime, divergence, and more. The lenses (momentum, structure, volume, narrative, regime) carve natural joints.

The exit vocabulary has nine facts (from `exit.wat`): pnl, hold duration, mfe, mae, atr-entry, atr-now, stop-distance, phase, direction. Nine facts do not need six specialists. The proposal suggests lenses (portfolio health, position dynamics, market context, risk state) but these overlap heavily -- ATR shift appears in both "market context" and "risk state," P&L appears in both "position dynamics" and "portfolio health."

Do not create structure in anticipation of complexity. Start with one exit observer. If its accuracy plateaus because the vocabulary is too broad, specialize. The market panel earned its six observers through demonstrated need. The exit panel should earn its structure the same way.

## Summary of conditions

1. **Name the unit of observation.** Per-position or per-portfolio. Do not mix them in the same observer.

2. **Specify the bootstrap.** How does the exit panel get training positions if the market panel has no labels? Describe the transition from horizon drain to exit-panel labels as a sequence, not a switch.

3. **Trail modulation as a value, not a place.** The exit panel produces a trail-factor scalar. `tick` consumes it. The panel never touches `trailing-stop` directly.

4. **Resolve the channel metaphor.** If positions are the channel, the exit panel needs positions. If treasury state is the input, drop the CSP framing and call it what it is: a second observer panel over a different data stream.

5. **Start with one exit observer.** Earn the panel structure through demonstrated need, not analogy.

None of these are architectural objections. The core idea -- two learning systems coupled through an immutable data lifecycle, each grounded in world observation -- is sound. The conditions are about making the design as simple as the prose claims it is.
