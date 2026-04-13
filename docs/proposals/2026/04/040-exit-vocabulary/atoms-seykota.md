# Exit Trade Atoms: Seykota

The reckoner predicts trail WIDTH. Give it facts about the trade's shape so it can learn when to hold tight and when to give room.

```scheme
;; How far has this trade run? Log scale — a 10% move matters more than 1%.
(Log "exit-excursion" (/ (- extreme entry-price) entry-price))

;; How much of the run have we given back? 0 = at peak, 1 = round-tripped.
(Linear "exit-retracement" (/ (- extreme current) (- extreme entry-price)) 1.0)

;; Current trail width as fraction of extreme. This is the reckoner's OWN prior output — feedback.
(Log "exit-trail-distance" (/ (- extreme trail-level) extreme))

;; Capital at risk: how far to the hard stop. Tells the reckoner the constraint it's working within.
(Log "exit-stop-distance" (/ (abs (- entry-price stop-level)) entry-price))

;; How old is this trade? Young trades need room. Old trades have already spoken.
(Log "exit-age" age)

;; How stale is the peak? Candles since extreme was set. A peak aging without new highs is a trend dying.
(Log "exit-peak-age" peak-age)

;; Has the trail been touched? Binary fact. Once signaled, the character of the trade changes.
(Linear "exit-signaled" (if signaled 1.0 0.0) 1.0)
```

Seven atoms. Excursion and retracement describe the trade's shape. Trail and stop distance describe the current protection geometry. Age and peak-age describe time. Signaled marks the phase transition. The reckoner has everything it needs to learn width.