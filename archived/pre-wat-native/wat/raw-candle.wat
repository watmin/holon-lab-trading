;; ── raw-candle.wat ──────────────────────────────────────────────────
;;
;; The input data types. Asset identifies a token. RawCandle is the
;; enterprise's only input — everything else is derived.
;; Depends on: nothing.

;; Asset: a named token (e.g. "USDC", "WBTC").
(struct asset
  [name : String])

;; RawCandle: one period of market data. Eight fields.
;; From the parquet. From the websocket. The enterprise doesn't care which.
;; The asset pair IS the routing key — only the post for that pair receives it.
(struct raw-candle
  [source-asset : Asset]   ; e.g. USDC — what is deployed
  [target-asset : Asset]   ; e.g. WBTC — what is acquired
  [ts : String]
  [open : f64]
  [high : f64]
  [low : f64]
  [close : f64]
  [volume : f64])
