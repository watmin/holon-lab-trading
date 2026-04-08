;; -- event.wat -- the enterprise's input vocabulary --------------------------
;;
;; The enterprise is a fold over Stream<Event>.
;; Every input is an event. The enterprise doesn't know where events come from.
;; Backtest, websocket, test harness -- same event, same fold.
;;
;; The event carries raw OHLCV. No pre-computed indicators. No pre-encoded
;; thoughts. Each desk computes its own indicators from the raw candle.

(require core/structural)
(require candle)

;; -- Event (the fold's input) ------------------------------------------------
;;
;; One raw candle at a time. Five numbers and a timestamp.
;; The desk steps its indicator bank to produce computed indicators.

(enum event
  (candle raw-candle)              ; raw OHLCV — the only input that matters
  (deposit asset amount)           ; capital deposited into treasury
  (withdraw asset amount))         ; capital withdrawn from treasury

;; -- What events do NOT do --------------------------------------------------
;; - Do NOT carry pre-computed indicators (that's the desk's indicator bank)
;; - Do NOT carry pre-encoded thoughts (that's the desk's thought encoder)
;; - Do NOT carry observer vectors (that's the desk's observer panel)
;; - Events are raw input. The desk derives everything.
