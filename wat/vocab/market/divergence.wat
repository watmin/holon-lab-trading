;; vocab/market/divergence.wat — RSI divergence via PELT structural peaks
;; Depends on: candle
;; MarketLens :narrative selects this module.

(require primitives)
(require candle)

(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((bull (:rsi-divergence-bull c))
        (bear (:rsi-divergence-bear c)))
    ;; Only emit facts when divergence is present.
    ;; The vocabulary is conditional — it emits what IS true.
    (append
      (if (> bull 0.0)
        (list (Log "rsi-divergence-bull" bull))
        '())
      (if (> bear 0.0)
        (list (Log "rsi-divergence-bear" bear))
        '()))))
