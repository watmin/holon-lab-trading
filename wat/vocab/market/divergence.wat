;; divergence.wat — RSI divergence
;;
;; Depends on: candle
;; Domain: market (MarketLens :narrative)
;;
;; Structural divergence: price and RSI disagree at turning points.
;; Divergence magnitudes are pre-computed by the IndicatorBank via
;; PELT peak detection on aligned price/RSI buffers.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; rsi-divergence-bull — bullish divergence magnitude.
;; Price made a lower low but RSI made a higher low. Positive = divergence present.
;; 0.0 = no divergence. Larger = stronger signal.
;; Log-encoded because magnitude — the difference between 0.01 and 0.02 matters
;; more than 0.10 and 0.11.
;;
;; rsi-divergence-bear — bearish divergence magnitude.
;; Price made a higher high but RSI made a lower high. Positive = divergence present.
;; Same encoding logic.

(define (encode-divergence-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let ((bull (:rsi-divergence-bull candle))
        (bear (:rsi-divergence-bear candle)))
    ;; Only emit when divergence is present — 0.0 means no divergence
    (let* ((facts (list))
           (facts (if (> bull 0.0)
                    (append facts (list (Log "rsi-div-bull" bull)))
                    facts))
           (facts (if (> bear 0.0)
                    (append facts (list (Log "rsi-div-bear" bear)))
                    facts)))
      facts)))
