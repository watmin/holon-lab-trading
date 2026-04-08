;; regime.wat — regime character, trend structure, volatility shape
;;
;; Depends on: candle
;; Domain: market (MarketLens :regime)
;;
;; Abstract properties of the price series: is it trending or choppy?
;; Orderly or chaotic? Efficient or noisy?
;; Persistence facts (hurst, autocorr, adx) live in persistence.wat.
;; All values are pre-computed fields on the enriched Candle.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; Trend consistency — pre-computed on Candle at three scales.
;; What fraction of recent candles closed in the same direction?
;; Range [0, 1]. High = trending. Low = choppy.
;;
;; Range position — pre-computed on Candle at three scales.
;; Where is price in the recent [low, high] range?
;; Range [0, 1]. 0.0 = at the low. 1.0 = at the high.
;;
;; BB width — pre-computed on Candle. Band width as fraction of price.
;; Log-encoded. Wider = more volatile.
;;
;; KAMA Efficiency Ratio — pre-computed on Candle. [0, 1].
;; 1.0 = perfectly efficient (trending). 0.0 = perfectly noisy.
;;
;; Choppiness Index — pre-computed on Candle. [0, 100]. Normalized to [0, 1].
;; High = choppy. Low = trending. Complement of KAMA-ER but different math.
;;
;; DFA alpha — pre-computed on Candle. Detrended Fluctuation Analysis exponent.
;; < 0.5: anti-persistent. = 0.5: random walk. > 0.5: persistent. > 1.0: non-stationary.
;; Linear-encoded with scale 2.0 to cover the meaningful range.
;;
;; Variance ratio — pre-computed on Candle.
;; = 1.0: random walk. > 1.0: trending. < 1.0: mean-reverting.
;; Log-encoded because ratio.
;;
;; Entropy rate — pre-computed on Candle.
;; High entropy = unpredictable. Low entropy = structured.
;; Linear-encoded with scale 1.0 (normalized conditional entropy).
;;
;; Aroon up/down — pre-computed on Candle. [0, 100]. Normalized to [0, 1].
;; How recent was the highest high (up) or lowest low (down)?
;; High Aroon up + low Aroon down = strong uptrend.
;;
;; Fractal dimension — pre-computed on Candle.
;; 1.0 = trending (smooth). 2.0 = noisy (space-filling).
;; Linear-encoded with scale 2.0.

(define (encode-regime-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Trend consistency at three scales
    (Linear "trend-consistency-6" (:trend-consistency-6 candle) 1.0)
    (Linear "trend-consistency-12" (:trend-consistency-12 candle) 1.0)
    (Linear "trend-consistency-24" (:trend-consistency-24 candle) 1.0)

    ;; Range position at three scales
    (Linear "range-pos-12" (:range-pos-12 candle) 1.0)
    (Linear "range-pos-24" (:range-pos-24 candle) 1.0)
    (Linear "range-pos-48" (:range-pos-48 candle) 1.0)

    ;; Volatility character
    (Log "regime-bb-width" (max (:bb-width candle) 0.0001))

    ;; Regime indicators — efficiency and choppiness
    (Linear "kama-er" (:kama-er candle) 1.0)
    (Linear "choppiness" (/ (:choppiness candle) 100.0) 1.0)

    ;; Fractal scaling — DFA and variance ratio
    (Linear "dfa-alpha" (:dfa-alpha candle) 2.0)
    (Log "variance-ratio" (max (:variance-ratio candle) 0.0001))

    ;; Information content
    (Linear "entropy-rate" (:entropy-rate candle) 1.0)

    ;; Aroon — recency of extremes
    (Linear "aroon-up" (/ (:aroon-up candle) 100.0) 1.0)
    (Linear "aroon-down" (/ (:aroon-down candle) 100.0) 1.0)

    ;; Fractal dimension — geometry of the price path
    (Linear "fractal-dim" (:fractal-dim candle) 2.0)))
