;; persistence.wat — Hurst, autocorrelation, ADX
;;
;; Depends on: candle
;; Domain: market (MarketLens :regime, paired with regime.wat)
;;
;; Properties of the price series. Not direction — character.
;; "Is this market trending or mean-reverting? Persistent or random?"
;; Hurst and autocorrelation are pre-computed on the enriched Candle
;; by the IndicatorBank (from close-buf-48).

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; Hurst exponent — pre-computed on Candle.
;; H > 0.5: persistent (trends continue).
;; H < 0.5: anti-persistent (mean-reverting). H = 0.5: random walk.
;; Range [0, 1]. Linear-encoded with scale 1.0.
;;
;; Lag-1 autocorrelation — pre-computed on Candle.
;; Positive: momentum. Negative: mean-reversion.
;; Range [-1, 1]. Linear-encoded with scale 1.0. Signed.
;;
;; ADX — pre-computed on Candle. Range [0, 100].
;; Normalized to [0, 1]. Measures trend strength, not direction.

(define (encode-persistence-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ADX — normalized to [0, 1]
    (Linear "adx" (/ (:adx candle) 100.0) 1.0)
    ;; Hurst exponent — pre-computed on Candle
    (Linear "hurst" (clamp (:hurst candle) 0.0 1.0) 1.0)
    ;; Lag-1 autocorrelation — pre-computed on Candle
    (Linear "autocorr" (:autocorrelation candle) 1.0)))
