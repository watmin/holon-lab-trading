;; enums.wat — Side, Direction, Outcome, TradePhase, reckoner-config, prediction, ScalarEncoding
;; Depends on: nothing

(require primitives)

;; Side — trading action. On Proposal and Trade.
(enum Side :buy :sell)

;; Direction — price movement observation. Used in propagation.
(enum Direction :up :down)

;; Outcome — accountability. Grace = profit. Violence = loss.
(enum Outcome :grace :violence)

;; TradePhase — the state machine of a position's lifecycle.
(enum trade-phase
  :active              ; capital reserved, all stops live
  :runner              ; residue riding, principal already returned
  :settled-violence    ; stop-loss fired — bounded loss
  :settled-grace)      ; runner trail fired — residue is permanent gain

;; reckoner-config — readout mode for the learning primitive.
;; dims and recalib-interval are separate parameters to the constructor.
(enum reckoner-config
  (Discrete
    labels)            ; Vec<String> — ("Up" "Down") or ("Grace" "Violence")
  (Continuous
    default-value))    ; f64 — the crutch, returned when ignorant

;; prediction — what a reckoner returns. Data, not action.
(enum prediction
  (Discrete
    scores             ; Vec<(String, f64)> — (label name, cosine) for each label
    conviction)        ; f64 — how strongly the reckoner leans
  (Continuous
    value              ; f64 — the reckoned scalar
    experience))       ; f64 — how much the reckoner knows (0.0 = ignorant)

;; ScalarEncoding — how a scalar accumulator encodes values.
(enum scalar-encoding
  :log                           ; no params — log compresses naturally
  (Linear [scale : f64])         ; encode-linear scale
  (Circular [period : f64]))     ; encode-circular period
