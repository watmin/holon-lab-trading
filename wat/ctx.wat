;; ctx.wat — the immutable world
;;
;; Depends on: thought-encoder
;;
;; Three fields. The one seam documented.
;;
;; Born at startup. Passed to posts via on-candle. Nobody owns it.
;; Everybody borrows it. Immutable config is separate from mutable state.
;;
;; The one seam: the ThoughtEncoder's composition cache is mutable.
;; During encoding (parallel), the cache is read-only — misses are
;; returned as values. Between candles (sequential), the enterprise
;; inserts collected misses into the cache. ctx is immutable DURING
;; a candle. The cache updates BETWEEN candles.

(require primitives)
(require thought-encoder)

(struct ctx
  [thought-encoder : ThoughtEncoder]   ; contains VectorManager + composition cache (the seam)
  [dims : usize]                       ; vector dimensionality
  [recalib-interval : usize])          ; observations between recalibrations
