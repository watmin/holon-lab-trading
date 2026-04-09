;; trade.wat — Trade struct
;; Depends on: enums (TradePhase, Side), distances (Levels),
;;             raw-candle (Asset), newtypes (TradeId)

(require primitives)
(require enums)
(require distances)
(require raw-candle)
(require newtypes)

;; ── Trade — an active position the treasury holds ─────────────────────
(struct trade
  [id : TradeId]
  [post-idx : usize]
  [broker-slot-idx : usize]
  [phase : TradePhase]
  [source-asset : Asset]
  [target-asset : Asset]
  [side : Side]
  [entry-rate : f64]
  [source-amount : f64]
  [stop-levels : Levels]
  [candles-held : usize]
  [price-history : Vec<f64>])
