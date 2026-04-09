;; vocab/market/ichimoku.wat — cloud position, TK cross
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :structure

(require primitives)
(require candle)

(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (tenkan (:tenkan-sen c))
        (kijun (:kijun-sen c))
        (cloud-top (:cloud-top c))
        (cloud-bottom (:cloud-bottom c))
        (cloud-width (- cloud-top cloud-bottom))
        (tk-delta (:tk-cross-delta c)))
    (list
      ;; Cloud position — where is price relative to the cloud?
      ;; Signed: positive = above cloud, negative = below
      (if (> close cloud-top)
        (let ((dist (/ (- close cloud-top) close)))
          (Log "ichimoku-above-cloud" (+ 1.0 dist)))
        (if (< close cloud-bottom)
          (let ((dist (/ (- cloud-bottom close) close)))
            (Bind (Atom "ichimoku-below-cloud") (Log "ichimoku-below-distance" (+ 1.0 dist))))
          ;; Inside the cloud — position within
          (let ((cloud-pos (if (= cloud-width 0.0) 0.5
                            (/ (- close cloud-bottom) cloud-width))))
            (Linear "ichimoku-in-cloud" cloud-pos 1.0))))

      ;; TK cross — tenkan vs kijun spread, normalized by price
      (Linear "tk-spread" (/ (- tenkan kijun) (max close 1.0)) 0.01)

      ;; TK cross delta — velocity of the TK spread change
      (Linear "tk-cross-delta" tk-delta 1.0)

      ;; Cloud width — volatility measure
      (Log "cloud-width" (+ 1.0 (/ cloud-width (max close 1.0)))))))
