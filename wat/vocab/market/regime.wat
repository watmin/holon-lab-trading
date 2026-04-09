;; regime.wat — market regime characterization
;;
;; Depends on: candle (reads: kama-er, choppiness, dfa-alpha, variance-ratio,
;;                            entropy-rate, aroon-up, aroon-down, fractal-dim,
;;                            bb-width, squeeze)
;; Market domain. Lens: :regime, :generalist.
;;
;; All regime atoms prefixed with regime- to avoid collisions.
;; Squeeze as continuous ratio (bb-width / kelt-width), not bool.

(require primitives)

(define (encode-regime-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; KAMA Efficiency Ratio — [0, 1]. 1 = perfectly trending.
    (Linear "regime-kama-er" (:kama-er candle) 1.0)

    ;; Choppiness Index — [0, 100]. High = choppy.
    (Linear "regime-choppiness" (:choppiness candle) 100.0)

    ;; DFA alpha — unbounded positive. ~0.5 = random, >0.5 = persistent.
    (Linear "regime-dfa-alpha" (:dfa-alpha candle) 2.0)

    ;; Variance ratio — ratio around 1.0. >1 = trending, <1 = mean-reverting.
    (Log "regime-variance-ratio" (:variance-ratio candle))

    ;; Entropy rate — unbounded positive. Higher = more random.
    (Linear "regime-entropy" (:entropy-rate candle) 2.0)

    ;; Aroon — [0, 100] each
    (Linear "regime-aroon-up"   (:aroon-up candle)   100.0)
    (Linear "regime-aroon-down" (:aroon-down candle)  100.0)

    ;; Fractal dimension — ~[1.0, 2.0]. 1 = trending, 2 = noisy.
    (Linear "regime-fractal-dim" (:fractal-dim candle) 2.0)

    ;; Bollinger bandwidth — unbounded positive ratio
    (Log "regime-bb-width" (:bb-width candle))

    ;; Squeeze — continuous ratio: bb-width / kelt-width
    (Log "regime-squeeze" (:squeeze candle))))
