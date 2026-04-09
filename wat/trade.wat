;; trade.wat — Trade struct
;; Depends on: enums (TradePhase, Side), distances (Levels), newtypes (TradeId), raw-candle (Asset)
;; An active position the treasury holds.

(require primitives)
(require enums)
(require distances)
(require newtypes)
(require raw-candle)

(struct trade
  [id : TradeId]               ; assigned by treasury at funding time
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker (for trigger routing)
  [phase : TradePhase]         ; :active → :runner → :settled-*
  [source-asset : Asset]       ; what was deployed
  [target-asset : Asset]       ; what was acquired
  [side : Side]                ; copied from the funding Proposal
  [entry-rate : f64]
  [entry-atr : f64]            ; from candle.atr at funding time
  [source-amount : f64]        ; how much was deployed
  [stop-levels : Levels]       ; absolute price levels, updated by step 3c
  [candles-held : usize]       ; how long open
  [price-history : Vec<f64>])  ; close prices from entry to now

(define (make-trade [id : TradeId] [post-idx : usize] [slot-idx : usize]
                    [source : Asset] [target : Asset]
                    [side : Side] [entry-rate : f64] [entry-atr : f64]
                    [amount : f64] [stop-lvls : Levels])
  : Trade
  (trade id post-idx slot-idx :active source target side
         entry-rate entry-atr amount stop-lvls
         0 (list entry-rate)))

;; Append a candle's close price to the trade's history.
(define (trade-tick [t : Trade] [current-price : f64])
  (push! (:price-history t) current-price)
  (inc! (:candles-held t)))
