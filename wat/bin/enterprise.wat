;; ── bin/enterprise.wat ──────────────────────────────────────────────
;;
;; The binary specification. The outer shell. The driver of the fold.
;; Creates the world, feeds candles, writes the ledger, displays
;; progress. It does not think. It does not predict. It does not learn.
;; It orchestrates.
;; Depends on: everything.

(require enums)
(require newtypes)
(require distances)
(require raw-candle)
(require candle)
(require indicator-bank)
(require window-sampler)
(require scalar-accumulator)
(require thought-encoder)
(require ctx)
(require proposal)
(require trade)
(require trade-origin)
(require settlement)
(require log-entry)
(require simulation)
(require post)
(require treasury)
(require enterprise)

;; ── CLI arguments ───────────────────────────────────────────────
;; The configuration that the enterprise receives as constants.

(struct cli-args
  [dims : usize]                       ; vector dimensionality (default 10000)
  [recalib-interval : usize]           ; observations between recalibrations (default 500)
  [denomination : String]              ; what "value" means (e.g. "USD")
  [assets : Vec<(String, f64)>]        ; pool of (name, initial-balance) pairs
  [data-sources : Vec<String>]         ; one data source per asset pair (parquet or websocket)
  [max-candles : usize]                ; stop after N candles (0 = run all)
  [swap-fee : f64]                     ; per-swap venue cost as fraction
  [slippage : f64]                     ; per-swap slippage estimate as fraction
  [max-window-size : usize]            ; maximum candle history (default 2016)
  [ledger : String])                   ; path to output SQLite database

;; ── Construction ────────────────────────────────────────────────
;; Build the world, then the machine.

(define (construct [args : CliArgs])
  : (Enterprise, Ctx)
  (let* ((dims (:dims args))
         (recalib-interval (:recalib-interval args))

         ;; Build ctx — the immutable world
         (ctx (make-ctx dims recalib-interval))

         ;; Build assets
         (asset-list (map (lambda (pair) (make-asset (first pair))) (:assets args)))
         (initial-balances
           (fold-left (lambda (m pair)
                        (assoc m (make-asset (first pair)) (second pair)))
                      (map-of)
                      (:assets args)))

         ;; One post per asset pair — enumerate pairs from the asset pool
         (pairs (fold-left
                  (lambda (acc i)
                    (append acc
                      (map (lambda (j) (list i j))
                           (filter (lambda (j) (!= j i))
                                   (range (len asset-list))))))
                  (list)
                  (range (len asset-list))))

         (posts
           (map (lambda (pair-with-idx)
                  (let* (((idx pair) pair-with-idx)
                         ((i j) pair)
                         (source (nth asset-list i))
                         (target (nth asset-list j))

                         ;; Indicator bank
                         (bank (make-indicator-bank))

                         ;; Market observers — one per MarketLens variant
                         (market-lenses (list :momentum :structure :volume
                                              :narrative :regime :generalist))
                         (market-observers
                           (map (lambda (lens)
                                  (make-market-observer lens dims recalib-interval
                                    (make-window-sampler (+ idx 7919) 12 (:max-window-size args))))
                                market-lenses))

                         ;; Exit observers — one per ExitLens variant
                         (exit-lenses (list :volatility :structure :timing :generalist))
                         (exit-observers
                           (map (lambda (lens)
                                  (make-exit-observer lens dims recalib-interval
                                    0.015 0.030))
                                exit-lenses))

                         ;; Brokers — N x M grid
                         (n (len market-lenses))
                         (m (len exit-lenses))
                         (registry
                           (map (lambda (slot-idx)
                                  (let ((market-idx (/ slot-idx m))
                                        (exit-idx (mod slot-idx m)))
                                    (make-broker
                                      (list (nth market-lenses market-idx)
                                            (nth exit-lenses exit-idx))
                                      slot-idx m dims recalib-interval
                                      (list (make-scalar-accumulator "trail-distance" :log)
                                            (make-scalar-accumulator "stop-distance" :log)))))
                                (range (* n m)))))

                    (make-post idx source target dims recalib-interval
                      (:max-window-size args) bank
                      market-observers exit-observers registry)))
                (map (lambda (i) (list i (nth pairs i))) (range (len pairs)))))

         ;; Treasury
         (treasury (make-treasury
                     (make-asset (:denomination args))
                     initial-balances
                     (:swap-fee args)
                     (:slippage args)))

         ;; Enterprise
         (ent (make-enterprise posts treasury)))

    (list ent ctx)))

