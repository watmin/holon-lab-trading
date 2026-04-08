;; timeframe.wat — 1h/4h structure, narrative, inter-timeframe agreement
;;
;; Depends on: candle
;; Domain: market (MarketLens :narrative)
;;
;; Multi-timeframe analysis. 5-minute candles aggregate into 1h and 4h.
;; All values are pre-computed fields on the enriched Candle.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; 1h/4h body ratio — how decisive is the higher-timeframe candle?
;; Range [0, 1]. Pre-computed on Candle.
;;
;; 1h/4h range position — where is price in the higher-timeframe range?
;; Computed from tf-Xh-high and tf-Xh-low. Range [0, 1].
;;
;; 1h/4h return — signed. How much has the higher-timeframe moved?
;; Linear-encoded with scale 0.05 (5% is a large hourly move for BTC).
;;
;; tf-agreement — pre-computed on Candle. Inter-timeframe agreement score.
;; 5m/1h/4h direction alignment. High = all timeframes agree. Low = conflict.
;; Linear-encoded with scale 1.0.

(define (encode-timeframe-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((facts (list))

         ;; 1h structure
         (h-range (- (:tf-1h-high candle) (:tf-1h-low candle)))
         (facts (append facts
                  (list (Linear "tf-1h-body" (clamp (:tf-1h-body candle) 0.0 1.0) 1.0))))
         (facts (if (> h-range 1e-10)
                  (let ((pos (/ (- (:close candle) (:tf-1h-low candle)) h-range)))
                    (append facts (list (Linear "tf-1h-range-pos" (clamp pos 0.0 1.0) 1.0))))
                  facts))

         ;; 4h structure
         (h4-range (- (:tf-4h-high candle) (:tf-4h-low candle)))
         (facts (append facts
                  (list (Linear "tf-4h-body" (clamp (:tf-4h-body candle) 0.0 1.0) 1.0))))
         (facts (if (> h4-range 1e-10)
                  (let ((pos (/ (- (:close candle) (:tf-4h-low candle)) h4-range)))
                    (append facts (list (Linear "tf-4h-range-pos" (clamp pos 0.0 1.0) 1.0))))
                  facts))

         ;; 1h/4h returns — signed, linear
         (facts (if (> (abs (:tf-1h-ret candle)) 1e-10)
                  (append facts (list (Linear "tf-1h-ret" (:tf-1h-ret candle) 0.05)))
                  facts))
         (facts (if (> (abs (:tf-4h-ret candle)) 1e-10)
                  (append facts (list (Linear "tf-4h-ret" (:tf-4h-ret candle) 0.05)))
                  facts))

         ;; Inter-timeframe agreement — how aligned are 5m/1h/4h?
         (facts (append facts
                  (list (Linear "tf-agreement" (:tf-agreement candle) 1.0)))))

    facts))
