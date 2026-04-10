# Resolution: Proposal 011 — Paper Lifetime

**Date:** 2026-04-10
**Decision:** REJECTED. The question was wrong.

## The designers

**Hickey (CONDITIONAL):** Use a cap. Produce partial resolutions at
eviction. Unbounded accumulation is the absence of a design choice.

**Beckman (REJECTED):** The paper is a product type where the domain
demands a coproduct. Each side resolves independently. The deque
bounds itself by trail distance. The performance problem dissolves
because the design becomes correct. Reject the cap. Decompose the
paper.

## The builder's insight

"Why do papers need BOTH sides to resolve? Each side is independent."

The builder saw it before the designers confirmed it. The buy side
fires → direction observation (Up). The sell side fires → direction
observation (Down). Each is its own learning event. The coupling was
the bug. The unbounded growth was the symptom.

## The decision

Decompose the paper. Each side resolves independently. Each side
produces its own Resolution with its own direction, outcome, and
optimal distances. A paper lives for at most `trail_distance` worth
of candles per side. No cap to tune. No partial resolution to design.
No stale papers to evict. The structure IS the solution.

## What changes

- PaperEntry: each side resolves independently. `tick_paper` produces
  0, 1, or 2 Resolutions per tick (one per newly-resolved side).
  A side that already resolved is skipped.
- Paper deque: papers are removed when BOTH sides have resolved
  (cleanup, not learning gate). But the deque stays bounded because
  each side resolves within a few candles.
- The Resolution carries the direction of the RESOLVED side.
