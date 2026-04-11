;; ── enums.wat ───────────────────────────────────────────────────────
;;
;; Sum types for the enterprise. Side, Direction, and Outcome are the
;; three labels. TradePhase is the position lifecycle. ReckConfig and
;; Prediction are the reckoner's configuration and output. ScalarEncoding
;; determines how continuous values are encoded.
;; Depends on: nothing.

;; ── Trading labels ─────────────────────────────────────────────────
;; Side is a DECISION (what we do). Direction is a MEASUREMENT (what
;; the price did). They are related (Up → Buy, Down → Sell) but
;; distinct types — one is a decision, the other is a measurement.

(enum Side :buy :sell)              ; trading action — on Proposal and Trade
(enum Direction :up :down)          ; price movement — used in propagation
(enum Outcome :grace :violence)     ; accountability — used everywhere

;; ── Position lifecycle ─────────────────────────────────────────────

(enum trade-phase
  :active              ; capital reserved, all stops live
  :runner              ; residue riding, principal already returned
  :settled-violence    ; stop-loss fired — bounded loss
  :settled-grace)      ; trailing stop fired — residue is permanent gain

;; ── Reckoner configuration ─────────────────────────────────────────
;; One constructor. Config specifies the readout mode only.
;; dims and recalib-interval are separate parameters to the constructor.

(enum reckoner-config
  (Discrete
    labels)            ; Vec<String> — ("Up" "Down")
  (Continuous
    default-value      ; f64 — the crutch, returned when ignorant
    buckets))          ; usize — number of bins (K). Compute budget, not resolution.

;; ── Prediction — what a reckoner returns ───────────────────────────
;; Data. The consumer decides what "best" means.

(enum prediction
  (Discrete
    scores             ; Vec<(String, f64)> — (label name, cosine) for each label
    conviction)        ; f64 — how strongly the reckoner leans
  (Continuous
    value              ; f64 — the reckoned scalar
    experience))       ; f64 — how much the reckoner knows (0.0 = ignorant)

;; ── Scalar encoding ────────────────────────────────────────────────
;; Determines how continuous values are encoded into vectors.
;; Used by ScalarAccumulator — observe and extract use the SAME encoding.

(enum scalar-encoding
  :log                           ; no params — log compresses naturally
  (Linear [scale : f64])         ; encode-linear scale
  (Circular [period : f64]))     ; encode-circular period

;; ── Observer lenses ────────────────────────────────────────────────
;; Which vocabulary modules an observer attends to. Lenses select
;; the subset of thoughts each observer reasons about.

(enum market-lens
  :momentum
  :structure
  :volume
  :regime
  :narrative
  :generalist)

(enum exit-lens
  :volatility
  :structure
  :timing
  :generalist)
