;; ctx.wat — the immutable world
;; Depends on: thought-encoder
;; Born at startup. Passed to posts via ctx on every on-candle call.
;; Immutable DURING each candle. The ThoughtEncoder's composition cache
;; is the one seam — updated BETWEEN candles from collected misses.

(require primitives)
(require thought-encoder)

;; Three fields, nothing else.
(struct ctx
  [thought-encoder : ThoughtEncoder]     ; contains VectorManager + composition cache (the seam)
  [dims : usize]                         ; vector dimensionality
  [recalib-interval : usize])            ; observations between recalibrations

(define (make-ctx [te : ThoughtEncoder] [dims : usize] [recalib-interval : usize])
  : Ctx
  (ctx te dims recalib-interval))

;; Insert collected cache misses into the ThoughtEncoder.
;; Called by the binary BETWEEN candles — the one seam.
(define (insert-cache-misses [c : Ctx] [misses : Vec<(ThoughtAST, Vector)>])
  (for-each (lambda (miss)
    (let (((ast vec) miss))
      (set! (:compositions (:thought-encoder c)) ast vec)))
    misses))
