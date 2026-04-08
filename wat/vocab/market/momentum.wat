;; momentum.wat — CCI, SMA-relative facts, MACD + MACD signal + MACD hist
;;
;; Depends on: candle
;; Domain: market (MarketLens :momentum)
;;
;; Commodity Channel Index: how far is the typical price from its
;; moving average, in units of mean deviation? Unbounded.
;; Positive = above average. Negative = below. Magnitude = extremity.
;;
;; SMA-relative facts: the guide's own example. Close relative to each
;; SMA as a signed fraction of close: (close - smaX) / close.
;; These are the trend's backbone — when close crosses an SMA, the sign
;; flips. The magnitude says how far. encode-linear with scale 0.1
;; (a 10% deviation from SMA saturates — that is extreme for BTC).
;;
;; MACD: the full MACD triplet. Not just the histogram.
;; macd and macd-signal are normalized by close (they are absolute
;; differences of EMAs). macd-hist is macd - macd-signal, also
;; normalized by close.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

(define (encode-momentum-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((close (:close candle))
         (safe-close (max close 1.0))

         ;; CCI — normalized by dividing by 200, clamped to [-1, 1]
         (cci-norm (clamp (/ (:cci candle) 200.0) -1.0 1.0))

         ;; SMA-relative facts: (close - smaX) / close
         (close-sma20  (/ (- close (:sma20 candle)) safe-close))
         (close-sma50  (/ (- close (:sma50 candle)) safe-close))
         (close-sma200 (/ (- close (:sma200 candle)) safe-close))

         ;; MACD triplet — normalized by close
         (macd-norm        (/ (:macd candle) safe-close))
         (macd-signal-norm (/ (:macd-signal candle) safe-close))
         (macd-hist-norm   (/ (:macd-hist candle) safe-close)))

    (list
      (Linear "cci" cci-norm 1.0)

      ;; SMA-relative — the guide's example
      (Linear "close-sma20" close-sma20 0.1)
      (Linear "close-sma50" close-sma50 0.1)
      (Linear "close-sma200" close-sma200 0.1)

      ;; MACD triplet
      (Linear "macd" macd-norm 0.01)
      (Linear "macd-signal" macd-signal-norm 0.01)
      (Linear "macd-hist" macd-hist-norm 0.01))))
