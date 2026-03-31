# Resolution: Proposal 001 — Streaming Desks

Status: **ACCEPTED with refinements**

Both designers approved.

## The design

- Event sum type: Candle(asset, candle) | Deposit(asset, amount) | Withdraw(asset, amount)
- Desk as value: two-sided freshness slots, candle buffer, observers, manager
- Fold over merged stream: one event at a time, sequential, deterministic

## Designer refinements (both agree)

1. **Split observe from act.** desk-observe (always, on any relevant candle) + desk-act (only when both sides fresh). Journals learn from partial data. The desk is warm before both streams align.

2. **Price map in enterprise state, not treasury.** Treasury receives prices for valuation. It doesn't observe candle streams. Separation of concerns.

3. **Staleness per-side in candle intervals.** Stablecoin side gets +inf (never stale). Quote side staleness = N candle intervals. Not seconds.

4. **Two-phase tick for fairness.** All desks recommend (pure), then enterprise allocates and executes. Prevents ordering bias. Natural home for future cross-desk manager.

## What to implement

1. Event enum in enterprise
2. Desk struct with two-sided freshness + observe/act split
3. Merged stream from candle DBs (ORDER BY timestamp)
4. Price map on enterprise state
5. Single-pair case first: BTC/USDC proves the architecture
