;; ── vocab/exit/timing.wat ────────────────────────────────────────
;;
;; Momentum state and reversal signals. Exit observers use these
;; to time entries and exits. Pure function: candle in, ASTs out.
;; atoms: rsi, stoch-k, stoch-kd-spread, macd-hist, cci
;; Depends on: candle.

(require candle)

(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI: [0, 1] — Wilder's formula. Naturally bounded.
    '(Linear "rsi" (:rsi c) 1.0)

    ;; Stochastic %K: [0, 1] — where in the recent range.
    '(Linear "stoch-k" (/ (:stoch-k c) 100.0) 1.0)

    ;; Stochastic %K - %D spread: signed. Positive = %K above %D.
    ;; Normalize to [-1, 1].
    '(Linear "stoch-kd-spread"
             (/ (- (:stoch-k c) (:stoch-d c)) 100.0)
             1.0)

    ;; MACD histogram: signed, unbounded. Normalize by close.
    '(Linear "macd-hist" (/ (:macd-hist c) (:close c)) 0.01)

    ;; CCI: unbounded but typically [-300, 300]. Normalize.
    '(Linear "cci" (/ (:cci c) 300.0) 1.0)))
