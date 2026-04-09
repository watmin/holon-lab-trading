;; vocab/market/regime.wat — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
;; Depends on: candle
;; MarketLens :regime uses this.

(require primitives)
(require candle)

;; Regime facts — what kind of market is this right now?
(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((chop-normalized (/ (:choppiness c) 100.0))
        (aroon-up-normalized (/ (:aroon-up c) 100.0))
        (aroon-down-normalized (/ (:aroon-down c) 100.0)))
    (list
      ;; KAMA Efficiency Ratio — [0, 1]. 1 = trending, 0 = noisy.
      (Linear "kama-er" (:kama-er c) 1.0)
      ;; Choppiness Index — normalized [0, 1]. High = choppy, low = trending.
      (Linear "choppiness" chop-normalized 1.0)
      ;; DFA-alpha — >0.5 persistent, <0.5 anti-persistent
      (Linear "dfa-alpha" (:dfa-alpha c) 1.0)
      ;; Variance ratio — 1.0 = random walk. Deviation means structure.
      (Linear "variance-ratio" (:variance-ratio c) 2.0)
      ;; Entropy rate — [0, 1]. High = unpredictable. Low = patterned.
      (Linear "entropy-rate" (:entropy-rate c) 1.0)
      ;; Aroon up/down — normalized [0, 1]. How recent was the extreme?
      (Linear "aroon-up" aroon-up-normalized 1.0)
      (Linear "aroon-down" aroon-down-normalized 1.0)
      ;; Fractal dimension — 1.0 trending, 2.0 noisy.
      (Linear "fractal-dim" (:fractal-dim c) 2.0))))
