;; vocab/market/divergence.wat — RSI divergence via PELT structural peaks
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :narrative

(require primitives)
(require candle)

(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((bull (:rsi-divergence-bull c))
        (bear (:rsi-divergence-bear c)))
    ;; Conditional: emit divergence only when present
    (let ((facts '()))
      (when (> bull 0.001)
        (set! facts (append facts (list
          (Log "rsi-divergence-bull" (+ 1.0 bull))))))
      (when (> bear 0.001)
        (set! facts (append facts (list
          (Log "rsi-divergence-bear" (+ 1.0 bear))))))
      ;; Always emit a net divergence fact — signed
      (set! facts (append facts (list
        (Linear "rsi-divergence-net" (- bull bear) 1.0))))
      facts)))
