# Causal relations between streams — the missing primitive

## The concern

We've been saying "the rhythm IS the thought, not the snapshot." That's truer
than the pixel grid was. But rhythms are still per-stream. A rhythm encodes
"RSI went 72, 71, 73, 74" as a bundled bigram of trigrams. That's motion in
one stream.

A TRADER thinks in relations between streams:

- "RSI is **diverging** from price"
- "Volume **spikes** while the range **narrows**"
- "MACD crosses **after** price fails at resistance"
- "Bollinger squeeze **then** breakout"

The thought is not a snapshot of two streams. It's a RELATION between them,
typed — diverging, spiking-while, crosses-after, then-breakout. Named. Generic.
Repeatable.

What we have today encodes each stream's motion. What we don't have is the
relational composition. The discriminant can only find direction in what the
encoding can express. If we never express "diverge," we never learn whether
divergence predicts.

## What we're afraid of

We may have replicated the viewport in higher dimensions. Pixels → bundled
rhythms. More bits, same category: perception, not cognition.

The test: could the current encoding express "RSI diverging from price"?
Answer: only by accident — both rhythms land in the bundle, the discriminant
has to infer that one is going up while the other is going down from the
two rhythm vectors side by side. No atom names the divergence. No bind
composes the two streams into a relation.

## The shape of the missing primitive

Two kinds of relations across streams:

### 1. Concurrent (at this point in time)

`while(A, B)` — two streams in a relation at the current moment.
- `while(rsi-rising, price-falling)` — divergence
- `while(bb-squeeze, volume-low)` — compression
- `while(hour(3pm), dow(friday))` — time composition (we already do this)

The algebra: `Bind(A_state, B_state)` where A_state and B_state are atoms
or bound scalars. We already have this. The missing piece is that the
A_state and B_state need to be NAMED characterizations, not raw values.
"rsi-rising" is an atom. "price-falling" is an atom. The bind expresses
the co-occurrence.

### 2. Causal (across time)

`then(A, B)` — A happened, then B happened. Temporal composition.
- `then(bb-squeeze, breakout)` — squeeze precedes breakout
- `then(price-fails-resistance, macd-cross-down)` — causal chain
- `then(divergence, reversal)` — the reversal thesis itself

The algebra: `Bind(A_past, Permute(B_now, 1))` — the permutation indicates
position in time. Or a new primitive that lets the encoder express "B is
what followed A." Either way: we need an atom for `then` or we use permute
to mark "later."

## Why generic names matter

If we name every relation by its instantiation — `rsi-diverging-from-price`
as a single atom — we can't learn categories. The algebra gets a bag of
specific atoms, no composition.

Generic verbs: `diverging`, `converging`, `preceding`, `echoing`, `squeeze`,
`breakout`, `cross`, `fail`. The atoms name relations, not instantiations.
The binds compose the atoms with the specific streams.

`bind(diverging, bind(rsi, price))` = "RSI diverging from price"
`bind(diverging, bind(macd, price))` = "MACD diverging from price"

The discriminant learns what `diverging` means once. The specific instantiation
rides on the generic relation.

## What streams need in order to participate

For a stream to participate in causal relations, it needs named states over
time, not just values. Right now our rhythm encodes: "the number 72 became 73
became 74." A relation-aware encoding would need: "rising, rising, stable."
Categorical state labels that other streams can bind to.

That's a labeling layer between indicator → thought. Each indicator gets a
small vocabulary of state atoms (rising, falling, stable, extreme, crossing,
diverging, converging, squeeze, expansion). A stream emits its current state
atom each candle. Other streams can bind to those.

Not all at once. Start narrow. Rising/falling for all indicators. Then
crossing/diverging for pairs. Then the full vocabulary.

## The relation atoms (draft — expand in practice)

**One-stream states** (any indicator can emit):
- `rising`, `falling`, `stable`
- `extreme-high`, `extreme-low`
- `accelerating`, `decelerating`
- `squeeze`, `expansion` (for band-like indicators)

**Two-stream relations**:
- `diverging`, `converging` — direction disagreement/agreement
- `leading`, `lagging` — one moves before the other
- `crossing-up`, `crossing-down` — MA crossovers, signal crosses

**Temporal composition** (across candles):
- `then(A, B)` — A preceded B
- `echo(A, B)` — B is A's mirror later

## First experiment to run

Pick ONE relation: `diverging`. Pick TWO streams: RSI and close-price. Encode
`bind(diverging, bind(rsi, price))` when the two streams move in opposite
directions for N candles. Add it to the market observer's thought alongside
the existing rhythms.

If the discriminant learns a direction signal from this compound atom, the
primitive works. If not, we know it's either a bad relation or the subspace
is still eating it.

Start with one. Prove the primitive.

## What this doesn't replace

The rhythm encoding of each stream's motion is still useful. The relations
are additive — named compositions over the rhythms, not a substitute for them.
The discriminant sees: rhythms + relations + time. It learns what combinations
predict.

## Open questions

- Who computes the states? A new layer between indicator and rhythm? An
  existing vocab module? Do we compute state on the scalar (e.g. RSI value
  vs its moving average) or on the rhythm itself (the trigram shape)?
- How does a stream emit "crossing-up" — a pair of indicators need to agree
  they crossed. Is that the rhythm builder's job or a separate concept module?
- Temporal relations need a window. "then" over how many candles? Is that
  a spec per relation?
- Does `then` share with the existing `Permute` primitive or become its own?

## What we're parking here, not doing yet

This whole file is a sketch. The perf work unblocks experimentation. Before
we implement relation atoms, we probably want to:
1. Kill the critical `l1_hits` bug and the dead code from ward backlog 2
2. Run a clean 10k with the current thoughts to measure where we are
3. Reset the noise subspaces and reckoners between code changes
4. THEN introduce one relation atom and measure

The order matters because we don't know if the flat accuracy is because
relations are missing or because some other thing is broken.
