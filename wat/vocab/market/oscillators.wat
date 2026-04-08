;; oscillators.wat — Williams %R, StochRSI, multi-ROC, RSI
;;
;; Depends on: candle
;; Domain: market (MarketLens :momentum)
;;
;; Every value is a scalar. No zones. The discriminant learns
;; where the boundaries are.
;;
;; RSI lives here — in oscillators, the momentum lens. Not duplicated
;; elsewhere. RSI IS an oscillator.
;;
;; NOTE: UltOsc (Ultimate Oscillator) is not on the Candle struct.
;; If added later, encode as Linear with scale 1.0 after normalizing [0,100]->[0,1].

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; Williams %R — pre-computed on Candle. Range [-100, 0].
;; Normalized to [0, 1]: (wr + 100) / 100.
;;
;; StochRSI — stoch-k used as an RSI-like oscillator.
;; Pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;;
;; RSI — pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;; The discriminant learns what "overbought" means for this asset.
;;
;; Multi-ROC — rate of change at 1, 3, 6, 12 periods.
;; Per-candle rate: roc-N / N. Signed. encode-linear preserves sign
;; AND magnitude in one fact. No abs + signum split. ROC can be
;; negative — that is the point. Scale 0.1 covers typical per-candle
;; rates (a 10% per-candle move saturates — that is extreme).

(define (encode-oscillator-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((wr     (+ (/ (:williams-r candle) 100.0) 1.0))  ; normalize [-100,0] -> [0,1]
         (sk     (/ (:stoch-k candle) 100.0))              ; normalize [0,100] -> [0,1]
         (rsi    (/ (:rsi candle) 100.0))                   ; normalize [0,100] -> [0,1]
         (r1     (:roc-1 candle))
         (r3     (/ (:roc-3 candle) 3.0))
         (r6     (/ (:roc-6 candle) 6.0))
         (r12    (/ (:roc-12 candle) 12.0)))
    (list
      (Linear "williams-r" wr 1.0)
      (Linear "stoch-rsi" sk 1.0)
      (Linear "rsi" rsi 1.0)
      (Linear "roc-1" r1 0.1)
      (Linear "roc-3" r3 0.1)
      (Linear "roc-6" r6 0.1)
      (Linear "roc-12" r12 0.1))))
