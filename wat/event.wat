;; -- event.wat -- the enterprise's input vocabulary --------------------------
;;
;; The enterprise is a fold over Stream<EnrichedEvent>.
;; Every input is an event. The enterprise doesn't know where events come from.
;; Backtest, websocket, test harness -- same event, same fold.

(require core/structural)
(require candle)

;; -- Event (source vocabulary) ----------------------------------------------

;; rune:reap(scaffolding) -- Event and all stream constructors are never used
;; outside this file. The enterprise folds over EnrichedEvent, not Event.
;; Wired when streaming interface replaces backtest loop.

;; Raw event before encoding. Used by stream constructors.
;; The fold consumes EnrichedEvent, not Event.

(struct event/candle
  asset                  ; string -- which asset
  candle)                ; Candle

(struct event/deposit
  asset
  amount)                ; f64

(struct event/withdraw
  asset
  amount)                ; f64

(define (event-asset event)
  "Which asset does this event concern?"
  (match event
    (event/candle e)   (:asset e)
    (event/deposit e)  (:asset e)
    (event/withdraw e) (:asset e)))

(define (event-timestamp event)
  "Timestamp for ordering merged streams."
  (match event
    (event/candle e)   (:ts (:candle e))
    _                  ""))

;; -- EnrichedEvent (the fold's input) ---------------------------------------

;; Carries pre-computed encoding products.
;; The backtest runner pre-encodes in parallel, then wraps results.
;; A live runner would encode per-candle.

(struct enriched/candle
  candle                 ; Candle
  fact-labels            ; (list string) -- human-readable fact labels
  observer-vecs)         ; (list Vector) -- one per observer profile

;; rune:reap(scaffolding) -- Deposit and Withdraw variants are matched in
;; on_event but never constructed anywhere. Wired when streaming interface
;; supports capital events.
(struct enriched/deposit
  asset amount)

(struct enriched/withdraw
  asset amount)

;; -- Stream constructors ----------------------------------------------------

(define (stream-from-candles candles asset)
  "Wrap loaded candles into an event stream. Zero-copy of candle data."
  (map (lambda (c) (event/candle :asset asset :candle c)) candles))

(define (stream-from-db db-path asset label-col)
  "Load a single asset's candles from DB and produce an event stream."
  (stream-from-candles (load-candles db-path label-col) asset))

(define (merge-streams streams)
  "Merge multiple event streams by timestamp. Sorted -- enterprise processes in time order.
   This is the bridge to multi-asset: each asset's stream is merged into one."
  (sort-by event-timestamp (flatten streams)))

(define (with-recurring-deposits events asset amount interval)
  "Inject a deposit every `interval` candles. The system evolves with new capital."
  ;; Appends deposits and re-sorts by timestamp.
  ;; Proper interleaving would insert at the right timestamp.
  events)

;; -- What events do NOT do --------------------------------------------------
;; - Do NOT carry encoding logic (that's thought/mod.rs)
;; - Do NOT know about the enterprise fold (that's enterprise.rs)
;; - Do NOT filter or transform (they are raw input)
;; - Events are the vocabulary. EnrichedEvent is the fold's input.
