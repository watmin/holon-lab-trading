; trade-origin.wat — where a trade came from, for propagation routing.
;
; Depends on: nothing (just Vector).
;
; Stashed by the treasury at funding time. When a trade settles,
; the enterprise uses the origin to route the outcome back to the
; right post and broker. The composed-thought is preserved from
; funding so propagation uses the same vector the observers saw.

(require primitives)

;; ── Struct ──────────────────────────────────────────────────────────────

(struct trade-origin
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker
  [composed-thought : Vector]) ; the thought at entry
