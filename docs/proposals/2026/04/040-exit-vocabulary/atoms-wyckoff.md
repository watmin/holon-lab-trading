# Exit Trade Atoms: Wyckoff

The trail width must respond to how supply and demand have behaved since entry. These atoms describe the position's effort-result relationship — where price went, how far it gave back, and whether the move is spent.

```scheme
;; Excursion: how far price has traveled in our favor. The "result" of the move.
;; Log scale — compound returns. Buy side shown; exit observer picks the relevant side.
(Log "exit-buy-excursion" (/ (- buy-extreme entry-price) entry-price))
(Log "exit-sell-excursion" (/ (- entry-price sell-extreme) entry-price))

;; Retracement from extreme: how much of the markup has been given back.
;; 0 = at peak, 1 = round-tripped to entry. This IS the distribution signal.
(Linear "exit-buy-retracement" (/ (- buy-extreme current-price) (max 1e-9 (- buy-extreme entry-price))) 1.0)
(Linear "exit-sell-retracement" (/ (- current-price sell-extreme) (max 1e-9 (- entry-price sell-extreme))) 1.0)

;; Trail cushion: current trail distance as fraction of excursion. How much room remains.
(Linear "exit-buy-trail-cushion" (/ (- current-price buy-trail-stop) (max 1e-9 (- buy-extreme entry-price))) 2.0)
(Linear "exit-sell-trail-cushion" (/ (- sell-trail-stop current-price) (max 1e-9 (- entry-price sell-extreme))) 2.0)

;; Age of the position. Young trades need room for accumulation. Old trades have distributed.
(Log "exit-age" candles-held)

;; Effort without result: candles since the extreme was set. Derived from price-history.
;; Stale peak = supply absorbing demand. NEEDS: peak-age computed from price-history at tick time.
(Log "exit-buy-peak-age" buy-peak-age)
(Log "exit-sell-peak-age" sell-peak-age)
```

Ten atoms. Excursion measures result. Retracement measures distribution. Trail cushion measures remaining room. Age measures maturity. Peak age measures effort without result — the strongest sign that the markup phase is over.

**Note:** `peak-age` (candles since extreme was last updated) is not stored on the paper today. It must be computed by comparing `buy-extreme`/`sell-extreme` before and after each tick, or by adding a counter field to `paper-entry`.