;; ── Ledger ──────────────────────────────────────────────────────
;; Initialize SQLite database for this run.

(define (init-ledger [path : String] [args : CliArgs])
  : Ledger
  ;; Create meta table — run parameters
  ;; Create log table — receives LogEntry values from on-candle
  ;; The ledger is the glass box. The DB is the debugger.
  (make-ledger path args))

;; ── The fold ────────────────────────────────────────────────────
;; The main loop. The driver of the enterprise.

(define (run [args : CliArgs])
  : ()
  (let* (((ent ctx) (construct args))
         (ledger (init-ledger (:ledger args) args))
         (stream (open-parquet-stream (:data-sources args)))
         (progress-interval 1000)
         (kill-file "trader-stop"))

    ;; The fold — one raw candle at a time
    (fold-left
      (lambda (count raw-candle)
        ;; Kill switch — check every 1000 candles
        (when (and (> count 0) (= (mod count progress-interval) 0))
          (when (file-exists? kill-file)
            (begin (display "Kill switch activated. Aborting.")
                   (summary ent ledger count)
                   (abort))))

        ;; Max candles — stop if reached
        (when (and (> (:max-candles args) 0) (>= count (:max-candles args)))
          (begin (summary ent ledger count)
                 (abort)))

        ;; The heartbeat — one candle through the enterprise
        (let* (((log-entries cache-misses) (on-candle ent raw-candle ctx))

               ;; The one seam — insert cache misses between candles
               (_ (insert-misses ctx cache-misses))

               ;; Flush log entries to ledger (in batches)
               (_ (flush-logs ledger log-entries count))

               ;; Increment price history on all active trades
               (_ (for-each
                    (lambda (entry)
                      (let (((trade-id trade) entry))
                        (begin
                          (push! (:price-history trade) (:close raw-candle))
                          (inc! (:candles-held trade)))))
                    (:trades (:treasury ent)))))

          ;; Progress display
          (when (= (mod (+ count 1) progress-interval) 0)
            (progress ent count))

          (+ count 1)))
      0
      stream)

    ;; Summary — after the loop completes
    (summary ent ledger (len stream))))

;; ── Progress ────────────────────────────────────────────────────
;; Every N candles, display diagnostics.

(define (progress [ent : Enterprise] [count : usize])
  : ()
  ;; encode-count, throughput (candles/second)
  ;; treasury equity, return vs buy-and-hold
  ;; per-observer stats (recalib count, discriminant strength)
  ;; broker stats (paper count, Grace/Violence ratio, curves proven)
  ;; accumulation (residue earned per side)
  (let* ((equity (total-equity (:treasury ent))))
    (display (format "candle {} | equity {:.2}" count equity))))

;; ── Summary ─────────────────────────────────────────────────────
;; After the loop completes.

(define (summary [ent : Enterprise] [ledger : Ledger] [count : usize])
  : ()
  ;; Final equity, return percentage, buy-and-hold comparison
  ;; Trade count, win rate, accumulation totals
  ;; Venue costs paid
  ;; Observer panel summary
  ;; Ledger path and row count
  (let* ((equity (total-equity (:treasury ent)))
         (treasury (:treasury ent)))
    (begin
      (display (format "=== Run Summary ==="))
      (display (format "Candles processed: {}" count))
      (display (format "Final equity: {:.2}" equity))
      (display (format "Ledger: {}" (:path ledger))))))
