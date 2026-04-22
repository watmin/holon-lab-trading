;; ── trade-origin.wat ────────────────────────────────────────────────
;;
;; Where a trade came from, for propagation routing. The archaeological
;; record of WHY a trade exists. Stashed by the treasury at funding time.
;; Depends on: enums.

(require enums)

;; ── Struct ──────────────────────────────────────────────────────

(struct trade-origin
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker
  [composed-thought : Vector]  ; the thought at entry
  [prediction : Prediction])   ; :discrete (Grace/Violence) — the broker's prediction
                               ; at funding time
