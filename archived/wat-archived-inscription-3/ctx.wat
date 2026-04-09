;; ctx.wat — the immutable world. Born at startup.
;;
;; Depends on: thought-encoder.
;;
;; Lowercase intentionally — ctx is a parameter that flows through
;; function calls, not a type you instantiate like Post or Treasury.
;; Contains the ThoughtEncoder (which contains the VectorManager),
;; dims, recalib-interval. ctx flows in as a parameter — the enterprise
;; receives it, posts receive it, observers receive it. Nobody owns it.
;; Everybody borrows it. Immutable config is separate from mutable state.
;;
;; The one seam: the ThoughtEncoder's composition cache is mutable.
;; During encoding (parallel), the cache is read-only — misses are
;; returned as values. Between candles (sequential), the enterprise
;; inserts collected misses into the cache. ctx is immutable DURING a
;; candle. The cache updates BETWEEN candles.

(require primitives)
(require thought-encoder)

;; ── Ctx — three fields, nothing else ────────────────────────────────────

(struct ctx
  [thought-encoder : ThoughtEncoder]  ; contains VectorManager + composition cache (the seam)
  [dims : usize]                      ; vector dimensionality
  [recalib-interval : usize])         ; observations between recalibrations
