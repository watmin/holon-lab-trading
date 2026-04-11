;; ── log-entry.wat ───────────────────────────────────────────────────
;;
;; The glass box. What happened. Generic. Each function returns its
;; log entries as values. Seven variants.
;; Depends on: enums, newtypes, distances.

(require enums)
(require newtypes)
(require distances)

;; ── Enum ────────────────────────────────────────────────────────

(enum log-entry
  (ProposalSubmitted
    broker-slot-idx    ; usize
    composed-thought   ; Vector
    distances)         ; Distances

  (ProposalFunded
    trade-id           ; TradeId
    broker-slot-idx    ; usize
    amount-reserved)   ; f64

  (ProposalRejected
    broker-slot-idx    ; usize
    reason)            ; String

  (TradeSettled
    trade-id           ; TradeId
    outcome            ; Outcome — :grace or :violence
    amount             ; f64
    duration           ; usize — candles held
    prediction)        ; Prediction — from TradeOrigin

  (PaperResolved
    broker-slot-idx    ; usize
    outcome            ; Outcome — :grace or :violence
    optimal-distances) ; Distances

  (Propagated
    broker-slot-idx    ; usize
    observers-updated) ; usize — how many observers received the outcome

  (Diagnostic
    candle             ; usize — candle index
    throughput         ; f64   — candles per second
    cache-hits         ; usize
    cache-misses       ; usize
    cache-size         ; usize — current LRU cache occupancy
    equity             ; f64   — current equity
    ;; Per-candle timing breakdown (microseconds)
    us-settle          ; u64
    us-tick            ; u64
    us-observers       ; u64
    us-grid            ; u64
    us-brokers         ; u64
    us-propagate       ; u64
    us-triggers        ; u64
    us-fund            ; u64
    us-total           ; u64
    ;; Counts
    num-settlements    ; usize
    num-resolutions    ; usize
    num-active-trades)); usize
