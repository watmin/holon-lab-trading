;; flow.wat — OBV, VWAP, MFI, buying/selling pressure
;;
;; Depends on: candle
;; Domain: market (MarketLens :volume)
;;
;; Volume tells what CONVICTION accompanies a move.
;; Price without volume is opinion. Price with volume is fact.

(require primitives)
(require candle)

;; OBV slope — pre-computed on Candle (12-period linear regression slope).
;; Sign: +1 volume rising, -1 volume falling. Magnitude: how fast.
;; Divergence: OBV direction disagrees with price direction.
;;
;; VWAP distance — window-dependent. How far price is from the
;; volume-weighted average. Signed: positive = above, negative = below.
;;
;; MFI — pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;;
;; Buying/selling pressure — wick analysis per candle.
;; buy-pressure = (body-bottom - low) / range
;; sell-pressure = (high - body-top) / range
;; body-ratio = body / range
;;
;; Volume acceleration — pre-computed on Candle.
;; volume / volume-sma-20. Log-encoded because ratios.

(define (encode-flow-facts [candle : Candle]
                           [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((range     (- (:high candle) (:low candle)))
         (body-top  (max (:close candle) (:open candle)))
         (body-bot  (min (:close candle) (:open candle)))
         (body      (- body-top body-bot))
         (facts     (list
                      ;; MFI — normalized to [0, 1]
                      (Linear "mfi" (/ (:mfi candle) 100.0) 1.0)

                      ;; OBV slope — signed scalar
                      (Linear "obv-slope" (:obv-slope-12 candle) 1.0)

                      ;; Volume acceleration — ratio, log-encoded
                      (Log "vol-accel" (max (:vol-accel candle) 0.001)))))

    ;; VWAP distance — window-dependent
    (let ((vwap-dist (vwap-distance candles)))
      (let ((facts (if vwap-dist
                     (append facts (list (Linear "vwap-dist" vwap-dist 0.1)))
                     facts)))

        ;; Buying/selling pressure — only when range is meaningful
        (if (> range 1e-10)
          (append facts
            (list (Linear "buy-pressure" (/ (- body-bot (:low candle)) range) 1.0)
                  (Linear "sell-pressure" (/ (- (:high candle) body-top) range) 1.0)
                  (Linear "body-ratio" (/ body range) 1.0)))
          facts)))))

;; OBV divergence: OBV direction disagrees with price direction.
;; Returns a fact if divergence is detected — the magnitude is the
;; OBV slope (how strongly volume disagrees with price).
(define (obv-divergence-fact [candle : Candle]
                             [candles : Vec<Candle>])
  : Option<ThoughtAST>
  (let* ((obv-sign  (signum (:obv-slope-12 candle)))
         (n         (len candles))
         (price-dir (if (>= n 12)
                      (signum (- (:close candle)
                                 (:close (nth candles (- n 12)))))
                      (if (>= n 2)
                        (signum (- (:close candle)
                                   (:close (first candles))))
                        0.0))))
    (if (and (!= obv-sign 0.0)
             (!= price-dir 0.0)
             (!= obv-sign price-dir))
      (Some (Bind (Atom "obv-divergence")
                  (Linear "obv-slope" (:obv-slope-12 candle) 1.0)))
      None)))

;; VWAP distance: how far is price from volume-weighted average?
;; Signed: positive = above VWAP, negative = below.
(define (vwap-distance [candles : Vec<Candle>])
  : Option<f64>
  (if (empty? candles)
    None
    (let* ((cum-vol-price (fold-left (lambda (acc c)
                            (+ acc (* (/ (+ (:high c) (:low c) (:close c)) 3.0)
                                      (:volume c))))
                          0.0 candles))
           (cum-vol      (fold-left (lambda (acc c) (+ acc (:volume c)))
                          0.0 candles)))
      (if (< cum-vol 1e-10)
        None
        (let* ((vwap    (/ cum-vol-price cum-vol))
               (current (:close (last candles))))
          (Some (/ (- current vwap) current)))))))
