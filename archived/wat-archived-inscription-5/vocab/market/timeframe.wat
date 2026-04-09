;; vocab/market/timeframe.wat — 1h/4h structure + narrative + inter-timeframe agreement
;; Depends on: candle
;; MarketLens :narrative selects this module.

(require primitives)
(require candle)

;; Timeframe facts — what the higher timeframes say.
;; The 5-minute bar is noise. The 1h bar is signal. The 4h bar is structure.
;; Inter-timeframe agreement: are all timeframes voting the same way?
(define (encode-timeframe-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; 1h return — signed. Direction of the hourly candle.
    (Linear "tf-1h-ret" (:tf-1h-ret c) 0.1)

    ;; 1h body ratio — how decisive is the hourly candle?
    (Linear "tf-1h-body" (:tf-1h-body c) 1.0)

    ;; 1h range position — where is close in the hourly range?
    (let ((rng (- (:tf-1h-high c) (:tf-1h-low c))))
      (Linear "tf-1h-range-pos"
        (if (= rng 0.0) 0.5
          (/ (- (:close c) (:tf-1h-low c)) rng))
        1.0))

    ;; 4h return — signed. Direction of the 4-hour candle.
    (Linear "tf-4h-ret" (:tf-4h-ret c) 0.1)

    ;; 4h body ratio
    (Linear "tf-4h-body" (:tf-4h-body c) 1.0)

    ;; 4h range position
    (let ((rng (- (:tf-4h-high c) (:tf-4h-low c))))
      (Linear "tf-4h-range-pos"
        (if (= rng 0.0) 0.5
          (/ (- (:close c) (:tf-4h-low c)) rng))
        1.0))

    ;; Inter-timeframe agreement — [0, 1]. 1.0 = all timeframes agree.
    (Linear "tf-agreement" (:tf-agreement c) 1.0)

    ;; 5m-vs-1h direction alignment — signed product.
    ;; Positive = same direction. Negative = disagreement.
    (Linear "tf-5m-1h-align"
      (let ((dir5m (signum (:roc-1 c)))
            (dir1h (signum (:tf-1h-ret c))))
        (* dir5m dir1h))
      1.0)))
