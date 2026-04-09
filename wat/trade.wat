;; trade.wat — Trade struct
;; Depends on: enums.wat, distances.wat, newtypes.wat, raw-candle.wat

(require primitives)
(require enums)
(require distances)
(require newtypes)
(require raw-candle)

;; ── Trade ──────────────────────────────────────────────────────────
;; An active position the treasury holds.

(struct trade
  [id : TradeId]
  [post-idx : usize]
  [broker-slot-idx : usize]
  [phase : TradePhase]
  [source-asset : Asset]
  [target-asset : Asset]
  [side : Side]
  [entry-rate : f64]
  [entry-atr : f64]
  [source-amount : f64]
  [stop-levels : Levels]
  [candles-held : usize]
  [price-history : Vec<f64>])

(define (make-trade [id : TradeId]
                    [post-idx : usize]
                    [broker-slot-idx : usize]
                    [source-asset : Asset]
                    [target-asset : Asset]
                    [side : Side]
                    [entry-rate : f64]
                    [entry-atr : f64]
                    [source-amount : f64]
                    [stop-levels : Levels])
  : Trade
  (trade id post-idx broker-slot-idx :active
    source-asset target-asset side
    entry-rate entry-atr source-amount stop-levels
    0 (list entry-rate)))
