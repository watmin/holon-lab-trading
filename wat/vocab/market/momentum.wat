;; vocab/market/momentum.wat — SMA-relative, MACD triplet, CCI, DI-spread
;; Depends on: candle
;; MarketLens :momentum selects this module.

(require primitives)
(require candle)

(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c)))
    (list
      ;; SMA-relative positions — signed distance from close to SMA, as fraction
      (Linear "close-sma20" (if (= (:sma20 c) 0.0) 0.0 (/ (- close (:sma20 c)) (:sma20 c))) 0.1)
      (Linear "close-sma50" (if (= (:sma50 c) 0.0) 0.0 (/ (- close (:sma50 c)) (:sma50 c))) 0.1)
      (Linear "close-sma200" (if (= (:sma200 c) 0.0) 0.0 (/ (- close (:sma200 c)) (:sma200 c))) 0.2)

      ;; SMA stack — relative spacing
      (Linear "sma20-sma50" (if (= (:sma50 c) 0.0) 0.0 (/ (- (:sma20 c) (:sma50 c)) (:sma50 c))) 0.1)
      (Linear "sma50-sma200" (if (= (:sma200 c) 0.0) 0.0 (/ (- (:sma50 c) (:sma200 c)) (:sma200 c))) 0.1)

      ;; MACD triplet — the three MACD values
      (Linear "macd" (:macd c) 0.01)
      (Linear "macd-signal" (:macd-signal c) 0.01)
      (Linear "macd-hist" (:macd-hist c) 0.005)

      ;; CCI — normalized
      (Linear "cci" (/ (:cci c) 200.0) 1.0)

      ;; DI spread — directional indicator difference
      (Linear "di-spread" (/ (- (:plus-di c) (:minus-di c)) 100.0) 1.0))))
