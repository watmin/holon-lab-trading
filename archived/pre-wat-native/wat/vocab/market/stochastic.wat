;; ── vocab/market/stochastic.wat ──────────────────────────────────
;;
;; %K/%D spread and crosses. Pure function: candle in, ASTs out.
;; atoms: stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta
;; Depends on: candle.

(require candle)

(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((k (/ (:stoch-k c) 100.0))
        (d (/ (:stoch-d c) 100.0)))
    (list
      ;; Stochastic %K: [0, 1]. Where price is in recent range.
      '(Linear "stoch-k" k 1.0)

      ;; Stochastic %D: [0, 1]. Smoothed %K.
      '(Linear "stoch-d" d 1.0)

      ;; K-D spread: signed. Positive = %K above %D (bullish momentum).
      ;; [-1, 1] range.
      '(Linear "stoch-kd-spread" (- k d) 1.0)

      ;; Stochastic cross delta: pre-computed on candle. Rate of change
      ;; of K-D spread. Signed. [-1, 1].
      '(Linear "stoch-cross-delta"
               (clamp (:stoch-cross-delta c) -1.0 1.0)
               1.0))))
