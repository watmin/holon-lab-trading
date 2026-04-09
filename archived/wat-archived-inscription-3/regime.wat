;; vocab/market/regime.wat — KAMA-ER, choppiness, DFA, variance ratio,
;;   entropy, Aroon, fractal dim.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; regime-bb-width — the regime family's Bollinger width fact.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-regime-facts ─────────────────────────────────────────────────

(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; KAMA Efficiency Ratio — [0, 1]. High = trending, low = choppy.
    (Linear "kama-er" (:kama-er c) 1.0)

    ;; Choppiness Index — [0, 100] normalized to [0, 1].
    (Linear "choppiness" (/ (:choppiness c) 100.0) 1.0)

    ;; DFA alpha — ~0.5 random walk, >0.5 persistent, <0.5 anti-persistent
    (Linear "dfa-alpha" (:dfa-alpha c) 2.0)

    ;; Variance ratio — ~1.0 random walk, >1 trending, <1 mean-reverting
    (Log "variance-ratio" (:variance-ratio c))

    ;; Entropy rate — higher = more random, lower = more structured
    (Linear "entropy-rate" (:entropy-rate c) 1.0)

    ;; Aroon — [0, 100] each, normalized. Signed spread for direction.
    (Linear "aroon-up" (/ (:aroon-up c) 100.0) 1.0)
    (Linear "aroon-down" (/ (:aroon-down c) 100.0) 1.0)

    ;; Fractal dimension — [1.0, 2.0]. 1.0 trending, 2.0 noisy.
    (Linear "fractal-dim" (:fractal-dim c) 2.0)

    ;; Bollinger width — regime indicator of volatility expansion/contraction
    (Log "regime-bb-width" (:bb-width c))))
