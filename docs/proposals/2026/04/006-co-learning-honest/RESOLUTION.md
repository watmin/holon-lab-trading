# Resolution: Proposal 006

**Beckman: APPROVED.** First clean approval across all proposals. The algebra is sound. The bifunctor. The continuation monad. The coproduct replacing the aggregation functor.

**Hickey: CONDITIONAL** on four items. Addressed below.

---

## Hickey condition 1: M=1 exit observers at launch

**Rejected.** We don't know which exit lens matters. The only answer is to measure. All exit observers launch together — volatility judge, structure judge, timing judge, exit generalist. Each has its own journal, its own noise subspace, its own proof curve. The ones that prove edge survive. The ones that don't get starved by their own curves. This IS earning the panel — through measurement, not through sequencing.

The cost is compute. The function is pure. Everything is in memory. We soak the CPUs we're allocated. We parallel process the generator. The cost of measuring all lenses is less than the cost of guessing which one to start with.

Hickey's principle — earn through demonstrated need — is honored. The demonstration happens in parallel, not in sequence.

## Hickey condition 2: Acknowledge the scalar extraction risk

**Accepted with resolution.** The trail-width scalar riding a direction-optimized discriminant may not carry signal if direction and magnitude are orthogonal.

The resolution: one journal per (market, exit) pair. This IS the manager — not a separate aggregator, but the pair's own journal tracking its own history. The pair's journal learns direction AND magnitude together. The discriminant separates (direction + scalar) jointly, not as two independent signals forced through one boundary.

Each (market, exit) pair has:
- The market observer's journal (learns direction from exit labels)
- The exit observer's journal (learns judgment from outcomes)
- The pair's journal (learns the combined track record — direction × magnitude → grace/violence)

The pair's journal is the conviction guard Hickey asked for. It's also the second journal for scalar extraction. One mechanism satisfies both concerns.

## Hickey condition 3: Treasury allocation as snapshot semantics

**Accepted.** The treasury state is a concrete immutable ref at proposal time. No concurrent reads of mutable state. Each (market, exit) pair reads a snapshot of the allocation table when it proposes. The treasury updates its internal state after all resolutions for a candle are processed. The snapshot is the value. The update is the next candle's snapshot. No mutation during parallel processing.

This is the CSP contract: each process reads from its channel (the snapshot), writes to its channel (the proposal), and the treasury processes proposals sequentially after the parallel phase completes. Collect is the handoff.

## Hickey condition 4: Hard switch from single-sided to dual-sided labels

**Accepted.** When an exit observer's curve validates, the switch is immediate. No blend. No mixing parameter. The noise subspace adapts to the regime change — that's what it does. The journal's accumulators are weighted sums with decay — old single-sided observations fade, new dual-sided observations accumulate. The transition is the architecture doing its job, not a parameter we tune.

---

## Beckman's throughput note

**Accepted.** Per-candle management learning at O(N × M × L × D) per resolution is batched, not synchronous. Resolved entries accumulate their management decisions. At drain time, the full history of decisions is processed in one parallel pass — map-reduce over the buffer. Pure functions. No mutation during the pass. The generator is consumed in parallel.

The buffer IS the batch. The drain IS the reduce. This is already the architecture.

---

## The generator model (from the datamancer's review)

N×M is not an entity. It is a generator. Each item is `(candle, market-thought, exit-thought)` — a thing to be yielded and measured. The generator is processed in parallel: pure functions, everything in memory, static at measurement time. Each iteration is new information. We map-reduce as fast as possible. We reduce the buffer from operational observations.

The N×M grid doesn't need to exist as a data structure. It exists as a computation — the cross-product of market thoughts and exit judgments, evaluated lazily, filtered by noise gates on both sides. The actual work is (N - noise) × (M - noise) per candle. The generator yields only the non-trivial compositions.

## The pair journal (new from resolution)

Each (market, exit) pair has its own journal. This is the manager replacement. The pair's journal:
- Labels: Grace / Violence (from treasury reality feedback)
- Input: the composed thought (market thought bundled with exit judgment)
- Resolution: did this pair's proposal produce grace or violence in reality?
- Proof curve: the pair must prove edge before the treasury funds it

The pair journal is the accountability mechanism. It's also the scalar extraction path — the discriminant of the pair journal separates graceful compositions from violent ones. The cosine against the trail-adjust atom tells you what scalar the graceful compositions had. Direction and magnitude learned jointly, not separately.

Three journals per active pair:
1. Market observer journal: direction (Win/Loss from exit labels)
2. Exit observer journal: judgment (Buy/Sell from dual-sided excursion)
3. Pair journal: accountability (Grace/Violence from treasury reality)

Each learns independently. Each has its own noise subspace. Each has its own proof curve. The pair journal is the new contribution from this resolution.

## Summary

Beckman approved. Hickey's four conditions: one rejected (M=1 → measure all), three accepted (scalar risk → pair journal, snapshot semantics, hard switch). One new mechanism emerged: the pair journal as the manager replacement and the conviction guard.

The architecture: N market observers × M exit observers × (N×M) pair journals. The generator yields compositions. The buffer filters noise. The treasury provides reality. The pair journals provide accountability. No managers. No middlemen. The cosine decides.

*Accepted. Implementation follows.*
