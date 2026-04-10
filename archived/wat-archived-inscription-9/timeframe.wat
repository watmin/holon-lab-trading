;; vocab/market/timeframe.wat — 1h/4h structure + narrative + inter-timeframe agreement
;; Depends on: candle
;; MarketLens :narrative uses this module.

(require primitives)
(require candle)

(define (encode-timeframe-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; 1h timeframe
    (Linear "tf-1h-ret" (:tf-1h-ret c) 0.05)
    (Linear "tf-1h-body" (:tf-1h-body c) 1.0)
    (Linear "tf-1h-range-pos"
      (let ((rng (- (:tf-1h-high c) (:tf-1h-low c))))
        (if (= rng 0.0) 0.5
          (/ (- (:tf-1h-close c) (:tf-1h-low c)) rng)))
      1.0)
    ;; 4h timeframe
    (Linear "tf-4h-ret" (:tf-4h-ret c) 0.05)
    (Linear "tf-4h-body" (:tf-4h-body c) 1.0)
    (Linear "tf-4h-range-pos"
      (let ((rng (- (:tf-4h-high c) (:tf-4h-low c))))
        (if (= rng 0.0) 0.5
          (/ (- (:tf-4h-close c) (:tf-4h-low c)) rng)))
      1.0)
    ;; Inter-timeframe agreement — [0, 1]
    (Linear "tf-agreement" (:tf-agreement c) 1.0)))
