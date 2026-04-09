;; vocab/market/momentum.wat — SMA-relative, MACD triplet, CCI, DI-spread
;; Depends on: candle
;; MarketLens :momentum selects this module.

(require primitives)
(require candle)

;; Momentum facts — where is price relative to its averages?
;; All signed distances. The sign IS the direction.
(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c)))
    (list
      ;; Close relative to SMA20 — signed percentage distance.
      (Linear "close-sma20"
        (if (= (:sma20 c) 0.0) 0.0
          (/ (- close (:sma20 c)) (:sma20 c)))
        0.1)

      ;; Close relative to SMA50
      (Linear "close-sma50"
        (if (= (:sma50 c) 0.0) 0.0
          (/ (- close (:sma50 c)) (:sma50 c)))
        0.1)

      ;; Close relative to SMA200
      (Linear "close-sma200"
        (if (= (:sma200 c) 0.0) 0.0
          (/ (- close (:sma200 c)) (:sma200 c)))
        0.1)

      ;; SMA stack — relative distances between averages
      (Linear "sma20-sma50"
        (if (= (:sma50 c) 0.0) 0.0
          (/ (- (:sma20 c) (:sma50 c)) (:sma50 c)))
        0.1)

      (Linear "sma50-sma200"
        (if (= (:sma200 c) 0.0) 0.0
          (/ (- (:sma50 c) (:sma200 c)) (:sma200 c)))
        0.1)

      ;; MACD triplet
      (Linear "macd" (:macd c) 0.01)
      (Linear "macd-signal" (:macd-signal c) 0.01)
      (Linear "macd-hist" (:macd-hist c) 0.01)

      ;; CCI — signed, centered around 0
      (Linear "cci" (/ (:cci c) 300.0) 1.0)

      ;; DI spread — +DI minus -DI. Positive = bullish dominance.
      (Linear "di-spread"
        (/ (- (:plus-di c) (:minus-di c)) 100.0)
        1.0)

      ;; ATR ratio — volatility relative to price. Log for ratios.
      (Log "atr-ratio" (max 0.0001 (:atr-r c))))))
