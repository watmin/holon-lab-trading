;; ichimoku.wat — cloud zone, TK cross, cloud width, cloud position
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Ichimoku levels are streaming per-candle fields on the Candle struct.
;; Cloud position and TK relationship are signed scalars, not zones.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; Cloud position: signed distance from cloud center.
;; Positive = above cloud. Negative = below. Near zero = in cloud.
;; Scale: percentage of price.
;;
;; TK spread: (tenkan - kijun) / close. Signed.
;; Positive = tenkan above kijun (bullish). Negative = bearish.
;;
;; Cloud thickness — how decisive is the cloud?
;;
;; TK cross delta — pre-computed on Candle. Signed.
;; Change in (tenkan - kijun) from previous candle.
;; Positive = TK spread widening bullishly. Negative = narrowing or bearish.

(define (encode-ichimoku-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let ((cloud-top    (:cloud-top candle))
        (cloud-bottom (:cloud-bottom candle)))

    ;; Guard: ichimoku needs warmup (52 candles). cloud-top = 0 during warmup.
    (if (<= cloud-top 0.0)
      (list)
      (let* ((close   (:close candle))
             (tenkan  (:tenkan-sen candle))
             (kijun   (:kijun-sen candle))

             ;; Cloud center and position
             (cloud-mid (/ (+ cloud-top cloud-bottom) 2.0))
             (cloud-pos (/ (- close cloud-mid) close))

             ;; Cloud thickness — how decisive is the cloud?
             (cloud-width (/ (- cloud-top cloud-bottom) close))

             ;; TK spread
             (tk-spread (/ (- tenkan kijun) close))

             ;; TK cross delta — pre-computed, captures cross momentum
             (tk-delta (:tk-cross-delta candle)))

        (list
          (Linear "cloud-pos" cloud-pos 0.1)
          (Log "cloud-width" (max cloud-width 0.0001))
          (Linear "tk-spread" tk-spread 0.1)
          (Linear "tk-cross-delta" tk-delta 0.1))))))
