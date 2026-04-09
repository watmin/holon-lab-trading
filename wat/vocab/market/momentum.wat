;; momentum.wat — SMA-relative facts, CCI, MACD triplet
;;
;; Depends on: candle (reads: close, sma20, sma50, sma200, cci,
;;                            macd, macd-signal, macd-hist,
;;                            plus-di, minus-di)
;; Market domain. Lens: :momentum, :generalist.
;;
;; SMA-relative: close-sma20, close-sma50, close-sma200.
;; MACD triplet: macd, macd-signal, macd-hist.

(require primitives)

(define (encode-momentum-facts [candle : Candle]) : Vec<ThoughtAST>
  (let ((close (:close candle)))
    (list
      ;; SMA-relative — signed distance as fraction of price
      (Linear "close-sma20"
        (/ (- close (:sma20 candle)) close) 0.1)
      (Linear "close-sma50"
        (/ (- close (:sma50 candle)) close) 0.1)
      (Linear "close-sma200"
        (/ (- close (:sma200 candle)) close) 0.1)

      ;; MACD triplet — all signed, small magnitude
      (Linear "macd"        (:macd candle)        0.01)
      (Linear "macd-signal" (:macd-signal candle) 0.01)
      (Linear "macd-hist"   (:macd-hist candle)   0.01)

      ;; CCI — centered around 0, wide range
      (Linear "cci-momentum" (:cci candle) 400.0)

      ;; DMI spread — plus-DI minus minus-DI, signed
      (Linear "di-spread"
        (- (:plus-di candle) (:minus-di candle)) 100.0))))
