# Exit Atoms: Trend Following (Seykota)

The reckoner predicts trail WIDTH. The trail does the holding. The exit observer thinks about the trade, not the market.

## Atoms

```scheme
;; How volatile is this trade relative to its own history?
(Log "trade-atr-ratio"
  (/ current-candle-range trade-average-range))
;; Range expansion = widen the trail. Contraction = tighten it.

;; How far has the trade run from entry?
(Log "excursion-to-atr"
  (/ (abs (- current-price entry-price)) trade-atr))
;; A 6-ATR move gets a wider trail than a 1-ATR move.
;; The trend has earned room to breathe.

;; How deep is the current pullback from the trade's peak?
(Linear "retracement-depth" (/ (- peak current-price) (- peak entry-price)) 1.0)
;; 0.0 = at peak. 1.0 = back to entry. The trail width
;; should reflect how much the trade has already given back.

;; How old is the trade?
(Log "trade-age"
  (/ candles-held 100.0))
;; Young trades need tight protection. Mature trends
;; have proven themselves and earn wider trails.

;; Is the pullback accelerating or decelerating?
(Linear "pullback-velocity"
  (/ (- prior-close current-close) trade-atr) 1.0)
;; Positive = price falling away from peak (for a long).
;; A fast pullback wants a tighter trail. A slow drift
;; is noise — let the trail absorb it.

;; How much of the excursion has the trail already locked in?
(Linear "trail-lock-ratio"
  (/ (- trail-stop entry-price) (- peak entry-price)) 1.0)
;; 0.0 = trail still at entry. 1.0 = trail at peak.
;; If the trail already locks in most of the gain,
;; the width question is: how much more to give back.
```

Six atoms. Each is computable from fields already on the Trade struct: `entry-price`, `price-history` (gives peak, current, ranges, ATR), `candles-held`, and `stop-levels` (gives trail-stop). No new data needed.

The market observer says what is forming. These atoms say what the trade has done. The reckoner learns: given this trade shape, what trail width would have captured the most?
