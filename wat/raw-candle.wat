;; raw-candle.wat — Asset and RawCandle
;; Depends on: nothing

(require primitives)

;; ── Asset ──────────────────────────────────────────────────────────
;; A named token. The identity of a currency or commodity.

(struct asset
  [name : String])

(define (make-asset [name : String])
  : Asset
  (asset name))

;; ── RawCandle ──────────────────────────────────────────────────────
;; The enterprise's only input. Eight fields. From the parquet,
;; from the websocket. The asset pair IS the routing key.

(struct raw-candle
  [source-asset : Asset]
  [target-asset : Asset]
  [ts : String]
  [open : f64]
  [high : f64]
  [low : f64]
  [close : f64]
  [volume : f64])

(define (make-raw-candle [source-asset : Asset]
                         [target-asset : Asset]
                         [ts : String]
                         [open : f64]
                         [high : f64]
                         [low : f64]
                         [close : f64]
                         [volume : f64])
  : RawCandle
  (raw-candle source-asset target-asset ts open high low close volume))
