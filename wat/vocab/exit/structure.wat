;; structure.wat — trend consistency, ADX strength
;;
;; Depends on: candle
;; Domain: exit (ExitLens :structure)
;;
;; Trend structure determines whether the market is orderly enough
;; for tight stops or chaotic enough to need wide ones.

(require primitives)
(require candle)

;; Trend consistency — pre-computed on Candle at three scales.
;; What fraction of recent candles closed in the same direction?
;; Range [0, 1]. High = trending. Low = choppy.
;;
;; ADX — pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;; Measures trend strength. Strong trend = tighter trail possible.
;;
;; DI spread: (plus-di - minus-di) / 100. Signed.
;; Direction of the trend. Positive = bullish trend. Negative = bearish.

(define (encode-exit-structure-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    (Linear "exit-trend-consistency-6" (:trend-consistency-6 candle) 1.0)
    (Linear "exit-trend-consistency-12" (:trend-consistency-12 candle) 1.0)
    (Linear "exit-trend-consistency-24" (:trend-consistency-24 candle) 1.0)
    (Linear "exit-adx" (/ (:adx candle) 100.0) 1.0)
    (Linear "exit-di-spread"
      (/ (- (:plus-di candle) (:minus-di candle)) 100.0) 1.0)))
