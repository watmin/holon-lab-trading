;; enums.wat — Side, Direction, Outcome, TradePhase, reckoner-config, prediction, ScalarEncoding
;; Depends on: nothing

(require primitives)

;; Side — trading action. On Proposal and Trade.
;; Distinct from Direction — Side is a decision, Direction is a measurement.
(enum Side :buy :sell)

;; Direction — price movement. Used in propagation.
;; Up → price rose. Down → price fell.
(enum Direction :up :down)

;; Outcome — accountability. Grace = profit. Violence = loss.
(enum Outcome :grace :violence)

;; TradePhase — the state machine of a position's lifecycle.
;; :active → :runner → :settled-*
;; Four variants. No :principal-recovered.
(enum trade-phase
  :active              ; capital reserved, all stops live
  :runner              ; residue riding, principal already returned
  :settled-violence    ; stop-loss fired — bounded loss
  :settled-grace)      ; runner trail fired — residue is permanent gain

;; reckoner-config — data for constructing a Reckoner.
;; One constructor. Config is data.
(enum reckoner-config
  (Discrete
    dims               ; usize — vector dimensionality
    recalib-interval   ; usize — observations between recalibrations
    labels)            ; Vec<String> — ("Up" "Down") or ("Grace" "Violence")
  (Continuous
    dims               ; usize
    recalib-interval   ; usize
    default-value))    ; f64 — the crutch, returned when ignorant

;; prediction — what a reckoner returns. Data, not action.
;; Pattern-match to know which mode. The type tells you.
(enum prediction
  (Discrete
    scores             ; Vec<(String, f64)> — (label name, cosine) for each label
    conviction)        ; f64 — how strongly the reckoner leans
  (Continuous
    value              ; f64 — the reckoned scalar
    experience))       ; f64 — how much the reckoner knows (0.0 = ignorant)

;; ScalarEncoding — how a ScalarAccumulator encodes values.
;; Configured at construction. The data and its interpretation travel together.
(enum scalar-encoding
  :log                           ; no params — log compresses naturally
  (Linear [scale : f64])         ; encode-linear scale
  (Circular [period : f64]))     ; encode-circular period

;; MarketLens — which vocabulary subset a market observer thinks through.
;; :generalist selects ALL modules in the domain.
(enum MarketLens :momentum :structure :volume :narrative :regime :generalist)

;; ExitLens — which vocabulary subset an exit observer thinks through.
(enum ExitLens :volatility :structure :timing :generalist)
