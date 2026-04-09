;; raw-candle.wat — Asset and RawCandle
;; Depends on: nothing

(require primitives)

;; ── Asset — a named token ─────────────────────────────────────────────
(struct asset
  [name : String])

(define (make-asset [name : String])
  : Asset
  (asset name))

;; ── RawCandle — the enterprise's sole input ───────────────────────────
;; Eight fields. From the parquet. From the websocket. The enterprise
;; doesn't care which. The asset pair IS the identity of the stream.
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
