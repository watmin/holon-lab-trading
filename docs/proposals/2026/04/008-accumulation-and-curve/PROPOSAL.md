# Proposal 008: Accumulation and Curve Learning

## The confusion

The designers said "coordinate for later" on two features:
1. The runner phase (principal recovery → residue rides on house money)
2. Curve learning (the meta-journal — the system thinks about how well it thinks)

The builder is confused. These feel like they should be designable from
first principles. The accumulation model is the architecture's tolerance
mechanism — without it, the system needs high accuracy to survive. With
it, the system only needs the wins to leave something behind. The curve
learning is the self-awareness mechanism — without it, the system measures
but doesn't think about its own measurements.

Are these truly "observe first, design later"? Or are they designable NOW
from the architecture we already have?

## Question 1: The runner phase

The current Trade lifecycle: Active → Settled.

The proposed lifecycle:
```
Active → take-profit fires → PrincipalRecovered
  principal returns to available
  residue continues as Runner with wider stop
Runner → runner's stop fires → RunnerSettled
  residue returns to available (permanent gain)
```

The designers said: "You cannot design the runner well until you know what
residue actually looks like in practice." But:

- The trailing stop mechanism already exists (Levels on Trade)
- The principal amount is known at funding time
- The take-profit level is known at funding time
- The "wider stop" for the runner is itself a distance — learnable by the
  same cascade (reckoner → accumulator → crutch)

**Can the runner phase be specified as a state transition on the Trade
struct?** The mechanism is the same — a trailing stop at a different
distance. The only new thing is: the Trade has states, and the treasury
handles settlement differently depending on the state.

Is this really something we need data to design? Or is it a state machine
we can draw right now?

## Question 2: Curve learning

The current curve: records (conviction, correct?) pairs. Reports (amplitude,
exponent). That's measurement.

The proposed meta-journal: the curve's (amplitude, exponent) ARE observations.
Feed them to a reckoner. The reckoner learns: "when amplitude was high
AND exponent was steep, the next N predictions were accurate." The curve's
shape predicts future performance.

The designers said: "Feeding the curve's output back into encoding creates
a circular dependency whose convergence is unknown." But:

- The reckoner already handles circular feedback (observations shape the
  discriminant which shapes predictions which become observations)
- The meta-journal doesn't feed into the SAME reckoner — it's a separate
  reckoner at a higher level
- The book describes exactly this recursion: "Layer N is an engram library
  of layer N-1 states"

**Can the meta-journal be specified as a reckoner that observes curve
parameters?** The mechanism is the same — observe, predict, resolve.
The only new thing is: the input is curve state, not candle state.

Is the circular dependency real? Or is it the same feedback loop the
enterprise already uses, applied one level up?

## What the datamancer needs

For each question:
1. Can it be designed from first principles NOW?
2. If yes, what's the minimal specification?
3. If no, what specific observation is needed first?
