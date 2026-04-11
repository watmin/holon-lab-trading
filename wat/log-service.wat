;; ── log-service.wat ─────────────────────────────────────────────
;;
;; Log writer as a single-threaded pipe loop.
;;
;; Each producer gets a LogHandle at construction. The IO is declared.
;; The producer doesn't know about SQLite. It has a Sender<LogEntry>.
;; The log writer drains all pipes and writes to the DB.
;;
;; One thread. N pipes. One SQLite connection. No contention.
;; The pipe IS the IO monad. The type says "I produce log events."
;;
;; Depends on: log-entry, enums.

(require log-entry)
(require enums)

;; ── LogHandle — a producer's log pipe ───────────────────────────
;; Moved into the producing thread at construction.
;; Fire and forget. The producer writes and continues.
;; The handle IS the IO declaration. The type says "I produce log events."

(struct log-handle
  [emit : Sender<LogEntry>])              ; unbounded, fire and forget

;; Fire and forget. The log writer drains this.
(define (log [h : LogHandle] [entry : LogEntry])
  : ()
  (send (:emit h) entry))

;; ── LogService — owns the writer thread ─────────────────────────

(struct log-service
  [handle       : JoinHandle<()>]
  [rows-written : Arc<AtomicUsize>])      ; total rows committed

;; ── Spawn — create the service + N handles ──────────────────────
;; The SQLite connection is MOVED into the thread. One owner. No sharing.

(define (spawn [n-producers : usize] [conn : Connection])
  : (LogService, Vec<LogHandle>)

  ;; Create N unbounded pipes. One per producer.
  (let ((handles '())
        (drains '()))
    (for-each (range n-producers)
      (let (((emit-tx drain-rx) (unbounded-channel))) ; LogEntry
        (push! handles (make-log-handle emit-tx))
        (push! drains drain-rx)))

    (let ((rows (arc (atomic 0))))

      ;; Spawn the writer thread
      (let ((handle
              (thread-spawn
                (lambda ()
                  (let ((closed (vec-of false n-producers))
                        (BATCH-SIZE 100))

                    ;; WAL mode — readers don't block on writers.
                    ;; The DB is always queryable.
                    (execute-batch conn "PRAGMA journal_mode=WAL;")

                    ;; Prepared statements — one for log rows, one for diagnostics.
                    (let ((log-stmt
                            (prepare-cached conn
                              "INSERT INTO log (kind, broker_slot_idx, trade_id, outcome, amount, duration, reason, observers_updated)
                               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"))
                          (diag-stmt
                            (prepare-cached conn
                              "INSERT OR REPLACE INTO diagnostics (candle, throughput, cache_hits, cache_misses, cache_hit_pct, cache_size, equity, us_settle, us_tick, us_observers, us_grid, us_brokers, us_propagate, us_triggers, us_fund, us_total, num_settlements, num_resolutions, num_active_trades)
                               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)")))

                      (loop
                        (let ((did-work false)
                              (batch-count 0))

                          ;; BEGIN a batch transaction. One sync per batch, not per row.
                          (execute-batch conn "BEGIN")

                          ;; Drain all pipes. Write what we find.
                          ;; Commit every BATCH-SIZE rows.
                          (for-each (range n-producers)
                            (lambda (i)
                              (when (not (get closed i))
                                (loop
                                  (match (try-recv (get drains i))
                                    ((Ok entry)
                                      (write-entry log-stmt diag-stmt entry)
                                      (fetch-add! rows 1)
                                      (set! did-work true)
                                      (set! batch-count (+ batch-count 1))
                                      (when (>= batch-count BATCH-SIZE)
                                        (execute-batch conn "COMMIT; BEGIN")
                                        (set! batch-count 0)))
                                    ((Err Empty) (break))
                                    ((Err Disconnected)
                                      (set! closed i true)
                                      (break)))))))

                          ;; Commit whatever remains in the batch
                          (execute-batch conn "COMMIT")

                          ;; Shutdown: all pipes closed — drain remaining buffered entries
                          (when (all? closed)
                            (execute-batch conn "BEGIN")
                            (let ((final-count 0))
                              (for-each drains
                                (lambda (drain)
                                  (while-let ((Ok entry) (try-recv drain))
                                    (write-entry log-stmt diag-stmt entry)
                                    (fetch-add! rows 1)
                                    (set! final-count (+ final-count 1))
                                    (when (= 0 (mod final-count BATCH-SIZE))
                                      (execute-batch conn "COMMIT; BEGIN"))))))
                            (execute-batch conn "COMMIT")
                            (break))

                          ;; Block until ANY log pipe has data. Zero CPU when idle.
                          (when (not did-work)
                            (select-ready
                              (filter-indexed drains (not closed))))))))))))

        (list (make-log-service handle rows)
              handles)))))

;; ── write-entry — match variant, execute the right statement ────
;; Log variants go to the log table. Diagnostic goes to diagnostics.
;; cache-hit-pct is computed on write (derived, not stored in the entry).

(define (write-entry [log-stmt : Statement] [diag-stmt : Statement] [entry : LogEntry])
  : ()
  (match entry
    ((ProposalSubmitted broker-slot-idx _ _)
      (execute log-stmt
        "ProposalSubmitted" broker-slot-idx nil nil nil nil nil nil))

    ((ProposalFunded trade-id broker-slot-idx amount-reserved)
      (execute log-stmt
        "ProposalFunded" broker-slot-idx trade-id nil amount-reserved nil nil nil))

    ((ProposalRejected broker-slot-idx reason)
      (execute log-stmt
        "ProposalRejected" broker-slot-idx nil nil nil nil reason nil))

    ((TradeSettled trade-id outcome amount duration _)
      (execute log-stmt
        "TradeSettled" nil trade-id (outcome->string outcome) amount duration nil nil))

    ((PaperResolved broker-slot-idx outcome _)
      (execute log-stmt
        "PaperResolved" broker-slot-idx nil (outcome->string outcome) nil nil nil nil))

    ((Propagated broker-slot-idx observers-updated)
      (execute log-stmt
        "Propagated" broker-slot-idx nil nil nil nil nil observers-updated))

    ((Diagnostic candle throughput cache-hits cache-misses cache-size equity
                 us-settle us-tick us-observers us-grid us-brokers
                 us-propagate us-triggers us-fund us-total
                 num-settlements num-resolutions num-active-trades)
      (let ((hit-pct (if (> (+ cache-hits cache-misses) 0)
                       (* 100.0 (/ cache-hits (+ cache-hits cache-misses)))
                       0.0)))
        (execute diag-stmt
          candle throughput cache-hits cache-misses hit-pct cache-size equity
          us-settle us-tick us-observers us-grid us-brokers
          us-propagate us-triggers us-fund us-total
          num-settlements num-resolutions num-active-trades)))))

;; ── Shutdown ────────────────────────────────────────────────────
;; All LogHandles must be dropped first (cascade).
;; The writer drains remaining buffered entries, then exits.

(define (shutdown [svc : LogService])
  : ()
  (join (:handle svc)))

;; ── Accessor ────────────────────────────────────────────────────

(define (rows [svc : LogService]) : usize
  (load (:rows-written svc)))
