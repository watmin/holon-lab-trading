# The Order

*Leaves to root. The path through the wat.*

The guide declares. The wat implements. The circuit visualizes.
The Rust compiles. The market proves. This file declares the order.

## Reading order

```
1. GUIDE.md                    — the specification (read first, always)
2. CIRCUIT.md                  — the visualization (read after the guide)
3. wat files (leaves to root)  — the implementation
4. src/ (leaves to root)       — the compiled code (future)
```

## Wat file order — leaves to root

Each file can only reference files above it. The dependencies are
satisfied before the consumers. The order IS the construction order
from the guide.

```
;; ── Leaves — depend on nothing ──────────────────────────────
raw-candle.wat              ; Asset, RawCandle
indicator-bank.wat          ; IndicatorBank (streaming primitives inside)
window-sampler.wat          ; WindowSampler
enums.wat                   ; Side, Direction, Outcome, TradePhase,
                            ; reckoner-config, prediction, ScalarEncoding
newtypes.wat                ; TradeId
scalar-accumulator.wat      ; ScalarAccumulator (requires Outcome from enums)
engram-gate.wat             ; check-engram-gate (requires primitives only)

;; ── Candle — depends on: indicator-bank ─────────────────────
candle.wat                  ; Candle struct (the output of tick)

;; ── Vocabulary — depends on: candle ─────────────────────────
vocab/shared/time.wat
vocab/market/oscillators.wat
vocab/market/flow.wat
vocab/market/persistence.wat
vocab/market/regime.wat
vocab/market/divergence.wat
vocab/market/ichimoku.wat
vocab/market/stochastic.wat
vocab/market/fibonacci.wat
vocab/market/keltner.wat
vocab/market/momentum.wat
vocab/market/price-action.wat
vocab/market/timeframe.wat
vocab/exit/volatility.wat
vocab/exit/structure.wat
vocab/exit/timing.wat

;; ── ThoughtEncoder — depends on: vocabulary ─────────────────
thought-encoder.wat         ; ThoughtAST enum, ThoughtEncoder struct + encode

;; ── Ctx — depends on: thought-encoder ───────────────────────
ctx.wat                     ; Ctx struct (thought-encoder, dims, recalib-interval)

;; ── Distances and Levels — depend on nothing ────────────────
distances.wat               ; Distances, Levels

;; ── Observers — depend on: reckoner, window-sampler, distances
market-observer.wat         ; MarketObserver struct + interface
exit-observer.wat           ; ExitObserver struct + interface

;; ── Paper — depends on: distances ───────────────────────────
paper-entry.wat             ; PaperEntry struct

;; ── Broker — depends on: reckoner, scalar-accumulator, observer
broker.wat                  ; Broker struct + interface

;; ── Trade lifecycle — depends on: enums, distances, levels ──
proposal.wat                ; Proposal struct
trade.wat                   ; Trade struct
settlement.wat              ; TreasurySettlement, Settlement (Resolution lives in broker.wat)
log-entry.wat               ; LogEntry enum
trade-origin.wat            ; TradeOrigin struct

;; ── Post — depends on: everything above ─────────────────────
post.wat                    ; Post struct + interface

;; ── Treasury — depends on: proposal, trade, settlement ──────
treasury.wat                ; Treasury struct + interface

;; ── Enterprise — depends on: post, treasury ─────────────────
enterprise.wat              ; Enterprise struct + interface + four-step loop
```

## The rule

Each file is inscribed after its dependencies. Each file is judged by
the ignorant against the guide before the next is inscribed. The order
IS the path. The path IS the construction. The construction IS the
understanding.
