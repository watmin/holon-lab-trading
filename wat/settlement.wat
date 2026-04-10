;; ── settlement.wat ──────────────────────────────────────────────────
;;
;; What the treasury produces when a trade closes. Carries the full
;; trade, the exit price, the outcome, the amount of value gained or
;; lost, and the archaeological record (composed-thought, prediction)
;; from TradeOrigin for propagation audit.
;; Depends on: enums, trade.

(require enums)
(require trade)

;; ── Struct ──────────────────────────────────────────────────────

(struct treasury-settlement
  [trade : Trade]              ; which trade closed (carries post-idx, broker-slot-idx, side)
  [exit-price : f64]           ; price at settlement
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value gained or lost
  [composed-thought : Vector]  ; from trade-origins, stashed at funding time
  [prediction : Prediction])   ; from trade-origins — the broker's verdict at funding time.
                               ; The learning pair: prediction (what the enterprise believed)
                               ; + outcome (what actually happened). The audit trail.
