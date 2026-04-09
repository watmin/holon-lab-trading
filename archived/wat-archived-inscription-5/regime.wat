;; vocab/market/regime.wat — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
;; Depends on: candle
;; MarketLens :regime selects this module.

(require primitives)
(require candle)

;; Regime facts — what kind of market is this?
;; No zones. Only scalars. The discriminant learns the boundaries.
(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; KAMA Efficiency Ratio — [0, 1]. 1.0 = perfectly trending.
    (Linear "regime-kama-er" (:kama-er c) 1.0)

    ;; Choppiness Index — [0, 100]. High = choppy, low = trending.
    (Linear "regime-choppiness" (/ (:choppiness c) 100.0) 1.0)

    ;; DFA alpha — exponent. 0.5 = random walk, >0.5 = persistent, <0.5 = anti-persistent.
    (Linear "regime-dfa-alpha" (:dfa-alpha c) 2.0)

    ;; Variance ratio — 1.0 = random walk, >1 = trending, <1 = mean-reverting.
    (Log "regime-variance-ratio" (max 0.01 (:variance-ratio c)))

    ;; Entropy rate — higher = more random, lower = more predictable.
    (Linear "regime-entropy-rate" (:entropy-rate c) 3.0)

    ;; Aroon up — [0, 100]. How recent was the highest high?
    (Linear "regime-aroon-up" (/ (:aroon-up c) 100.0) 1.0)

    ;; Aroon down — [0, 100]. How recent was the lowest low?
    (Linear "regime-aroon-down" (/ (:aroon-down c) 100.0) 1.0)

    ;; Fractal dimension — 1.0 trending, 2.0 noisy.
    (Linear "regime-fractal-dim" (:fractal-dim c) 2.0)))
