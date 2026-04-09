;; ctx.wat — the immutable world
;; Depends on: thought-encoder.wat

(require primitives)
(require thought-encoder)

;; ── Ctx ────────────────────────────────────────────────────────────
;; Born at startup. Immutable DURING each candle. The ThoughtEncoder's
;; composition cache is the one seam — updated BETWEEN candles from
;; collected misses.

(struct ctx
  [thought-encoder : ThoughtEncoder]
  [dims : usize]
  [recalib-interval : usize])

(define (make-ctx [thought-encoder : ThoughtEncoder]
                  [dims : usize]
                  [recalib-interval : usize])
  : Ctx
  (ctx thought-encoder dims recalib-interval))

;; insert-misses — the seam. Called by the binary BETWEEN candles.
;; Inserts collected cache misses into the ThoughtEncoder's composition cache.
(define (insert-misses [c : Ctx] [misses : Vec<(ThoughtAST, Vector)>])
  (for-each (lambda (miss)
    (let (((ast vec) miss))
      (set! (:compositions (:thought-encoder c)) ast vec)))
    misses))
