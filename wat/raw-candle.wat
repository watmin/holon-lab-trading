; raw-candle.wat — the input leaf
;
; Depends on: nothing.
; The enterprise consumes a stream of raw candles. This is the only input.
; Everything else is derived. Each raw candle identifies its asset pair —
; the pair IS the routing key. Only the post for that pair receives it.

; ── Asset — a named token ───────────────────────────────────────────────

(struct asset
  [name : String])

; ── RawCandle — eight fields, from parquet or websocket ─────────────────

(struct raw-candle
  [source-asset : Asset]   ; e.g. USDC
  [target-asset : Asset]   ; e.g. WBTC
  [ts : String]
  [open : f64]
  [high : f64]
  [low : f64]
  [close : f64]
  [volume : f64])

; ── Constructors ────────────────────────────────────────────────────────

(define (make-asset [name : String])
  : Asset
  (Asset name))

(define (make-raw-candle [source : Asset]
                         [target : Asset]
                         [ts : String]
                         [open : f64]
                         [high : f64]
                         [low : f64]
                         [close : f64]
                         [volume : f64])
  : RawCandle
  (RawCandle source target ts open high low close volume))
