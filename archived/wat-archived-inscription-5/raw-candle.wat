;; raw-candle.wat — Asset + RawCandle
;; Depends on: nothing
;; The only input to the enterprise. Everything else is derived.

(require primitives)

;; Asset — a named token. The routing key.
(struct asset
  [name : String])

(define (make-asset [name : String])
  : Asset
  (asset name))

;; RawCandle — one period of market data, tagged with its asset pair.
;; From the parquet. From the websocket. The enterprise doesn't care which.
(struct raw-candle
  [source-asset : Asset]   ; e.g. USDC — what is deployed
  [target-asset : Asset]   ; e.g. WBTC — what is acquired
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
