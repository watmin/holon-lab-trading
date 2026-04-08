;; enums.wat — sum types for the enterprise
;;
;; Depends on: nothing
;; Side, Direction, Outcome, TradePhase, reckoner-config, prediction,
;; ScalarEncoding

(require primitives)

;; ── Side — trading action (what the trader does) ─────────────────────
;; On Proposal and Trade. Up → :buy, Down → :sell.
(enum side
  :buy
  :sell)

;; ── Direction — price movement (what the price did) ──────────────────
;; Used in propagation. The market observer predicts this.
(enum direction
  :up
  :down)

;; ── Outcome — accountability ─────────────────────────────────────────
;; Grace = profit. Violence = loss.
(enum outcome
  :grace
  :violence)

;; ── TradePhase — the state machine of a position's lifecycle ─────────
;; active → settled-violence (stop-loss fired)
;; active → principal-recovered (take-profit hit, principal returns)
;; principal-recovered → runner (residue rides with wider trailing stop)
;; runner → settled-grace (runner trail fired, residue is permanent gain)
(enum trade-phase
  :active
  :principal-recovered
  :runner
  :settled-violence
  :settled-grace)

;; ── reckoner-config — configuration for the learning primitive ───────
;; One constructor, two modes. Config is data.
(enum reckoner-config
  (Discrete
    [dims : usize]
    [recalib-interval : usize]
    [labels : Vec<String>])
  (Continuous
    [dims : usize]
    [recalib-interval : usize]
    [default-value : f64]))

;; ── prediction — what a reckoner returns ─────────────────────────────
;; Data, not action. The consumer decides what "best" means.
(enum prediction
  (Discrete
    [scores : Vec<(String, f64)>]
    [conviction : f64])
  (Continuous
    [value : f64]
    [experience : f64]))

;; ── scalar-encoding — how a scalar accumulator encodes values ────────
;; Configured at construction. The data and its interpretation travel together.
(enum scalar-encoding
  :log
  (Linear [scale : f64])
  (Circular [period : f64]))
