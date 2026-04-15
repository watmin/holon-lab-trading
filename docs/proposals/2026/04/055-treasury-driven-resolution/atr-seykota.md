# ATR Median Window — Seykota

Use 2016 candles (one week).

The median is answering: "what does normal volatility look like right now?"
That question has a natural timescale — long enough to be stable,
short enough to track regime changes.

- **14 candles** — you're measuring noise, not regime. The median
  collapses to the ATR itself. No information gained.
- **500 candles** — too reactive. A single volatility spike shifts
  your "normal" and your deadlines whipsaw with it. You want the
  deadline to be *anti-correlated* with current vol, not dragged
  around by it.
- **4032 candles** — too slow. Two weeks of 5-minute candles means
  your baseline still remembers a regime that ended days ago.
  Deadlines become stale.
- **2016 candles** — one week is the natural period. Markets have
  weekly structure (Asia open, London, NY, weekend). One full cycle
  gives you a stable median that still adapts when the regime
  genuinely shifts.

The principle: the reference window should be one full cycle of the
dominant periodicity in your data. For intraday crypto on 5-minute
bars, that cycle is one week.

Don't overthink it. Get it running, then let the data tell you if
the window needs adjustment. The exact number matters less than
the decision to use a median instead of a mean.
