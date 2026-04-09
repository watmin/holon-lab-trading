;; vocab/market/keltner.wat — channel position, BB position, squeeze.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state. No zones.
;; Keltner channel position, Bollinger position, and squeeze as ratio.
;; bb-kelt-spread (not bk-spread) — the correct atom name.
;; Squeeze as ratio (not bool) — bb-width / kelt-width.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-keltner-facts ────────────────────────────────────────────────

(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (let* ((kelt-width (- (:kelt-upper c) (:kelt-lower c)))
         (facts
           (list
             ;; Keltner position — where close is within the channel [-1, 1]
             (Linear "kelt-pos" (:kelt-pos c) 1.0)

             ;; Bollinger position — where close is within the bands [-1, 1]
             (Linear "bb-pos" (:bb-pos c) 1.0)

             ;; Squeeze — bb-width / kelt-width ratio. Continuous.
             ;; < 1.0 = Bollinger inside Keltner (squeeze). > 1.0 = expansion.
             (Linear "squeeze" (:squeeze c) 2.0)

             ;; BB-Keltner spread — how far apart the two channel systems are
             (Linear "bb-kelt-spread"
                     (if (> kelt-width 0.0)
                         (/ (:bb-width c) kelt-width)
                         1.0)
                     2.0))))

    ;; Conditional: beyond bands — how far (log scale)
    (cond
      ((> (:bb-pos c) 1.0)
        (cons (Log "bb-breakout-upper" (- (:bb-pos c) 1.0)) facts))
      ((< (:bb-pos c) -1.0)
        (cons (Log "bb-breakout-lower" (- (- (:bb-pos c)) 1.0)) facts))
      (else facts))))
