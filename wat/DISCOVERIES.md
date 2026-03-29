# Wat Discoveries

Ideas, findings, and improvements encountered while backfilling the wat specifications.
Append-only. Each entry dated. The act of writing specifications reveals gaps.

---

(Entries 1-23 from earlier in session — see git history for full content)

## 2026-03-29: Position management debugging

24. **SELL positions had -100% P&L.** return_pct() assumed BUY direction (wbtc_held × price).
    SELL positions hold USDC not WBTC. Fixed with direction-aware P&L. Found by querying
    the DB — all SELL stop losses showed identical -100.35% despite tiny price movements.

25. **BUY positions NEVER close.** 1,302 BUY opens, zero BUY stop losses, zero BUY partial
    profits. All 29,344 "BUY HorizonExpiry" entries are from the learning pipeline (Pending),
    not from managed positions. The managed BUY positions accumulate in the positions vector
    forever. The stop at 0.6% below entry SHOULD fire — BTC easily moves 0.6% in a few
    candles. BUG TO FIND: why doesn't the BUY stop trigger?

    Hypothesis: the trailing stop tightens to 0.3% after one uptick (trail = 1.5 × ATR vs
    stop = 3 × ATR). But even 0.3% drops happen constantly. Something else prevents the
    stop from firing. Need to add diagnostic logging to the tick() method.

26. **The ledger mixes learning trades with managed positions.** HorizonExpiry entries are
    paper learning trades from the Pending pipeline. StopLoss/PartialProfit/Open entries are
    from managed positions. They're in the same table with no distinguishing column. Should
    add a `source` column: 'learning' vs 'managed'.

27. **HorizonExpiry should not exist for managed positions.** The user asked "why does expire
    even exist?" Managed positions live until stop or TP. Period. The market closes them.
    HorizonExpiry is for the learning pipeline only.
