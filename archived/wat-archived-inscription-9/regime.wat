;; vocab/market/regime.wat — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
;; Depends on: candle
;; MarketLens :regime uses this module.

(require primitives)
(require candle)

(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; KAMA Efficiency Ratio — [0, 1], 1 = perfectly efficient
    (Linear "kama-er" (:kama-er c) 1.0)
    ;; Choppiness Index — [0, 100] normalized, high = choppy
    (Linear "choppiness" (/ (:choppiness c) 100.0) 1.0)
    ;; DFA alpha — scaling exponent
    (Linear "dfa-alpha" (:dfa-alpha c) 2.0)
    ;; Variance ratio — 1.0 = random walk
    (Linear "variance-ratio" (:variance-ratio c) 2.0)
    ;; Entropy rate — conditional entropy of returns
    (Linear "entropy-rate" (:entropy-rate c) 2.0)
    ;; Aroon up/down — [0, 100] normalized
    (Linear "aroon-up" (/ (:aroon-up c) 100.0) 1.0)
    (Linear "aroon-down" (/ (:aroon-down c) 100.0) 1.0)
    ;; Fractal dimension — 1.0 trending, 2.0 noisy
    (Linear "fractal-dim" (:fractal-dim c) 2.0)))
