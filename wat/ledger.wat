;; ── ledger.wat — the enterprise's memory ────────────────────────────
;;
;; The ledger subscribes to ALL channels with filter (always).
;; It records every thought, every decision, every outcome.
;; It hallucinates nothing. Every number is measured.
;;
;; The ledger is the DB. The DB is the debugger. The state is the breakpoint.

;; ── Subscription ────────────────────────────────────────────────────
;;
;; (subscribe "ledger" → "*" :filter (always) :process (record))
;;
;; The wildcard subscription: every channel, every message.
;; The ledger is the only subscriber that sees EVERYTHING.
;; Not even risk sees everything — risk sees expert + treasury channels.
;; The ledger sees expert + manager + risk + treasury + position channels.

;; ── Tables ──────────────────────────────────────────────────────────
;;
;; candle_log:       per-candle state (thought + manager prediction, outcome)
;; trade_ledger:     per-position lifecycle (entry, exits, P&L, costs)
;; recalib_log:      per-recalibration state (disc_strength, cos_raw)
;; disc_decode:      top discriminant facts at each recalibration
;; observer_log:     per-observer predictions (diagnostics)
;; risk_log:         per-trade risk state (diagnostics)
;; trade_facts:      fact attribution for traded candles (diagnostics)
;; trade_vectors:    thought vectors for engram analysis (diagnostics)
;;
;; Future:
;; channel_log:      every message on every channel (full enterprise trace)
;; alpha_log:        per-swap counterfactual comparison
;; exit_log:         per-position exit expert observations

;; ── Contract ────────────────────────────────────────────────────────
;;
;; 1. The ledger never drops a message.
;; 2. The ledger never transforms a message.
;; 3. The ledger never delays a message.
;; 4. The ledger is append-only.
;; 5. The ledger is queryable (SQL).
;; 6. The ledger is the source of truth for all debugging.
;; 7. The ledger distinguishes sources: learning vs managed, paper vs live.
;;
;; "The enterprise's ledger is its debugger."
