;; vocab/exit/structure.wat — trend consistency, ADX strength
;; Depends on: candle.wat
;; Domain: exit — distance signal
;; Lens: :structure

(require primitives)
(require candle)

(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((tc-6 (:trend-consistency-6 c))
        (tc-12 (:trend-consistency-12 c))
        (tc-24 (:trend-consistency-24 c))
        (adx-norm (/ (:adx c) 100.0))
        (range-12 (:range-pos-12 c))
        (range-48 (:range-pos-48 c)))
    (list
      ;; Trend consistency at multiple horizons
      (Linear "exit-trend-6" tc-6 1.0)
      (Linear "exit-trend-12" tc-12 1.0)
      (Linear "exit-trend-24" tc-24 1.0)

      ;; ADX strength — for determining how wide stops should be
      (Linear "exit-adx" adx-norm 1.0)

      ;; Range position — where in the range are we?
      ;; Near extremes → tighter stops. Mid-range → wider stops.
      (Linear "exit-range-12" range-12 1.0)
      (Linear "exit-range-48" range-48 1.0))))
