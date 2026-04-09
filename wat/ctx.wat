;; ctx.wat — the immutable world. Born at startup.
;; Depends on: thought-encoder

(require primitives)
(require thought-encoder)

;; Immutable DURING each candle. The ThoughtEncoder's composition cache
;; is the one seam — updated BETWEEN candles from collected misses.
;; Three fields, nothing else.
(struct ctx
  [thought-encoder : ThoughtEncoder]
  [dims : usize]
  [recalib-interval : usize])

(define (make-ctx [thought-encoder : ThoughtEncoder]
                  [dims : usize]
                  [recalib-interval : usize])
  : Ctx
  (ctx thought-encoder dims recalib-interval))

;; Insert collected cache misses into the ThoughtEncoder's composition cache.
;; Called by the binary BETWEEN candles — the one seam.
(define (insert-cache-misses [ctx : Ctx] [misses : Vec<(ThoughtAST, Vector)>])
  (for-each (lambda (miss)
    (let (((ast vec) miss))
      (set! (:compositions (:thought-encoder ctx)) ast vec)))
    misses))
