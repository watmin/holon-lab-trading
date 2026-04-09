;; vocab/market/oscillators.wat — Williams %R, RSI, CCI, MFI, multi-ROC
;; Depends on: candle
;; MarketLens :momentum selects this module.

(require primitives)
(require candle)

;; Oscillator facts — signed scalars, no zones.
;; The discriminant learns where the boundaries are.
(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI: [0, 100] → normalize to [0, 1]
    (Linear "rsi" (/ (:rsi c) 100.0) 1.0)

    ;; Williams %R: [-100, 0] → normalize to [-1, 0]
    (Linear "williams-r" (/ (:williams-r c) 100.0) 1.0)

    ;; CCI: unbounded, centered around 0. Use scale to compress.
    (Linear "cci" (/ (:cci c) 300.0) 1.0)

    ;; MFI: [0, 100] → normalize to [0, 1]
    (Linear "mfi" (/ (:mfi c) 100.0) 1.0)

    ;; Multi-period rate of change — signed, unbounded
    ;; Log for ratios: equal ratios = equal similarity
    (Log "roc-1" (+ 1.0 (:roc-1 c)))
    (Log "roc-3" (+ 1.0 (:roc-3 c)))
    (Log "roc-6" (+ 1.0 (:roc-6 c)))
    (Log "roc-12" (+ 1.0 (:roc-12 c)))

    ;; RSI divergence magnitudes — 0.0 = no divergence
    (Linear "rsi-divergence-bull" (:rsi-divergence-bull c) 1.0)
    (Linear "rsi-divergence-bear" (:rsi-divergence-bear c) 1.0)))
