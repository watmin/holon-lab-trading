;; vocab/market/timeframe.wat — 1h/4h structure + narrative + inter-timeframe agreement
;; Depends on: candle
;; MarketLens :narrative uses this.

(require primitives)
(require candle)

;; Timeframe facts — multi-resolution price structure.
;; 1h = 12 × 5-min candles. 4h = 48 × 5-min candles.
(define (encode-timeframe-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; 1h return — signed
    (Linear "tf-1h-ret" (:tf-1h-ret c) 0.1)
    ;; 1h body ratio — [0, 1]. How much of the range is body (vs wick).
    (Linear "tf-1h-body" (:tf-1h-body c) 1.0)
    ;; 1h range as fraction of close
    (let ((one-h-range (if (= (:tf-1h-close c) 0.0) 0.0
                         (/ (- (:tf-1h-high c) (:tf-1h-low c)) (:tf-1h-close c)))))
      (Log "tf-1h-range" (max 0.001 one-h-range)))
    ;; 4h return — signed
    (Linear "tf-4h-ret" (:tf-4h-ret c) 0.1)
    ;; 4h body ratio — [0, 1]
    (Linear "tf-4h-body" (:tf-4h-body c) 1.0)
    ;; 4h range as fraction of close
    (let ((four-h-range (if (= (:tf-4h-close c) 0.0) 0.0
                          (/ (- (:tf-4h-high c) (:tf-4h-low c)) (:tf-4h-close c)))))
      (Log "tf-4h-range" (max 0.001 four-h-range)))
    ;; Inter-timeframe agreement score — [-1, 1]. Positive = all aligned.
    (Linear "tf-agreement" (:tf-agreement c) 1.0)))
