; enums.wat — all sum types in one file
;
; Depends on: nothing.
; Every enum the enterprise uses. Order follows the guide's
; forward declarations — each line can only reference what's above it.

; ── Side — trading action ──────────────────────────────────────────────
; What the trader does. On Proposal and Trade.

(enum side
  :buy
  :sell)

; ── Direction — price movement ─────────────────────────────────────────
; What the price did. Used in propagation.

(enum direction
  :up
  :down)

; ── Outcome — accountability ───────────────────────────────────────────
; Used everywhere. Grace is gain, Violence is loss.

(enum outcome
  :grace
  :violence)

; ── TradePhase — the state machine of a position's lifecycle ───────────

(enum trade-phase
  :active              ; capital reserved, all stops live
  :principal-recovered ; principal returned to available, residue continues
  :runner              ; residue riding with wider trailing stop, zero cost basis
  :settled-violence    ; stop-loss fired — bounded loss
  :settled-grace)      ; runner trail fired or take-profit — residue is permanent gain

; ── MarketLens — which vocabulary subset a market observer thinks through
; Each variant selects a subset of the vocabulary. :generalist selects ALL.

(enum market-lens
  :momentum
  :structure
  :volume
  :narrative
  :regime
  :generalist)

; ── ExitLens — which vocabulary subset an exit observer thinks through

(enum exit-lens
  :volatility
  :structure
  :timing
  :generalist)

; ── reckoner-config — constructor argument for make-reckoner ───────────

(enum reckoner-config
  (Discrete
    [dims : usize]               ; vector dimensionality
    [recalib-interval : usize]   ; observations between recalibrations
    [labels : Vec<String>])      ; ("Up" "Down")
  (Continuous
    [dims : usize]
    [recalib-interval : usize]
    [default-value : f64]))      ; the crutch, returned when ignorant

; ── prediction — what a reckoner returns ───────────────────────────────
; Data. The consumer decides what "best" means.

(enum prediction
  (Discrete
    [scores : Vec<(String, f64)>]  ; (label name, cosine) for each label
    [conviction : f64])            ; how strongly the reckoner leans
  (Continuous
    [value : f64]                  ; the reckoned scalar
    [experience : f64]))           ; how much the reckoner knows (0.0 = ignorant)

; ── scalar-encoding — how a scalar accumulator encodes values ──────────

(enum scalar-encoding
  :log                             ; no params — log compresses naturally
  (Linear [scale : f64])           ; encode-linear scale
  (Circular [period : f64]))       ; encode-circular period

; ── thought-ast — the vocabulary's language ────────────────────────────
; Recursive. A tree of deferred computations — data, not execution.
; The vocabulary produces these. The encoder evaluates them.

(enum thought-ast
  (Atom [name : String])                          ; dictionary lookup
  (Linear [name : String] [value : f64] [scale : f64])  ; bind(atom, encode-linear)
  (Log [name : String] [value : f64])             ; bind(atom, encode-log)
  (Circular [name : String] [value : f64] [period : f64]) ; bind(atom, encode-circular)
  (Bind [left : ThoughtAST] [right : ThoughtAST]) ; composition of two sub-trees
  (Bundle [children : Vec<ThoughtAST>]))           ; superposition of sub-trees
