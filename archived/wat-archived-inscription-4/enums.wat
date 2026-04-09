;; enums.wat — sum types for the enterprise
;;
;; Depends on: nothing
;; side, direction, outcome, trade-phase, market-lens, exit-lens,
;; reckoner-config, prediction, scalar-encoding, thought-ast

(require primitives)

;; ── side — trading action (what the trader does) ────────────────────
;; On Proposal and Trade. Up → :buy, Down → :sell.
(enum side
  :buy
  :sell)

;; ── direction — price movement (what the price did) ─────────────────
;; Used in propagation. The market observer predicts this.
(enum direction
  :up
  :down)

;; ── outcome — accountability ────────────────────────────────────────
;; Grace = profit. Violence = loss.
(enum outcome
  :grace
  :violence)

;; ── trade-phase — the state machine of a position's lifecycle ───────
;; active → runner (take-profit hit, principal returns, residue rides)
;; active → settled-violence (stop-loss fired)
;; runner → settled-grace (runner trail fired, residue is permanent gain)
(enum trade-phase
  :active
  :runner
  :settled-violence
  :settled-grace)

;; ── market-lens — which vocabulary subset a market observer thinks through ─
;; Each variant selects a subset of the market vocabulary.
;; :generalist selects ALL market modules.
(enum market-lens :momentum :structure :volume :narrative :regime :generalist)

;; ── exit-lens — which vocabulary subset an exit observer thinks through ────
;; Each variant selects a subset of the exit vocabulary.
;; :generalist selects ALL exit modules.
(enum exit-lens :volatility :structure :timing :generalist)

;; ── reckoner-config — configuration for the learning primitive ──────
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

;; ── prediction — what a reckoner returns ────────────────────────────
;; Data, not action. The consumer decides what "best" means.
(enum prediction
  (Discrete
    [scores : Vec<(String, f64)>]
    [conviction : f64])
  (Continuous
    [value : f64]
    [experience : f64]))

;; ── scalar-encoding — how a scalar accumulator encodes values ───────
;; Configured at construction. The data and its interpretation travel together.
(enum scalar-encoding
  :log
  (Linear [scale : f64])
  (Circular [period : f64]))

;; ── thought-ast — the tree of deferred thoughts ────────────────────
;; Recursive. Bind and Bundle reference ThoughtAST. The vocabulary
;; produces these — data, not execution. The ThoughtEncoder evaluates them.
(enum thought-ast
  (Atom [name : String])
  (Linear [name : String] [value : f64] [scale : f64])
  (Log [name : String] [value : f64])
  (Circular [name : String] [value : f64] [period : f64])
  (Bind [left : ThoughtAST] [right : ThoughtAST])
  (Bundle [children : Vec<ThoughtAST>]))
