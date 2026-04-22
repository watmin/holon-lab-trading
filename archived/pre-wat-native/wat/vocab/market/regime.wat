;; ── vocab/market/regime.wat ──────────────────────────────────────
;;
;; What KIND of market this is. Pure function: candle in, ASTs out.
;; atoms: kama-er, choppiness, dfa-alpha, variance-ratio,
;;        entropy-rate, aroon-up, aroon-down, fractal-dim
;; Depends on: candle.

(require candle)

(define (encode-regime-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; KAMA efficiency ratio: [0, 1]. 1 = perfectly trending, 0 = noise.
    '(Linear "kama-er" (:kama-er c) 1.0)

    ;; Choppiness index: [0, 100]. Normalize to [0, 1].
    ;; High = choppy/sideways. Low = trending.
    '(Linear "choppiness" (/ (:choppiness c) 100.0) 1.0)

    ;; DFA alpha: scaling exponent. ~0.5 = random, >0.5 = persistent, <0.5 = anti-persistent.
    ;; Typically [0, 2]. Linear with scale 2.
    '(Linear "dfa-alpha" (/ (:dfa-alpha c) 2.0) 1.0)

    ;; Variance ratio: ratio of long-horizon to short-horizon variance.
    ;; 1.0 = random walk. Unbounded positive. Log-encoded.
    '(Log "variance-ratio" (max 0.001 (:variance-ratio c)))

    ;; Entropy rate: [0, 1]. Higher = more unpredictable.
    '(Linear "entropy-rate" (:entropy-rate c) 1.0)

    ;; Aroon up: [0, 1]. How recently the highest high occurred.
    ;; Raw aroon is [0, 100]. Normalize.
    '(Linear "aroon-up" (/ (:aroon-up c) 100.0) 1.0)

    ;; Aroon down: [0, 1]. How recently the lowest low occurred.
    '(Linear "aroon-down" (/ (:aroon-down c) 100.0) 1.0)

    ;; Fractal dimension: [1, 2]. 1 = smooth trend, 2 = space-filling noise.
    ;; Normalize: (fd - 1) maps [1,2] to [0,1].
    '(Linear "fractal-dim" (- (:fractal-dim c) 1.0) 1.0)))
