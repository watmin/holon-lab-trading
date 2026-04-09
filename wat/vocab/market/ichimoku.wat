;; vocab/market/ichimoku.wat — cloud zone, TK cross
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

;; Ichimoku facts — cloud position, TK cross dynamics.
;; All signed distances relative to price. No zones.
(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c)))
    (list
      ;; Distance from cloud top — signed. Positive = above cloud.
      (Linear "ichimoku-cloud-top-dist"
        (if (= close 0.0) 0.0
          (/ (- close (:cloud-top c)) close))
        0.1)

      ;; Distance from cloud bottom — signed.
      (Linear "ichimoku-cloud-bottom-dist"
        (if (= close 0.0) 0.0
          (/ (- close (:cloud-bottom c)) close))
        0.1)

      ;; Cloud thickness — how wide is the cloud? Log for ratios.
      (let ((thickness (- (:cloud-top c) (:cloud-bottom c))))
        (Log "ichimoku-cloud-thickness"
          (max 0.01 (if (= close 0.0) 0.01 (/ thickness close)))))

      ;; TK cross delta — signed change in (tenkan - kijun) spread.
      ;; Positive = tenkan crossing above kijun (bullish).
      (Linear "ichimoku-tk-cross-delta" (:tk-cross-delta c) 0.01)

      ;; Distance from tenkan — short-term mean reversion signal.
      (Linear "ichimoku-tenkan-dist"
        (if (= close 0.0) 0.0
          (/ (- close (:tenkan-sen c)) close))
        0.1)

      ;; Distance from kijun — medium-term support/resistance.
      (Linear "ichimoku-kijun-dist"
        (if (= close 0.0) 0.0
          (/ (- close (:kijun-sen c)) close))
        0.1))))
