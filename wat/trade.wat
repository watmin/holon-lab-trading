;; trade.wat — Trade struct
;; Depends on: enums, distances, newtypes, raw-candle (Asset)

(require primitives)
(require enums)
(require distances)
(require newtypes)
(require raw-candle)

(struct trade
  [id : TradeId]               ; assigned by treasury at funding time
  [post-idx : usize]
  [broker-slot-idx : usize]
  [phase : TradePhase]         ; :active → :runner → :settled-*
  [source-asset : Asset]
  [target-asset : Asset]
  [side : Side]
  [entry-rate : f64]
  [source-amount : f64]        ; how much was deployed
  [stop-levels : Levels]       ; current absolute price levels
  [candles-held : usize]
  [price-history : Vec<f64>])  ; close prices from entry to now

(define (make-trade [id : TradeId]
                    [post-idx : usize]
                    [broker-slot-idx : usize]
                    [side : Side]
                    [source-asset : Asset]
                    [target-asset : Asset]
                    [entry-rate : f64]
                    [source-amount : f64]
                    [stop-levels : Levels])
  : Trade
  (trade id post-idx broker-slot-idx :active
    source-asset target-asset side entry-rate source-amount
    stop-levels 0 (list entry-rate)))

;; Append a close price to the trade's history and increment candles-held
(define (trade-tick [t : Trade] [current-price : f64])
  : Trade
  (update t
    :candles-held (+ (:candles-held t) 1)
    :price-history (append (:price-history t) (list current-price))))
