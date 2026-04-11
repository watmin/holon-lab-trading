# Proposal 020 — Dual Observation

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposals 017-019

## The insight

A paper plays both sides. One wins. One loses. That's two signals
from one event. Today we propagate only the winner. Half the
learning is discarded.

## The generic loop

The reckoner has N labels and N prototypes. A paper resolves — one
label won, one lost. The same thought. Opposite signals.

```
paper resolves → winner label, loser label

observe(thought, winner, +weight)   // pull toward the winner
observe(thought, loser,  -weight)   // push away from the loser
```

Direction agnostic. The labels could be Up/Down, Grace/Violence,
any binary discrimination. The loop is generic. One won. One lost.
Both prototypes learn from the same event.

The discriminant is the difference between prototypes. When one
prototype pulls and the other pushes on the same vector, the
discriminant moves TWICE as far per observation. Not two
observations — one observation that teaches both sides.

## Why this matters

Today: one paper resolution → `observe(thought, Up, weight)`.
The Up prototype absorbs the thought. The Down prototype is
untouched. The discriminant moves by `weight` in one direction.

After: one paper resolution → `observe(thought, Up, +weight)` AND
`observe(thought, Down, -weight)`. The Up prototype pulls in. The
Down prototype pushes out. The discriminant moves by `2 * weight`.

At 95,000 paper resolutions per 2000 candles, this doubles the
effective training signal without generating a single additional
paper. The disc_strength should respond.

## The negative observation

The reckoner's `observe(thought, label, weight)` already supports
any weight — positive or negative. Positive weight bundles the
thought INTO the prototype. Negative weight pushes it AWAY. The
accumulator handles both. The algebra is already there.

The negative observation says: "this thought is NOT label=Down."
The Down prototype accumulates the negation — it learns what Down
does NOT look like. The discriminant sharpens because both
prototypes are informed by every resolution.

## Applied to each learner

**Market observer (Up/Down):**
- Buy side wins → observe(thought, Up, +residue), observe(thought, Down, -residue)
- Sell side wins → observe(thought, Down, +residue), observe(thought, Up, -residue)

**Broker (Grace/Violence):**
- Grace → observe(composed, Grace, +residue), observe(composed, Violence, -residue)
- Violence → observe(composed, Violence, +amount), observe(composed, Grace, -amount)

**Exit observer:** Not applicable — continuous reckoners, not binary.
The exit observer learns optimal scalar distances, not labels.

## The noise subspace question

Proposal 019 identified the noise subspace as stripping signal.
This proposal doubles the signal strength per observation.
If the doubled signal overcomes the stripping, the noise subspace
may be tolerable. If disc_strength still declines after dual
observation, the subspace is definitively the problem.

This lets us test one variable at a time:
1. First: implement dual observation. Run 30k. Measure disc_strength.
2. If disc_strength climbs: the signal was weak, not stripped. Keep subspace.
3. If disc_strength still declines: the subspace strips faster than
   doubled signal can accumulate. Remove it.

## Questions

1. Does negative weight in the accumulator do what we think? The
   accumulator does `sums += thought * weight`. Negative weight
   subtracts the thought from the prototype. Is that "pushing away"
   or is it something else algebraically?

2. Should the negative weight equal the positive weight? Or should
   the loser get less punishment than the winner gets reward?
   Asymmetric weights could prevent the prototypes from canceling
   if the signal is noisy.

3. Can the reckoner's existing `observe` handle negative weight
   without breaking? Does the accumulator count, the discriminant
   computation, the curve fitting — do any of them assume positive
   weight?

4. Is this the same insight as MFE vs MAE from the book? "Favorable
   first vs adverse first" was the honest label. Dual observation
   says: favorable first teaches BOTH "this is favorable" AND "this
   is NOT adverse." Same event, both signals.
