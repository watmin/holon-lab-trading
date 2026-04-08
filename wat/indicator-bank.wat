; indicator-bank.wat — streaming indicator state machine. Depends on: RawCandle.
;
; Advances all indicators by one raw candle. Stateful — ring buffers,
; EMA accumulators, Wilder smoothers. One per post (one per asset pair).
; Consumes raw candles, produces enriched Candles.

(require primitives)
(require raw-candle)

;; Internal state is an implementation detail. The struct is opaque.
(struct indicator-bank ...)

;; Interface

(define (make-indicator-bank)
  ; → IndicatorBank
  ; Creates a fresh indicator bank with zeroed accumulators.
  (make-indicator-bank))

(define (tick [bank : IndicatorBank]
              [raw  : RawCandle])
  : Candle
  ; Advances all streaming indicators by one raw candle.
  ; Returns an enriched Candle with raw OHLCV + 100+ computed indicators.
  (tick-indicator-bank bank raw))
