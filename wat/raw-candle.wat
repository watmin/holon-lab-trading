; raw-candle.wat — the input. Depends on nothing.
;
; The enterprise consumes a stream of raw candles. This is the only input.
; Everything else is derived. Each raw candle identifies its asset pair —
; the pair IS the routing key. Only the post for that pair receives it.

(require primitives)

;; Asset — a named token. The routing identity.
(struct asset
  name)               ; String

;; RawCandle — eight fields. From the parquet. From the websocket.
;; The enterprise doesn't care which. The asset pair IS the identity
;; of the stream.
(struct raw-candle
  source-asset        ; Asset — e.g. USDC
  target-asset        ; Asset — e.g. WBTC
  ts                  ; String — timestamp
  open                ; f64
  high                ; f64
  low                 ; f64
  close               ; f64
  volume)             ; f64
