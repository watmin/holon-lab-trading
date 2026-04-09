;; enums.wat — Side, Direction, Outcome, TradePhase, reckoner-config, prediction, ScalarEncoding
;; Depends on: nothing

(require primitives)

;; ── Side — trading action ──────────────────────────────────────────
;; What the trader does. On Proposal and Trade.

(enum Side :buy :sell)

;; ── Direction — price movement ─────────────────────────────────────
;; What the price did. Used in propagation.

(enum Direction :up :down)

;; ── Outcome — accountability ───────────────────────────────────────
;; Did this trade produce value or destroy it?

(enum Outcome :grace :violence)

;; ── TradePhase — the state machine of a position's lifecycle ───────

(enum trade-phase
  :active
  :runner
  :settled-violence
  :settled-grace)

;; ── reckoner-config — readout mode only ────────────────────────────
;; dims and recalib-interval are separate parameters to the constructor.

(enum reckoner-config
  (Discrete
    labels)              ; Vec<String> — e.g. ("Up" "Down")
  (Continuous
    default-value))      ; f64 — the crutch, returned when ignorant

;; ── prediction — what a reckoner returns ───────────────────────────
;; Data, not action. The consumer decides.

(enum prediction
  (Discrete
    scores               ; Vec<(String, f64)> — (label name, cosine) per label
    conviction)          ; f64 — how strongly the reckoner leans
  (Continuous
    value                ; f64 — the reckoned scalar
    experience))         ; f64 — how much the reckoner knows (0.0 = ignorant)

;; ── ScalarEncoding — how a scalar accumulator encodes values ───────

(enum scalar-encoding
  :log                            ; no params — log compresses naturally
  (Linear [scale : f64])          ; encode-linear scale
  (Circular [period : f64]))      ; encode-circular period

;; ── MarketLens — which vocabulary subset a market observer thinks through ──

(enum MarketLens :momentum :structure :volume :narrative :regime :generalist)

;; ── ExitLens — which vocabulary subset an exit observer thinks through ──

(enum ExitLens :volatility :structure :timing :generalist)
