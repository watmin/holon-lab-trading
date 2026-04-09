;; vocab/market/ichimoku.wat — cloud position, TK cross
;; Depends on: candle
;; MarketLens :structure uses this.

(require primitives)
(require candle)

;; Ichimoku facts — cloud structure and momentum.
(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (cloud-mid (/ (+ (:cloud-top c) (:cloud-bottom c)) 2.0))
        (cloud-width (- (:cloud-top c) (:cloud-bottom c)))
        ;; Cloud position: where is close relative to the cloud?
        ;; Positive = above cloud, negative = below, near 0 = inside.
        (cloud-position (if (= cloud-width 0.0)
                          0.0
                          (/ (- close cloud-mid) cloud-width))))
    (list
      ;; Cloud position — signed, unbounded beyond [-1, 1]
      (Linear "ichimoku-cloud-position" cloud-position 2.0)
      ;; TK cross delta — signed change in (tenkan - kijun) spread
      (Linear "tk-cross-delta" (:tk-cross-delta c) 100.0)
      ;; Tenkan-Kijun spread as fraction of close
      (Linear "tk-spread" (if (= close 0.0) 0.0
                            (/ (- (:tenkan-sen c) (:kijun-sen c)) close)) 0.01))))
