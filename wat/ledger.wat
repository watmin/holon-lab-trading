;; ── ledger.wat — the enterprise's memory ────────────────────────────
;;
;; Subscribes to ALL channels with filter (always).
;; Records every thought, every decision, every outcome.
;; Hallucinates nothing. Every number is measured.

(require core/structural)

;; ── Tables ──────────────────────────────────────────────────────────

(struct candle-log
  step candle-idx timestamp
  tht-cos tht-conviction tht-pred
  meta-pred meta-conviction
  actual traded position-frac equity outcome-pct)

(struct trade-ledger
  step candle-idx timestamp exit-candle-idx exit-timestamp
  direction conviction high-conviction
  entry-price exit-price position-frac position-usd
  gross-return-pct swap-fee-pct slippage-pct net-return-pct
  pnl-usd equity-after
  max-favorable-pct max-adverse-pct
  crossing-candles horizon-candles outcome won exit-reason)

(struct recalib-log
  step journal cos-raw disc-strength buy-count sell-count)

(struct disc-decode
  step journal rank fact-label cosine)

(struct observer-log
  step observer conviction direction correct)

(struct risk-log
  step drawdown-pct streak-len streak-dir recent-acc equity-pct won)

(struct trade-fact
  step fact-label)

(struct trade-vector
  step won tht-data)

;; ── Interpreter ─────────────────────────────────────────────────────
;;
;; The fold says WHAT happened (LogEntry). The interpreter says WHEN to write.
;; Beckman's free monad: separate description from interpretation.
;;
;; (define (flush-logs entries conn)
;;   (for-each
;;     (lambda (entry)
;;       (match entry
;;         (candle-log fields ...)     → INSERT INTO candle_log
;;         (trade-ledger fields ...)   → INSERT INTO trade_ledger
;;         (recalib-log fields ...)    → INSERT INTO recalib_log
;;         (disc-decode fields ...)    → INSERT INTO disc_decode
;;         (observer-log fields ...)   → INSERT INTO observer_log
;;         (risk-log fields ...)       → INSERT INTO risk_log
;;         (trade-fact fields ...)     → INSERT INTO trade_facts
;;         (trade-vector fields ...)   → INSERT INTO trade_vectors
;;         batch-commit               → COMMIT))
;;     entries))

;; ── Contract ────────────────────────────────────────────────────────
;;
;; 1. The ledger never drops a message.
;; 2. The ledger never transforms a message.
;; 3. The ledger never delays a message.
;; 4. The ledger is append-only.
;; 5. The ledger is queryable (SQL).
;; 6. The ledger is the source of truth for all debugging.
;; 7. The ledger distinguishes sources: learning vs managed, paper vs live.

;; ── What the ledger does NOT do ─────────────────────────────────────
;; - Does NOT filter messages (it sees everything)
;; - Does NOT transform data (it records verbatim)
;; - Does NOT make decisions (it is passive)
;; - Does NOT predict (it measures)
;; - "The enterprise's ledger is its debugger."
