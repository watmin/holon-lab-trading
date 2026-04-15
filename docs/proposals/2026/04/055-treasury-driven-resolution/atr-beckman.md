# ATR Lookback Window — Beckman Response

The formula `deadline_candles = base_deadline * (median_atr / current_atr)` is
dimensionally clean. The ratio median/current is unitless, so the output has
units of candles. The composition with base_deadline is a simple scaling — no
hidden nonlinearity. Good.

Two observations on the algebra:

1. **Boundedness.** When current_atr approaches zero (dead market), the
   deadline goes to infinity. You need a clamp: `min(max_deadline,
   base_deadline * median_atr / current_atr)`. Symmetrically, during a
   flash crash current_atr spikes and the deadline could collapse to 1-2
   candles — below what any observer can evaluate. Clamp both sides.

2. **The median window.** The median is doing regime detection. It answers:
   "what is typical RIGHT NOW?" That means the window should span roughly
   one regime, not several. For 5-minute BTC candles, regimes persist on
   the order of days to weeks. A 2016-candle window (7 days) is too
   reactive — it tracks intra-regime noise. A 60480-candle window (7 weeks)
   is too stale — it spans multiple regimes and the median becomes a
   historical artifact. The sweet spot is **8064 candles (4 weeks)** — long
   enough to be robust against single-day spikes, short enough to shift
   when the regime genuinely changes.

   But: don't optimize this. The median of a rolling window is a sufficient
   statistic for "typical." Four weeks is a defensible starting point. If
   the system is sensitive to this parameter, the formula has a deeper
   problem. A well-designed ratio should be robust to 2x changes in the
   lookback. Test 2 weeks, 4 weeks, 8 weeks. If the outcomes diverge
   wildly, the issue is the base_deadline, not the window.

The formula is sound. Clamp both ends. Start at 4 weeks. Move on.
