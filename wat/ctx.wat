;; ctx.wat — the immutable world
;; Depends on: thought-encoder
;; Born at startup. Immutable DURING each candle.
;; The ThoughtEncoder's composition cache is the one seam —
;; updated BETWEEN candles from collected misses.

(require primitives)
(require thought-encoder)

(struct ctx
  [thought-encoder : ThoughtEncoder]   ; contains VectorManager + composition cache (the seam)
  [dims : usize]                       ; vector dimensionality
  [recalib-interval : usize])          ; observations between recalibrations

(define (make-ctx [thought-encoder : ThoughtEncoder]
                  [dims : usize]
                  [recalib-interval : usize])
  : Ctx
  (ctx thought-encoder dims recalib-interval))

;; Insert cache misses into the ThoughtEncoder between candles.
;; This is the one seam — the sequential phase after all parallel steps.
(define (insert-cache-misses [c : Ctx] [misses : Vec<(ThoughtAST, Vector)>])
  : Ctx
  (let ((updated-compositions
          (fold (lambda (cache miss)
                  (let (((ast vec) miss))
                    (assoc cache ast vec)))
                (:compositions (:thought-encoder c))
                misses)))
    (update c
      :thought-encoder (update (:thought-encoder c)
                         :compositions updated-compositions))))
