;; enums.wat — sum types for the enterprise
;;
;; Depends on: nothing
;; Side, Direction, Outcome, TradePhase, reckoner-config, prediction,
;; ScalarEncoding, ThoughtAST

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

;; ── MarketLens — which vocabulary subset a market observer thinks through ─
;; Each variant selects a subset of the market vocabulary.
;; :generalist selects ALL market modules.
(enum market-lens :momentum :structure :volume :narrative :regime :generalist)

;; ── ExitLens — which vocabulary subset an exit observer thinks through ────
;; Each variant selects a subset of the exit vocabulary.
;; :generalist selects ALL exit modules.
(enum exit-lens :volatility :structure :timing :generalist)

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

;; ── thought-ast — the tree of deferred thoughts ─────────────────────
;; Recursive. Bind and Bundle reference ThoughtAST. The vocabulary
;; produces these — data, not execution. The ThoughtEncoder evaluates them.
(enum thought-ast
  (Atom [name : String])
  (Linear [name : String] [value : f64] [scale : f64])
  (Log [name : String] [value : f64])
  (Circular [name : String] [value : f64] [period : f64])
  (Bind [left : ThoughtAST] [right : ThoughtAST])
  (Bundle [children : Vec<ThoughtAST>]))
