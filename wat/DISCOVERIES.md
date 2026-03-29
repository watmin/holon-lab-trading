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

28. **Position exit direction was hardcoded "Sell".** Every exit logged as SELL regardless of
    actual direction. BUY stops were invisible in the DB — they were firing correctly but
    recorded as SELL stops. "The enterprise was working. The ledger was lying."

29. **BUY positions work: 30 runners at +1.80%, 35 partials, 753 stops at -1.39%.** The
    runners prove the partial-profit → runner lifecycle works. But 753 stops overwhelm
    30 runners economically. The enterprise churns: open, stop, open, stop.

30. **SELL positions work: 8 partial profits at +1.64%, 133 stops at -0.54%.** The SELL
    stop losses are smaller than BUY stops (-0.54% vs -1.39%) because price tends to
    rise over this period (2019 BTC bull market). SELL positions lose less per stop but
    still lose net.

31. **Fractional allocation saves the enterprise.** -1.3% total loss despite 753 BUY stops.
    At 1.5% per position, each stop loses ~0.02% of equity. The enterprise bleeds slowly.
    With 100% position sizing this would be -40%+.

32. **K_trail = 1.5 × ATR may be too tight.** The trailing stop at 0.3% behind high water
    fires on normal 5-minute retraces. Runners that survive average +1.80%, but many
    potential runners get stopped at +0.5% that could have reached +3%. The Exit Expert
    (#1) should learn the optimal trail from the distribution of runner returns.

33. **Every position exits via stop loss.** This is correct. The TP converts to a runner.
    The runner trails until stopped. The stop is always the final exit. The question is
    WHERE the stop is — that's the trail distance, which is the greed parameter.

34. **Position is asset-agnostic.** The mechanics are: swap A→B, manage, swap B→A.
    BUY = USDC→WBTC. SELL = WBTC→USDC. But could be USDC→SOL or WBTC→ETH. The
    position struct needs from_asset/to_asset fields for multi-asset generalization.
