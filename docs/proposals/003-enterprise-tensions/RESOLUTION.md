# Resolution: ACCEPTED

Both designers converged to APPROVED. The tensions resolved through debate.

## Decisions

### A. Two entry points → EnrichedEvent
Both agree: unify now. The type is the contract. `EnrichedEvent` carries pre-encoded thoughts for Candle, passes through Deposit/Withdraw. One door. The encoding functor lives outside the fold.

### B. Risk boundaries → Two levels
Both agree: per-desk risk reads portfolio (trade-sequence health). Cross-desk risk reads treasury (allocation health). The fractal grows a node when the second desk arrives. Update the spec now. Build the node later.

### C. DB writes → Pure fold (DONE)
Beckman's free monad. LogEntry describes, flush_logs interprets. The fold is pure. Hickey's Option<&Connection> was simpler but Beckman's pattern is more composable. Implemented and committed.

## Remaining action items

1. **EnrichedEvent type** — unify on_event + on_candle into one entry point
2. **Dissolve the generalist** — categorical orphan, borrows manager's proof gate
3. **Replace `i` with cursor** — the fold counts its own ticks
4. **Update risk spec** — two-level framing (per-desk + cross-desk)
5. **Scoped atom namespaces** — for multi-desk (when it arrives)

Items 1-3 are immediate. Item 4 is a spec update. Item 5 is deferred.
