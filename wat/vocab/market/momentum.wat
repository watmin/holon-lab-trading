;; vocab/market/momentum.wat — SMA-relative, MACD triplet, CCI, DI-spread
;; Depends on: candle
;; MarketLens :momentum uses this.

(require primitives)
(require candle)

;; Momentum facts — directional pressure and trend strength.
(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        ;; SMA relative distances — signed percentage
        (close-sma20 (if (= (:sma20 c) 0.0) 0.0
                       (/ (- close (:sma20 c)) (:sma20 c))))
        (close-sma50 (if (= (:sma50 c) 0.0) 0.0
                       (/ (- close (:sma50 c)) (:sma50 c))))
        (close-sma200 (if (= (:sma200 c) 0.0) 0.0
                        (/ (- close (:sma200 c)) (:sma200 c))))
        ;; SMA stack — the structure of the averages
        (sma20-sma50 (if (= (:sma50 c) 0.0) 0.0
                       (/ (- (:sma20 c) (:sma50 c)) (:sma50 c))))
        (sma50-sma200 (if (= (:sma200 c) 0.0) 0.0
                        (/ (- (:sma50 c) (:sma200 c)) (:sma200 c))))
        ;; DI spread — signed. Positive = bullish trend.
        (di-spread (- (:plus-di c) (:minus-di c)))
        (di-spread-normalized (/ di-spread 100.0)))
    (list
      ;; Close relative to SMAs — signed distances
      (Linear "close-sma20" close-sma20 0.1)
      (Linear "close-sma50" close-sma50 0.1)
      (Linear "close-sma200" close-sma200 0.1)
      ;; SMA stack — relative distances between averages
      (Linear "sma20-sma50" sma20-sma50 0.1)
      (Linear "sma50-sma200" sma50-sma200 0.1)
      ;; MACD triplet — the full signal
      (Linear "macd" (:macd c) 100.0)
      (Linear "macd-signal" (:macd-signal c) 100.0)
      (Linear "macd-hist" (:macd-hist c) 100.0)
      ;; CCI — directional strength
      (Linear "cci" (:cci c) 200.0)
      ;; DI spread — bullish/bearish trend strength
      (Linear "di-spread" di-spread-normalized 1.0))))
