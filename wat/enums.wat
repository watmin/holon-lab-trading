;; enums.wat — Side, Direction, Outcome, TradePhase, reckoner-config, prediction, ScalarEncoding
;; Depends on: nothing

(require primitives)

;; ── Side — trading action ──────────────────────────────────────────
;; What the trader does. On Proposal and Trade.
(enum side :buy :sell)

;; ── Direction — price movement ─────────────────────────────────────
;; What the price did. Used in propagation.
(enum direction :up :down)

;; ── Outcome — accountability ───────────────────────────────────────
;; Did this produce value or destroy it?
(enum outcome :grace :violence)

;; ── TradePhase — the state machine of a position's lifecycle ───────
(enum trade-phase
  :active              ; capital reserved, all stops live
  :runner              ; residue riding, principal covered
  :settled-violence    ; stop-loss fired — bounded loss
  :settled-grace)      ; runner trail fired — residue is permanent gain

;; ── reckoner-config — readout mode for the learning primitive ──────
;; dims and recalib-interval are separate parameters.
;; The config specifies the readout mode only.
(enum reckoner-config
  (Discrete
    labels)            ; Vec<String> — ("Up" "Down") or ("Grace" "Violence")
  (Continuous
    default-value))    ; f64 — the crutch, returned when ignorant

;; ── prediction — what a reckoner returns ───────────────────────────
;; Data, not action. The consumer decides what "best" means.
(enum prediction
  (Discrete
    scores             ; Vec<(String, f64)> — (label, cosine) for each label
    conviction)        ; f64 — how strongly the reckoner leans
  (Continuous
    value              ; f64 — the reckoned scalar
    experience))       ; f64 — how much the reckoner knows

;; ── ScalarEncoding — how a scalar accumulator encodes values ───────
(enum scalar-encoding
  :log                           ; encode-log — ratios compress naturally
  (Linear [scale : f64])         ; encode-linear scale
  (Circular [period : f64]))     ; encode-circular period
