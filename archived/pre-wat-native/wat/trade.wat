;; ── trade.wat ───────────────────────────────────────────────────────
;;
;; An active position the treasury holds. Created when a proposal is
;; funded. Phase transitions: :active → :runner → :settled-*.
;; Depends on: enums, newtypes, distances.

(require enums)
(require newtypes)
(require distances)

;; ── Struct ──────────────────────────────────────────────────────

(struct trade
  [id : TradeId]               ; assigned by treasury at funding time
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker (for trigger routing)
  [side : Side]                ; copied from the funding Proposal
  [source-asset : Asset]       ; what was deployed
  [target-asset : Asset]       ; what was acquired
  [entry-price : f64]          ; price at entry
  [amount : f64]               ; how much was deployed
  [stop-levels : Levels]       ; current trailing stop, safety stop
                               ; absolute price levels, updated by step 3c
  [phase : TradePhase]         ; :active → :runner → :settled-*
  [candles-held : usize]       ; how long open
  [price-history : Vec<f64>])  ; close prices from entry to now, appended each candle
