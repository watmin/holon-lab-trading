;; volatility.wat — ATR regime, ATR ratio, squeeze state
;;
;; Depends on: candle
;; Domain: exit (ExitLens :volatility)
;;
;; Volatility determines distance. High ATR = wider stops.
;; The exit observer learns the relationship between volatility
;; state and optimal exit distance.

(require primitives)
(require candle)

;; ATR ratio (atr-r) — pre-computed on Candle. ATR / close.
;; Log-encoded because ratio. The difference between 1% and 2% ATR
;; matters more than 10% and 11%.
;;
;; ATR rate of change — how is volatility changing?
;; Pre-computed on Candle at 6 and 12 period scales. Signed.
;; Positive = expanding. Negative = contracting.
;;
;; Squeeze state — from Keltner/BB relationship. Pre-computed.
;; 1.0 = squeeze active (volatility compressed). 0.0 = not.
;;
;; BB width — band width as fraction of price. Log-encoded.

(define (encode-exit-volatility-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    (Log "atr-ratio" (max (:atr-r candle) 0.0001))
    (Linear "atr-roc-6" (:atr-roc-6 candle) 1.0)
    (Linear "atr-roc-12" (:atr-roc-12 candle) 1.0)
    (Linear "exit-squeeze" (if (:squeeze candle) 1.0 0.0) 1.0)
    (Log "exit-bb-width" (max (:bb-width candle) 0.0001))))
