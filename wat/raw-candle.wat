;; raw-candle.wat — Asset and RawCandle
;; Depends on: nothing

(require primitives)

;; Asset — a named token. USDC, WBTC, SOL, USD.
(struct asset
  [name : String])

(define (make-asset [name : String])
  : Asset
  (asset name))

;; RawCandle — the input. Eight fields. From parquet. From websocket.
;; The enterprise doesn't care which. The asset pair IS the routing key.
(struct raw-candle
  [source-asset : Asset]   ; e.g. USDC
  [target-asset : Asset]   ; e.g. WBTC
  [ts : String]
  [open : f64]
  [high : f64]
  [low : f64]
  [close : f64]
  [volume : f64])

(define (make-raw-candle [source : Asset] [target : Asset]
                         [ts : String]
                         [open : f64] [high : f64] [low : f64]
                         [close : f64] [volume : f64])
  : RawCandle
  (raw-candle source target ts open high low close volume))
