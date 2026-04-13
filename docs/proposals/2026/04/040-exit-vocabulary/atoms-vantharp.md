# Exit Trade Atoms: Van Tharp

The reckoner needs R-multiple awareness. Every trade is measured from entry risk. These atoms give the reckoner position-in-R-space so it can learn when to tighten and when to let it run.

```scheme
;; R-multiple: how far the trade has moved in units of initial risk
(Log "exit-r-multiple" (/ excursion stop-distance))

;; Retracement: how much of the favorable move has been given back (0=at peak, 1=back to entry)
(Linear "exit-retracement" retracement 1.0)

;; Heat: current trail width as fraction of remaining profit
(Linear "exit-heat" (/ trail-distance excursion) 1.0)

;; Age: trades that linger die. Log because early candles matter more than late ones.
(Log "exit-age" age)

;; Peak staleness: candles since the extreme formed. Stale peaks mean momentum died.
(Log "exit-peak-age" peak-age)

;; Signaled: binary. The trail has been touched. Everything changes after this.
(Linear "exit-signaled" (if signaled 1.0 0.0) 1.0)
```

Six atoms. Three about where the trade IS in R-space (r-multiple, retracement, heat). Three about whether the trade is ALIVE (age, peak-age, signaled). The reckoner decides what predicts good trail width. We just name the facts.
