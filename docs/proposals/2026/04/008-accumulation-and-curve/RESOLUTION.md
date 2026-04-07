# Resolution — Proposal 008

## Runner phase: ACCEPTED

Both designers accepted. The runner is a state machine, specifiable
from first principles. Parameters are learned. Mechanism is architecture.

TradePhase enum: Active → PrincipalRecovered → Runner → Settled.
Distances gains runner-trail (fourth learnable scalar).
Applied to the guide.

## Curve learning: RESOLVED differently than proposed

The meta-journal dissolved. It was never a separate entity.

### The discovery

The curve produces a scalar: `edge-at(conviction) → f64`. The edge is
the accuracy at this conviction level. Range: [0.0, 1.0]. No floor at
0.5 — accuracy below 0.5 is anti-correlation (the flip signal).

The consumer doesn't need the curve object, the snapshot, or the
parameters. The consumer needs ONE SCALAR — the edge — as a fact in
its bundle. The consumer's reckoner learns whether that scalar predicts
Grace. The same mechanism that handles RSI handles the producer's edge.

### The protocol

Every learned message carries three things:

```
(thought: Vector, prediction: Prediction, edge: f64)
```

- **thought** — what you know. The encoded facts.
- **prediction** — what you think will happen.
- **edge** — how accurate you are when you predict this strongly.
  [0.0, 1.0]. The coupling of knowledge and judgment, measured by the curve.

The consumer encodes the edge as a scalar fact:
```scheme
(Linear "producer-edge" edge 1.0)
```

The consumer bundles it with market facts. The reckoner learns:
- edge 0.65 + momentum → Grace (trust this observer)
- edge 0.38 + momentum → Grace on OPPOSITE direction (the flip — discovered organically)
- edge 0.50 → noise (ignore this observer)

No new primitives. No new entities. No CurveSnapshot struct. No curve
vocabulary module. One f64 attached to the message. The tools compose.

### What the consumer discovers without looking

- **Right-leaning curve** — high conviction → high accuracy. The reckoner
  learns "high edge = trust."
- **Bell curve** — middle conviction is best. The reckoner learns "edge
  around 0.57 = trust, edge at 0.70 = overfit."
- **Anti-correlation** — consistently below 0.5. The reckoner learns
  "this producer is a contrarian indicator."
- **The flip** — emerges from the data. No hardcoded logic. The
  measurement IS the flip.

### The designers' conditions — met or dissolved

Hickey's condition: "demonstrate that curve parameters are stable enough
to be values." → Dissolved. The consumer doesn't observe curve parameters.
The consumer observes one scalar that is always a value — the edge at
this conviction right now.

Beckman's condition: "prove the Jacobian's spectral radius < 1." →
Dissolved. There is no feedback loop to characterize. The edge is a
read-only observation. The consumer's reckoner does not feed back into
the producer's curve. The consumer learns FROM the edge but does not
CHANGE the edge.

## Questions for designers

**Q1: Is the protocol (thought, prediction, edge) the right channel signature?**
Every learned message carries all three. The consumer is free to use
any subset.

**Q2: Is edge ∈ [0.0, 1.0] correct?** No floor at 0.5 — anti-correlation
is information. Or should the edge be (accuracy - base) ∈ [-0.5, 0.5]
to center at zero?

**Q3: Does this resolve the curve learning placeholder in the guide?**
The meta-journal is dissolved. The consumer's existing reckoner learns
from the edge scalar. No new machinery needed.
