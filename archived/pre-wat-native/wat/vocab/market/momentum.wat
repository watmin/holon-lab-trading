;; ── vocab/market/momentum.wat ────────────────────────────────────
;;
;; Trend-relative, MACD, DI. Pure function: candle in, ASTs out.
;; atoms: close-sma20, close-sma50, close-sma200, macd-hist, di-spread, atr-ratio
;; Depends on: candle.

(require candle)

(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Close relative to SMA20: signed percentage distance.
    ;; Positive = above, negative = below.
    '(Linear "close-sma20"
             (/ (- (:close c) (:sma20 c)) (:close c))
             0.1)

    ;; Close relative to SMA50: signed percentage distance.
    '(Linear "close-sma50"
             (/ (- (:close c) (:sma50 c)) (:close c))
             0.1)

    ;; Close relative to SMA200: signed percentage distance.
    '(Linear "close-sma200"
             (/ (- (:close c) (:sma200 c)) (:close c))
             0.1)

    ;; MACD histogram: signed, unbounded. Small values.
    ;; Normalize by close to make scale-independent.
    '(Linear "macd-hist" (/ (:macd-hist c) (:close c)) 0.01)

    ;; DI spread: plus-DI minus minus-DI. Signed, [-100, 100].
    ;; Normalize to [-1, 1].
    '(Linear "di-spread"
             (/ (- (:plus-di c) (:minus-di c)) 100.0)
             1.0)

    ;; ATR ratio: ATR / close. Unbounded positive ratio. Log-encoded.
    '(Log "atr-ratio" (max 0.001 (:atr-r c)))))
