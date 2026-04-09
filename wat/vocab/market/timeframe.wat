;; vocab/market/timeframe.wat — 1h/4h structure + narrative + inter-timeframe agreement
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :narrative

(require primitives)
(require candle)

(define (encode-timeframe-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((tf-1h-ret (:tf-1h-ret c))
        (tf-1h-body (:tf-1h-body c))
        (tf-4h-ret (:tf-4h-ret c))
        (tf-4h-body (:tf-4h-body c))
        (tf-agreement (:tf-agreement c))
        (roc-1 (:roc-1 c)))
    (list
      ;; 1h return — signed
      (Linear "tf-1h-ret" tf-1h-ret 0.1)

      ;; 1h body ratio — how much of the range is body
      (Linear "tf-1h-body" tf-1h-body 1.0)

      ;; 1h trend direction — positive = bullish
      (Linear "tf-1h-trend" (signum tf-1h-ret) 1.0)

      ;; 4h return — signed
      (Linear "tf-4h-ret" tf-4h-ret 0.1)

      ;; 4h body ratio
      (Linear "tf-4h-body" tf-4h-body 1.0)

      ;; 4h structure — the longer-term narrative
      (Linear "tf-4h-structure" (signum tf-4h-ret) 1.0)

      ;; 5m return — the immediate candle
      (Linear "tf-5m-ret" roc-1 0.05)

      ;; Inter-timeframe agreement — [0, 1]. 1.0 = all agree
      (Linear "tf-agreement" tf-agreement 1.0))))
