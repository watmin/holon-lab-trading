;; vocab/market/persistence.wat — Hurst, autocorrelation, ADX.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; The persistence family: does the market remember its past?

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-persistence-facts ────────────────────────────────────────────

(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Hurst exponent — [0, 1]. 0.5 = random walk, >0.5 = persistent, <0.5 = anti-persistent
    (Linear "hurst" (:hurst c) 1.0)

    ;; Autocorrelation — signed, [-1, 1]. Positive = trending, negative = reverting
    (Linear "autocorrelation" (:autocorrelation c) 1.0)

    ;; ADX — [0, 100] normalized to [0, 1]. Trend strength, not direction.
    (Linear "adx" (/ (:adx c) 100.0) 1.0)

    ;; DI spread — signed. plus-di - minus-di, directional pressure.
    (Linear "di-spread" (/ (- (:plus-di c) (:minus-di c)) 100.0) 1.0)))
