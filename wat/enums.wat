;; enums.wat — Side, Direction, Outcome, TradePhase, reckoner-config, prediction, ScalarEncoding
;; Depends on: nothing

(require primitives)

;; ── Side — trading action ─────────────────────────────────────────────
;; What the trader does. On Proposal and Trade.
(enum Side :buy :sell)

;; ── Direction — price movement observation ────────────────────────────
;; What the price did. Used in propagation.
(enum Direction :up :down)

;; ── Outcome — accountability ──────────────────────────────────────────
;; Did this trade produce value or destroy it?
(enum Outcome :grace :violence)

;; ── TradePhase — the state machine of a position's lifecycle ──────────
;; :active → :runner → :settled-*
(enum trade-phase
  :active
  :runner
  :settled-violence
  :settled-grace)

;; ── reckoner-config — readout mode for the learning primitive ─────────
;; dims and recalib-interval are separate parameters to the constructor,
;; not inside the config. The config specifies the readout mode only.
(enum reckoner-config
  (Discrete
    labels)              ; Vec<String> — ("Up" "Down")
  (Continuous
    default-value))      ; f64 — the crutch, returned when ignorant

;; ── prediction — what a reckoner returns. Data. ───────────────────────
;; The consumer decides what "best" means.
(enum prediction
  (Discrete
    scores               ; Vec<(String, f64)> — (label name, cosine) for each label
    conviction)          ; f64 — how strongly the reckoner leans
  (Continuous
    value                ; f64 — the reckoned scalar
    experience))         ; f64 — how much the reckoner knows (0.0 = ignorant)

;; ── ScalarEncoding — how a ScalarAccumulator encodes values ───────────
(enum scalar-encoding
  :log                           ; no params — log compresses naturally
  (Linear [scale : f64])         ; encode-linear scale
  (Circular [period : f64]))     ; encode-circular period
