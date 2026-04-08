; ctx.wat — the immutable world. Born at startup.
;
; Depends on: thought-encoder (ThoughtEncoder)
;
; ctx is a parameter, not an entity. Lowercase intentionally.
; Created by the binary, passed to on-candle. The enterprise
; is mutable state. ctx is not.
;
; The one seam: the ThoughtEncoder's composition cache is mutable.
; Immutable DURING a candle — the cache is read-only, misses returned
; as values. Updated BETWEEN candles — the enterprise inserts collected
; misses. The seam is bounded by the fold boundary.

(require thought-encoder)     ; ThoughtEncoder

(struct ctx
  [thought-encoder : ThoughtEncoder]   ; contains VectorManager + composition cache (the seam)
  [dims : usize]                       ; vector dimensionality
  [recalib-interval : usize])          ; observations between recalibrations
