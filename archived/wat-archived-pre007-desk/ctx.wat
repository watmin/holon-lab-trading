; ctx.wat — the immutable world. Born at startup. Never changes.
;
; Depends on: ThoughtEncoder
;
; ctx is a parameter, not an entity. Lowercase intentionally.
; Created by the binary, passed to on-candle. The enterprise
; is mutable state. ctx is not.

(require thought-encoder)     ; ThoughtEncoder

(struct ctx
  [thought-encoder : ThoughtEncoder]   ; contains VectorManager
  [dims : usize]                       ; vector dimensionality
  [recalib-interval : usize])          ; observations between recalibrations
