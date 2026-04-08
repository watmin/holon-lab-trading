;; ichimoku.wat — cloud zone, TK cross
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Ichimoku levels are streaming per-candle fields on the Candle struct.
;; Cloud position and TK relationship are signed scalars, not zones.

(require primitives)
(require candle)

;; Cloud position: signed distance from cloud center.
;; Positive = above cloud. Negative = below. Near zero = in cloud.
;; Scale: percentage of price.
;;
;; TK spread: (tenkan - kijun) / close. Signed.
;; Positive = tenkan above kijun (bullish). Negative = bearish.
;;
;; TK cross: the delta of TK spread from previous candle.
;; Large positive = bullish cross happening. Large negative = bearish cross.

(define (encode-ichimoku-facts [candle : Candle]
                               [candles : Vec<Candle>])
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

             (facts (list
                      (Linear "cloud-pos" cloud-pos 0.1)
                      (Log "cloud-width" (max cloud-width 0.0001))
                      (Linear "tk-spread" tk-spread 0.1))))

        ;; TK cross detection — requires previous candle
        (if (>= (len candles) 2)
          (let* ((prev       (nth candles (- (len candles) 2)))
                 (prev-tk    (- (:tenkan-sen prev) (:kijun-sen prev)))
                 (curr-tk    (- tenkan kijun))
                 (tk-delta   (/ (- curr-tk prev-tk) close)))
            (if (> (:tenkan-sen prev) 0.0)
              (append facts (list (Linear "tk-cross" tk-delta 0.1)))
              facts))
          facts)))))
