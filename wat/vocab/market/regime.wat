;; vocab/market/regime.wat — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :regime

(require primitives)
(require candle)

(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((kama-er (:kama-er c))
        (chop-norm (/ (:choppiness c) 100.0))
        (dfa (:dfa-alpha c))
        (vr (:variance-ratio c))
        (entropy (:entropy-rate c))
        (aroon-up-norm (/ (:aroon-up c) 100.0))
        (aroon-down-norm (/ (:aroon-down c) 100.0))
        (fractal (:fractal-dim c)))
    (list
      ;; KAMA Efficiency Ratio — [0, 1]. 1.0 = perfectly trending
      (Linear "kama-er" kama-er 1.0)

      ;; Choppiness — [0, 100] normalized. High = choppy, low = trending
      (Linear "choppiness" chop-norm 1.0)

      ;; DFA alpha — exponent. >0.5 persistent, <0.5 anti-persistent
      (Linear "dfa-alpha" dfa 2.0)

      ;; Variance ratio — 1.0 = random walk. Deviation = structure
      (Linear "variance-ratio" vr 2.0)

      ;; Entropy rate — conditional entropy. Low = predictable
      (Linear "entropy-rate" entropy 2.0)

      ;; Aroon up/down — [0, 100] normalized
      (Linear "aroon-up" aroon-up-norm 1.0)
      (Linear "aroon-down" aroon-down-norm 1.0)

      ;; Aroon spread — signed. Positive = bullish trend
      (Linear "aroon-spread" (- aroon-up-norm aroon-down-norm) 1.0)

      ;; Fractal dimension — [1.0, 2.0]. 1.0 = trending, 2.0 = noisy
      (Linear "fractal-dim" fractal 2.0))))
