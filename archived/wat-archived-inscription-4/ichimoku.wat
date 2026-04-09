;; ichimoku.wat — Ichimoku cloud position and TK cross
;;
;; Depends on: candle (reads: close, tenkan-sen, kijun-sen, cloud-top,
;;                            cloud-bottom, senkou-span-a, senkou-span-b,
;;                            tk-cross-delta)
;; Market domain. Lens: :structure, :generalist.
;;
;; Cloud position not zone — signed distance from cloud, not a category.

(require primitives)

(define (encode-ichimoku-facts [candle : Candle]) : Vec<ThoughtAST>
  (let ((close (:close candle))
        (cloud-mid (* 0.5 (+ (:cloud-top candle) (:cloud-bottom candle))))
        (cloud-width (- (:cloud-top candle) (:cloud-bottom candle))))
    (list
      ;; Price position relative to cloud — signed distance as fraction of price
      (Linear "ichi-cloud-position"
        (/ (- close cloud-mid) close) 0.1)

      ;; Cloud thickness — wider cloud = stronger support/resistance
      (Log "ichi-cloud-width" (/ cloud-width close))

      ;; Tenkan-Kijun relationship — signed distance
      (Linear "ichi-tk-spread"
        (/ (- (:tenkan-sen candle) (:kijun-sen candle)) close) 0.1)

      ;; TK cross delta — change in (tenkan - kijun) from previous candle
      (Linear "ichi-tk-cross-delta" (:tk-cross-delta candle) 0.01)

      ;; Senkou span relationship — span-a vs span-b signed
      (Linear "ichi-span-spread"
        (/ (- (:senkou-span-a candle) (:senkou-span-b candle)) close) 0.1))))
