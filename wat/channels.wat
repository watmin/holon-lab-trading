;; ── channels.wat — the enterprise's communication contract ─────────
;;
;; Producers always emit. Consumers subscribe with filters.
;; The channel delivers. The consumer decides what matters.
;;
;; No information is lost. Every thought is recorded.
;; The filter is the consumer's policy, not the system's architecture.

;; ── Channel ─────────────────────────────────────────────────────────
;;
;; A channel is a named, typed, append-only stream.
;; Producers emit messages. Consumers subscribe with filter expressions.
;; The channel does not filter, transform, or drop messages.

(define-contract channel
  :name    string        ; unique identifier
  :type    type          ; message schema
  :policy  append-only)  ; messages are never deleted or modified

;; ── Producer contract ───────────────────────────────────────────────
;;
;; A producer emits to a channel on every heartbeat (candle).
;; Emission is unconditional. The producer does not know who listens.
;; The producer does not know if anyone listens.

(define-contract producer
  :channel  channel
  :emit     (fn (heartbeat) → message)  ; always produces
  :filter   none                         ; never self-censors
  :frequency every-heartbeat)            ; never skips

;; ── Consumer contract ───────────────────────────────────────────────
;;
;; A consumer subscribes to one or more channels with a filter expression.
;; The filter is the consumer's choice — the channel doesn't enforce it.
;; The consumer processes matching messages and ignores the rest.

(define-contract consumer
  :channels  (list channel)
  :filter    (fn (message) → bool)       ; consumer-defined predicate
  :process   (fn (message) → effect))    ; what to do with matching messages

;; ── Filter expressions ──────────────────────────────────────────────
;;
;; Filters are composable predicates. The consumer builds them.
;;
;; Built-in filter primitives:
;;   (always)                    — receive everything
;;   (gate-open? expert)         — only when expert's curve validates
;;   (conviction> threshold)     — only above a conviction level
;;   (direction= Buy)            — only BUY predictions
;;   (and filter1 filter2)       — both must pass
;;   (or filter1 filter2)        — either passes
;;   (not filter)                — invert

;; ── Enterprise channels ─────────────────────────────────────────────

;; Market expert channels: one per expert
;; Message: { direction, conviction, raw_cos, thought_vector, gate_status }
(channel "momentum"   :type expert-prediction)
(channel "structure"   :type expert-prediction)
(channel "volume"      :type expert-prediction)
(channel "narrative"   :type expert-prediction)
(channel "regime"      :type expert-prediction)
(channel "generalist"  :type expert-prediction)

;; Manager channel: the enterprise decision
;; Message: { direction, conviction, proven_experts, band_status }
(channel "manager"     :type manager-decision)

;; Position channel: one message per open position per candle
;; Message: { pos_id, direction, pnl, hold_candles, mfe, mae, stop_dist, phase }
(channel "positions"   :type position-state)

;; Treasury channel: portfolio state per candle
;; Message: { balances, deployed, utilization, total_value, alpha }
(channel "treasury"    :type treasury-state)

;; ── Subscription table ──────────────────────────────────────────────
;;
;; Who listens to what, and with what filter.

;; Manager subscribes to expert channels
;;   Filter: gate-open? — only proven voices inform decisions
;;   But this is the MANAGER'S choice. It could subscribe to all.
(subscribe "manager" → "momentum"
  :filter (gate-open? momentum)
  :process (bind momentum-atom (bind action magnitude)))

(subscribe "manager" → "structure"
  :filter (gate-open? structure)
  :process (bind structure-atom (bind action magnitude)))

;; ... same for all expert channels

;; Risk subscribes to ALL expert channels
;;   Filter: always — risk needs the full picture
(subscribe "risk" → "momentum"   :filter (always) :process (observe risk-journal))
(subscribe "risk" → "structure"  :filter (always) :process (observe risk-journal))
(subscribe "risk" → "volume"     :filter (always) :process (observe risk-journal))
(subscribe "risk" → "narrative"  :filter (always) :process (observe risk-journal))
(subscribe "risk" → "regime"     :filter (always) :process (observe risk-journal))
(subscribe "risk" → "generalist" :filter (always) :process (observe risk-journal))

;; Risk also subscribes to treasury state
(subscribe "risk" → "treasury"   :filter (always) :process (observe risk-portfolio))

;; Exit expert subscribes to position channel
(subscribe "exit" → "positions"
  :filter (position-open?)
  :process (observe exit-journal position-state))

;; Treasury subscribes to manager decisions
(subscribe "treasury" → "manager"
  :filter (and (band-valid?) (conviction-in-band?))
  :process (execute-swap))

;; Ledger subscribes to EVERYTHING
;;   Filter: always. The ledger records all. It hallucinates nothing.
(subscribe "ledger" → "*"
  :filter (always)
  :process (record))

;; ── Contract guarantees ─────────────────────────────────────────────
;;
;; 1. Producers never skip. Every candle, every expert emits.
;; 2. Channels never drop. Every message is available to all subscribers.
;; 3. Filters never mutate. They select, they don't transform.
;; 4. The ledger sees everything. No message escapes recording.
;; 5. Consumers are independent. One consumer's filter doesn't affect another's.
;; 6. Gates are filters, not architecture. The channel doesn't know about gates.
;;
;; The channel delivers. The consumer decides what matters.
