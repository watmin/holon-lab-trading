;; vocab/market/price-action.wat — range-ratio, gaps, consecutive runs
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

;; Price action facts — the raw behavior of price bars.
;; Compression vs expansion, gaps, momentum runs.
(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Range ratio — current range / prev range.
    ;; < 1.0 = compression, > 1.0 = expansion. Log for ratios.
    (Log "pa-range-ratio" (max 0.01 (:range-ratio c)))

    ;; Gap — signed. (open - prev close) / prev close.
    ;; Positive = gap up. Negative = gap down.
    (Linear "pa-gap" (:gap c) 0.05)

    ;; Consecutive up — run count of bullish closes.
    ;; Linear because we want to distinguish 1 from 5 from 10.
    (Linear "pa-consecutive-up" (:consecutive-up c) 20.0)

    ;; Consecutive down — run count of bearish closes.
    (Linear "pa-consecutive-down" (:consecutive-down c) 20.0)

    ;; Body ratio — how much of the range is body?
    ;; Computed inline: |close - open| / (high - low).
    (let ((rng (- (:high c) (:low c)))
          (body (abs (- (:close c) (:open c)))))
      (Linear "pa-body-ratio"
        (if (= rng 0.0) 0.5 (/ body rng))
        1.0))

    ;; Upper wick ratio — (high - max(open, close)) / range
    (let ((rng (- (:high c) (:low c)))
          (upper-wick (- (:high c) (max (:open c) (:close c)))))
      (Linear "pa-upper-wick"
        (if (= rng 0.0) 0.0 (/ upper-wick rng))
        1.0))

    ;; Lower wick ratio — (min(open, close) - low) / range
    (let ((rng (- (:high c) (:low c)))
          (lower-wick (- (min (:open c) (:close c)) (:low c))))
      (Linear "pa-lower-wick"
        (if (= rng 0.0) 0.0 (/ lower-wick rng))
        1.0))))
