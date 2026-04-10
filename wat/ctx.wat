;; ── ctx.wat ─────────────────────────────────────────────────────
;;
;; The immutable world. Born at startup. Passed to posts via on-candle.
;; Three fields, nothing else.
;;
;; Immutable DURING each candle. The ThoughtEncoder's composition cache
;; is the one seam — updated BETWEEN candles from collected misses.
;;
;; Depends on: thought-encoder.

(require thought-encoder)

;; ── Struct ──────────────────────────────────────────────────────

(struct ctx
  [thought-encoder : ThoughtEncoder] ; contains VectorManager + composition cache (the seam)
  [dims : usize]                     ; vector dimensionality
  [recalib-interval : usize])        ; observations between recalibrations

;; ── Constructor ─────────────────────────────────────────────────

(define (make-ctx [dims : usize] [recalib-interval : usize])
  : Ctx
  (let ((vm (make-vector-manager dims))
        (encoder (make-thought-encoder vm)))
    (make-ctx encoder dims recalib-interval)))

;; ── Cache maintenance — the one seam ───────────────────────────
;; Called BETWEEN candles by the enterprise. Inserts all collected
;; misses from the previous candle's parallel encoding phases.
;; This is the only mutation on ctx.

(define (insert-misses [ctx : Ctx] [misses : Vec<(ThoughtAST, Vector)>])
  : ()
  (for-each (lambda ((ast vec))
              (set! (:compositions (:thought-encoder ctx)) ast vec))
            misses))
