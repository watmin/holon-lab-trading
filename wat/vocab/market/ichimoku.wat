;; vocab/market/ichimoku.wat — cloud position, TK cross
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (cloud-top (:cloud-top c))
        (cloud-bottom (:cloud-bottom c))
        (cloud-width (- cloud-top cloud-bottom)))
    (append
      ;; Cloud position — where is price relative to the cloud?
      ;; Above cloud, inside cloud, below cloud — one continuous scalar
      (if (> close cloud-top)
        ;; Above cloud: distance above, as log ratio
        (list (Log "cloud-position-above" (max (/ (- close cloud-top) close) 0.001)))
        (if (< close cloud-bottom)
          ;; Below cloud: distance below, as log ratio (negative sense via atom name)
          (list (Log "cloud-position-below" (max (/ (- cloud-bottom close) close) 0.001)))
          ;; Inside cloud: position within [0, 1]
          (if (= cloud-width 0.0)
            (list (Linear "cloud-position-inside" 0.5 1.0))
            (list (Linear "cloud-position-inside"
                    (/ (- close cloud-bottom) cloud-width) 1.0)))))

      ;; TK cross — tenkan/kijun spread and its change
      (list
        (Linear "tk-spread" (if (= close 0.0) 0.0
                              (/ (- (:tenkan-sen c) (:kijun-sen c)) close)) 0.05)
        (Linear "tk-cross-delta" (:tk-cross-delta c) 0.01)))))
