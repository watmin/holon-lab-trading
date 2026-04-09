;; keltner.wat — channel position, Bollinger position, squeeze
;;
;; Depends on: candle (reads: kelt-pos, bb-pos, squeeze, bb-width)
;; Market domain. Lens: :structure, :generalist.
;;
;; bb-kelt-spread not bk-spread. Squeeze as continuous ratio.

(require primitives)

(define (encode-keltner-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; Keltner channel position — where price sits in the channel
    (Linear "kelt-pos" (:kelt-pos candle) 1.0)

    ;; Bollinger position — where price sits in the bands
    (Linear "bb-pos" (:bb-pos candle) 1.0)

    ;; BB-Keltner spread — how far apart the two channels are
    ;; Positive = BB wider than Keltner, negative = Keltner wider
    (Linear "bb-kelt-spread"
      (- (:bb-pos candle) (:kelt-pos candle)) 2.0)

    ;; Squeeze — continuous ratio: bb-width / kelt-width
    (Log "squeeze" (:squeeze candle))))
