;; vocab/market/momentum.wat — SMA-relative, MACD triplet, CCI, DI-spread
;; Depends on: candle
;; MarketLens :momentum uses this module.

(require primitives)
(require candle)

(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (sma20 (:sma20 c))
        (sma50 (:sma50 c))
        (sma200 (:sma200 c)))
    (list
      ;; SMA-relative: signed distance as fraction
      (Linear "close-sma20" (if (= sma20 0.0) 0.0 (/ (- close sma20) sma20)) 0.1)
      (Linear "close-sma50" (if (= sma50 0.0) 0.0 (/ (- close sma50) sma50)) 0.1)
      (Linear "close-sma200" (if (= sma200 0.0) 0.0 (/ (- close sma200) sma200)) 0.1)
      ;; SMA stack: relative positions between averages
      (Linear "sma20-sma50" (if (= sma50 0.0) 0.0 (/ (- sma20 sma50) sma50)) 0.1)
      (Linear "sma50-sma200" (if (= sma200 0.0) 0.0 (/ (- sma50 sma200) sma200)) 0.1)
      ;; MACD triplet
      (Linear "macd" (:macd c) 0.01)
      (Linear "macd-signal" (:macd-signal c) 0.01)
      (Linear "macd-hist" (:macd-hist c) 0.01)
      ;; DI spread — signed: positive = bullish, negative = bearish
      (Linear "di-spread" (- (:plus-di c) (:minus-di c)) 100.0)
      ;; CCI as linear with wider scale
      (Linear "cci" (:cci c) 300.0))))
