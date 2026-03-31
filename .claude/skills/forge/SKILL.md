---
name: forge
description: Test the craft of the function. The datamancer holds the code to the fire — Hickey's heat removes impurity, Beckman's hammer tests composition. What survives the forge is well-made.
argument-hint: [file-path]
---

# Forge

> A forged blade is shaped by repeated heating and hammering. Each strike removes impurity. Each fold strengthens the metal.

The other wards ask: is it tangled? Is it alive? Is it true? Is it beautiful? The forge asks: **is it well-made?**

Two lenses in one fire. Rich Hickey removes what doesn't belong. Brian Beckman tests whether what remains holds together. The forge is both acts at once.

## What the forge tests

### Values, not places (Hickey)

Data should flow through functions, not mutate in place. A function that takes data and returns data is forged. A function that reaches into shared state, mutates it, and returns nothing is cast.

- Does this function take its inputs as parameters and return its outputs?
- Or does it reach into `self` for things that should be arguments?
- Are the mutations honest? `&mut self` should mutate self, not the world.
- Is there hidden coupling? Two functions that share mutable state without the type system knowing are welded, not forged.

### Types that enforce (Beckman)

The type signature should be the contract. If you can call the function wrong, the forge failed.

- Does the function take `f64` where it should take a newtype? (`DrawdownDepth(f64)` vs bare `f64`)
- Does it take `&str` where it should take an enum? Direction as a string is a lie. Direction as `Direction::Long` is a truth.
- Does the return type tell you what happened? `Option<T>` says "might fail." `Result<T, E>` says "might fail, and here's why." `T` says "always succeeds" — is that actually true?
- Can you call this function with nonsensical arguments and get a silent wrong answer? That's an unforged edge.

### Abstractions at the right level (both)

Not too many. Not too few. The right abstraction is one that earns its existence.

- A helper function called once is premature. Inline it.
- A pattern repeated three times is a function waiting to be born. Extract it.
- A trait with one implementor is a promise about a future that may not come. Remove it.
- A generic over a type used only as `f64` is false generality. Specialize it.

Hickey: "Every new thing you add has a cost. Is this worth it?"
Beckman: "Does this abstraction close? Can I compose through it?"

### Composition (Beckman)

Functions compose when the output of one is the input of the next. The forge checks the joints.

- Can this function be tested in isolation? If it needs the full enterprise state to test, it's welded to the frame.
- Does the function signature tell you its world? If it takes `&CandleContext` (30 fields) but reads 2, it's claiming a bigger world than it needs.
- Are there algebraic escapes? A "pure" function that writes to a log, a "stateless" computation that reads a global — the forge finds where the algebra leaks.
- Do the stages compose? `transducer → functor → fold` should be `A → B → C` with clean boundaries. If stage 2 reaches back into stage 1's state, the composition is broken.

### The function that survives the forge

It takes data in. It returns data out. The types say what it does. The name says why. It composes with its neighbors without knowing them. It can be tested alone. It does one thing. It does it completely.

A forged function is one you can hold up to both lenses simultaneously — Hickey nods "nothing unnecessary" and Beckman nods "it composes" — and neither flinches.

## How to scan

Read the target file (default: `src/state.rs`). For each function, each method, each closure:

1. **Values or places?** Does data flow through, or does the function reach into the world?
2. **Types enforce?** Can you call it wrong? Can you call it with nonsense?
3. **Right abstraction?** Is this function earning its existence? Too much? Too little?
4. **Composes?** Can it be tested alone? Does its signature tell its world?
5. **Survives?** Would both Hickey and Beckman nod?

Report findings as: the function, what the forge reveals, and what a well-forged version would look like. Not a rewrite — a direction.

## What forge is NOT

- Not sever. Sever checks macro structure (braided concerns across blocks). Forge checks micro structure (the craft of individual functions).
- Not gaze. Gaze checks communication (does it read well?). Forge checks composition (does it hold together?).
- Not a type system redesign. The forge works with the types you have. It asks: are you using them honestly?

## Runes

Skip findings annotated with `rune:forge(category)` in a comment at the site. The annotation must include a reason after the dash. Report the rune so the human knows it exists, but don't flag it as a finding.

Runes suppress bad thoughts without denying their presence. A rune tells the ward: the datamancer has been here. This is conscious.

```rust
// rune:forge(escape) — the fold's IO was extracted; this coupling is measured
```

Categories: `escape` (algebraic leak is known and measured), `coupling` (hidden dependency is intentional), `bare-type` (using f64/str instead of newtype is acceptable here), `premature` (single-use helper earns its place for clarity).

## The principle

Hickey said: simplicity is a prerequisite for reliability. Beckman said: composability is a prerequisite for understanding. The forge tests both. A well-forged function is simple AND composable. It survives the fire of "what if I use this in a context the author didn't imagine?" Because a forged function doesn't know its context. It knows its inputs and its outputs. Everything else is someone else's concern.

The datamancer forges. The function survives or it doesn't. The forge is the crucible where Rich's heat and Brian's hammer meet.
