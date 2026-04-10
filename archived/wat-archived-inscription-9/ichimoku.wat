;; vocab/market/ichimoku.wat — cloud position, TK cross
;; Depends on: candle
;; MarketLens :structure uses this module.

(require primitives)
(require candle)

(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (cloud-top (:cloud-top c))
        (cloud-bottom (:cloud-bottom c))
        (cloud-width (- cloud-top cloud-bottom))
        ;; Cloud position: where is close relative to the cloud?
        ;; above cloud: positive. in cloud: near zero. below: negative.
        (cloud-position (cond
                          ((> close cloud-top)
                           ;; Above cloud — distance above as ratio
                           (if (= cloud-top 0.0) 0.0
                             (/ (- close cloud-top) cloud-top)))
                          ((< close cloud-bottom)
                           ;; Below cloud — distance below as negative ratio
                           (if (= cloud-bottom 0.0) 0.0
                             (/ (- close cloud-bottom) cloud-bottom)))
                          (else
                           ;; Inside cloud — position within [0, 1] centered at 0
                           (if (= cloud-width 0.0) 0.0
                             (- (* 2.0 (/ (- close cloud-bottom) cloud-width)) 1.0))))))
    (list
      ;; Cloud position — signed distance from cloud
      (Linear "cloud-position" cloud-position 0.1)
      ;; Cloud thickness — log because it can vary widely
      (Log "cloud-thickness" (+ 1.0 (if (= close 0.0) 0.0 (/ cloud-width close))))
      ;; TK cross delta — signed change in tenkan-kijun spread
      (Linear "tk-cross-delta" (:tk-cross-delta c) 0.01)
      ;; Tenkan-kijun spread — current spread as ratio of price
      (Linear "tk-spread" (if (= close 0.0) 0.0
                            (/ (- (:tenkan-sen c) (:kijun-sen c)) close))
              0.01))))
