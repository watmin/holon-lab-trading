;; vocab/market/regime.wat — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
;; Depends on: candle
;; MarketLens :regime selects this module.

(require primitives)
(require candle)

(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; KAMA Efficiency Ratio — [0, 1]
    (Linear "kama-er" (:kama-er c) 1.0)

    ;; Choppiness Index — [0, 100] normalized to [0, 1]
    (Linear "choppiness" (/ (:choppiness c) 100.0) 1.0)

    ;; DFA alpha — exponent, typically [0.3, 1.5]
    (Linear "dfa-alpha" (:dfa-alpha c) 2.0)

    ;; Variance ratio — centered at 1.0
    (Linear "variance-ratio" (- (:variance-ratio c) 1.0) 1.0)

    ;; Entropy rate — [0, 1]
    (Linear "entropy-rate" (:entropy-rate c) 1.0)

    ;; Aroon up/down — [0, 100] normalized to [0, 1]
    (Linear "aroon-up" (/ (:aroon-up c) 100.0) 1.0)
    (Linear "aroon-down" (/ (:aroon-down c) 100.0) 1.0)

    ;; Fractal dimension — [1.0, 2.0] centered at 1.5
    (Linear "fractal-dim" (- (:fractal-dim c) 1.5) 1.0)))
