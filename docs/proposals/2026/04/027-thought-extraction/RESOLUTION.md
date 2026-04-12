# Resolution: Proposal 027 — Thought Extraction

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both accepted unanimously.

**Hickey:** Not a new primitive — cosine + encode composed into a
named pattern. Pure, stateless, no protocol. The geometry is the
contract. No threshold — a threshold is a parameter pretending to
be a fact. Let the reckoner discriminate. The `m:` prefix is
correct — different ontological levels. Concern: 78/22 atom split
(100 market vs 28 exit). Measure empirically.

**Beckman:** Algebraically sound. Cosine-projection, not
left-inverse. Presences ≈ 1/sqrt(N), not 1.0. JL at D=10,000
with N≈100 gives S/N ~10. One requirement: `m:` prefixed atom
names must be pre-registered with the VectorManager at startup.
Walk the market AST once, register all `m:` atoms.

## The changes

1. **New function:** `extract(ast, vec, encoder) → ast` in
   `thought_encoder.rs`. Walks the AST tree, cosines each leaf
   against the vector using cached encodings, returns a new AST
   with `m:` prefixed names and presence values.

2. **VectorManager pre-registration:** At startup, walk the
   market vocabulary ASTs for a default candle, prefix each atom
   name with `m:`, register with VectorManager. The atoms exist
   before the first extraction.

3. **Pipe change:** The market observer thread sends the AST
   alongside the thought and misses. The exit grid receives it.

4. **Exit encoding (step 2):** After encoding exit facts, call
   `extract` on the market observer's `(ast, anomaly)` pair.
   Append the extracted AST to the exit's facts before encoding.

5. **No threshold.** All presences enter the vocabulary. The
   reckoner decides what matters. Near-zero presence is the
   absence of signal — also information.

6. **`m:` prefix.** Different atoms. `rsi` is the exit's own
   measurement. `m:rsi` is the market observer's noise-stripped
   judgment about RSI. Different ontological levels.

## What doesn't change

- The market observer's encoding or learning.
- The exit observer's own 28 atoms.
- The exit reckoner queries on exit-thought (Proposal 026).
- The broker (future work — can extract from both).
- The ThoughtAST type.
- The simulation or paper mechanics.
