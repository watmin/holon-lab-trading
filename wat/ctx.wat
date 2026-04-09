;; ctx.wat — Ctx struct
;; Depends on: thought-encoder
;; The immutable world. Born at startup. Lowercase intentionally.

(require primitives)
(require thought-encoder)

;; ── Ctx — immutable context that flows through function calls ─────────
;; Three fields, nothing else. Nobody owns it. Everybody borrows it.
;; The one seam: the ThoughtEncoder's composition cache is mutable.
;; During encoding (parallel), the cache is read-only — misses are
;; returned as values. Between candles (sequential), the enterprise
;; inserts collected misses into the cache. ctx is immutable DURING a
;; candle. The cache updates BETWEEN candles.
(struct ctx
  [thought-encoder : ThoughtEncoder]
  [dims : usize]
  [recalib-interval : usize])
