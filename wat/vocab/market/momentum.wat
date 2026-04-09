;; vocab/market/momentum.wat — SMA-relative, MACD triplet, CCI, DI-spread
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :momentum

(require primitives)
(require candle)

(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (sma20 (:sma20 c))
        (sma50 (:sma50 c))
        (sma200 (:sma200 c))
        (macd-val (:macd c))
        (macd-sig (:macd-signal c))
        (macd-hist (:macd-hist c))
        (cci-norm (/ (:cci c) 400.0))
        (plus-di (/ (:plus-di c) 100.0))
        (minus-di (/ (:minus-di c) 100.0)))
    (list
      ;; Close relative to SMAs — signed distance
      (Linear "close-sma20" (if (= sma20 0.0) 0.0 (/ (- close sma20) sma20)) 0.1)
      (Linear "close-sma50" (if (= sma50 0.0) 0.0 (/ (- close sma50) sma50)) 0.1)
      (Linear "close-sma200" (if (= sma200 0.0) 0.0 (/ (- close sma200) sma200)) 0.1)

      ;; SMA stack — relative distances between SMAs
      (Linear "sma20-sma50" (if (= sma50 0.0) 0.0 (/ (- sma20 sma50) sma50)) 0.1)
      (Linear "sma50-sma200" (if (= sma200 0.0) 0.0 (/ (- sma50 sma200) sma200)) 0.1)

      ;; MACD triplet — the MACD line, signal line, and histogram
      (Linear "macd" (/ macd-val (max close 1.0)) 0.01)
      (Linear "macd-signal" (/ macd-sig (max close 1.0)) 0.01)
      (Linear "macd-hist" (/ macd-hist (max close 1.0)) 0.01)

      ;; CCI — centered oscillator
      (Linear "cci" cci-norm 1.0)

      ;; DI spread — directional movement spread. Positive = bullish
      (Linear "di-spread" (- plus-di minus-di) 1.0))))
