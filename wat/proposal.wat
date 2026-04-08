; proposal.wat — what a post produces, what the treasury evaluates.
;
; Depends on: Distances, Prediction, Side.
;
; Assembled by the post during step-compute-dispatch. The post calls:
;   market observer -> thought vector
;   exit observer -> evaluate-and-compose -> composed + distances
;   broker -> propose(composed) -> prediction (Grace/Violence)
;   post bundles these into a Proposal and submits to treasury.
;
; The Prediction on a proposal is from the BROKER's reckoner
; (Grace/Violence), NOT the market observer's Up/Down prediction.
; The Side is derived from the market observer's winning label.

(require primitives)
(require enums)         ; Side, Prediction
(require distances)     ; Distances

;; ── Struct ──────────────────────────────────────────────────────────────

(struct proposal
  [composed-thought : Vector]  ; market thought + exit facts
  [prediction : Prediction]    ; :discrete (Grace/Violence) from the broker
  [distances : Distances]      ; from the exit observer
  [edge : f64]                 ; the broker's edge [0.0, 1.0] — raw accuracy
                               ; from the broker's curve at its current conviction.
                               ; The treasury sorts proposals by this value and
                               ; funds proportionally — more edge, more capital.
  [side : Side]                ; :buy or :sell — from the market observer's
                               ; Up/Down prediction. Up -> :buy, Down -> :sell.
  [post-idx : usize]           ; which post this came from
  [broker-slot-idx : usize])   ; which broker proposed this
