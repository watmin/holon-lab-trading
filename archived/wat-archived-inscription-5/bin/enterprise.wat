;; bin/enterprise.wat — the outer shell
;; Depends on: everything
;; Drives the fold. Writes the ledger. Does not think.

(require primitives)
(require raw-candle)
(require indicator-bank)
(require candle)
(require enums)
(require newtypes)
(require distances)
(require window-sampler)
(require scalar-accumulator)
(require engram-gate)
(require thought-encoder)
(require ctx)
(require market-observer)
(require exit-observer)
(require paper-entry)
(require broker)
(require proposal)
(require trade)
(require settlement)
(require trade-origin)
(require log-entry)
(require post)
(require treasury)
(require enterprise)
(require simulation)

;; ══════════════════════════════════════════════════════════════════════
;; CLI arguments
;; ══════════════════════════════════════════════════════════════════════

(struct cli-config
  [dims : usize]                       ; vector dimensionality (default 10000)
  [recalib-interval : usize]           ; observations between recalibrations (default 500)
  [denomination : String]              ; e.g. "USD"
  [assets : Vec<(String, f64)>]        ; (name, initial-balance) pairs
  [data-sources : Vec<String>]         ; parquet paths or websocket URLs
  [max-candles : usize]                ; 0 = run all
  [swap-fee : f64]                     ; per-swap venue cost as fraction
  [slippage : f64]                     ; per-swap slippage estimate
  [max-window-size : usize]            ; maximum candle history (default 2016)
  [ledger-path : String])              ; output SQLite path

(define (default-config)
  : CliConfig
  (cli-config 10000 500 "USD"
    (list (list "USDC" 10000.0) (list "WBTC" 0.0))
    (list "data/analysis.db")
    0 0.0010 0.0025 2016 ""))

;; ══════════════════════════════════════════════════════════════════════
;; Construction — build the world, then the machine
;; ══════════════════════════════════════════════════════════════════════

;; Market lens variants — one observer per lens
(define market-lenses
  (list :momentum :structure :volume :narrative :regime :generalist))

;; Exit lens variants
(define exit-lenses
  (list :volatility :structure :timing :generalist))

;; Build a market observer for a given lens
(define (build-market-observer [lens : MarketLens] [dims : usize]
                               [recalib-interval : usize] [seed : usize])
  : MarketObserver
  (make-market-observer lens
    (Discrete dims recalib-interval '("Up" "Down"))
    (make-window-sampler seed 12 2016)))

;; Build an exit observer for a given lens
(define (build-exit-observer [lens : ExitLens] [dims : usize]
                             [recalib-interval : usize])
  : ExitObserver
  (make-exit-observer lens dims recalib-interval
    0.015   ; default-trail
    0.030   ; default-stop
    0.045   ; default-tp
    0.030)) ; default-runner-trail

;; Build scalar accumulators for a broker — one per distance
(define (build-scalar-accums)
  : Vec<ScalarAccumulator>
  (list
    (make-scalar-accumulator "trail-distance" :log)
    (make-scalar-accumulator "stop-distance" :log)
    (make-scalar-accumulator "tp-distance" :log)
    (make-scalar-accumulator "runner-trail-distance" :log)))

;; Build the broker registry — N×M brokers
(define (build-registry [market-obs : Vec<MarketObserver>]
                        [exit-obs : Vec<ExitObserver>]
                        [dims : usize] [recalib-interval : usize])
  : Vec<Broker>
  (let ((n (len market-obs))
        (m (len exit-obs)))
    (map (lambda (slot-idx)
      (let ((mi (/ slot-idx m))
            (ei (mod slot-idx m))
            (market-name (match (:lens (nth market-obs mi))
                           (:momentum "momentum") (:structure "structure")
                           (:volume "volume") (:narrative "narrative")
                           (:regime "regime") (:generalist "generalist")))
            (exit-name (match (:lens (nth exit-obs ei))
                         (:volatility "volatility") (:structure "structure")
                         (:timing "timing") (:generalist "generalist"))))
        (make-broker
          (list market-name exit-name)
          slot-idx m dims recalib-interval
          (build-scalar-accums))))
      (range 0 (* n m)))))

;; Build one post for an asset pair
(define (build-post [post-idx : usize] [source : Asset] [target : Asset]
                    [dims : usize] [recalib-interval : usize]
                    [max-window-size : usize])
  : Post
  (let ((market-obs (map (lambda (i)
                      (let ((lens (nth market-lenses i)))
                        (build-market-observer lens dims recalib-interval
                          (+ 7919 (* i 1000)))))
                      (range 0 (len market-lenses))))
        (exit-obs (map (lambda (i)
                    (let ((lens (nth exit-lenses i)))
                      (build-exit-observer lens dims recalib-interval)))
                    (range 0 (len exit-lenses))))
        (registry (build-registry market-obs exit-obs dims recalib-interval)))
    (make-post post-idx source target dims recalib-interval max-window-size
      (make-indicator-bank) market-obs exit-obs registry)))

;; Build the whole enterprise
(define (build-enterprise [config : CliConfig])
  : (Enterprise, Ctx)
  ;; Build ctx
  (let ((vm (make-vector-manager (:dims config)))
        (te (make-thought-encoder vm))
        (c  (make-ctx te (:dims config) (:recalib-interval config))))
    ;; Build posts — one per unique asset pair
    (let ((assets (:assets config))
          (n-assets (len assets))
          (post-idx 0)
          (posts '()))
      ;; For each pair of assets, create a post
      ;; Today: one pair (first = source, second = target)
      (when (>= n-assets 2)
        (let ((source (make-asset (first (nth assets 0))))
              (target (make-asset (first (nth assets 1))))
              (p (build-post 0 source target
                   (:dims config) (:recalib-interval config)
                   (:max-window-size config))))
          (set! posts (list p))))
      ;; Build treasury
      (let ((balances (fold (lambda (acc pair)
                        (assoc acc (make-asset (first pair)) (second pair)))
                      (map-of) assets))
            (treas (make-treasury (make-asset (:denomination config)) balances)))
        (list (make-enterprise posts treas) c)))))

;; ══════════════════════════════════════════════════════════════════════
;; The loop — the fold driver
;; ══════════════════════════════════════════════════════════════════════

;; Initialize ledger — create SQLite database for this run
(define (init-ledger [path : String] [config : CliConfig])
  ;; Creates meta and log tables.
  ;; Implementation: SQLite via Rust bindings.
  'ledger-initialized)

;; Flush log entries to ledger in batches
(define (flush-logs [ledger : Ledger] [logs : Vec<LogEntry>])
  (for-each (lambda (entry)
    ;; Insert each log entry into the SQLite log table
    (match entry
      ((ProposalSubmitted slot thought distances)
        'insert-proposal-submitted)
      ((ProposalFunded trade-id slot amount)
        'insert-proposal-funded)
      ((ProposalRejected slot reason)
        'insert-proposal-rejected)
      ((TradeSettled trade-id outcome amount duration)
        'insert-trade-settled)
      ((PaperResolved slot outcome optimal)
        'insert-paper-resolved)
      ((Propagated slot observers)
        'insert-propagated)))
    logs))

;; Check kill switch — file "trader-stop"
(define (kill-switch?)
  : bool
  ;; Check if the file exists. Implementation: std::path::Path::exists
  false)  ; the Rust implements the filesystem check

;; Display progress diagnostics
(define (display-progress [ent : Enterprise] [candle-count : usize] [elapsed-secs : f64])
  (let ((throughput (if (= elapsed-secs 0.0) 0.0
                      (/ (+ 0.0 candle-count) elapsed-secs)))
        (equity (total-equity (:treasury ent))))
    (format "candle={} throughput={:.0}/s equity={:.2}"
            candle-count throughput equity)))

;; ══════════════════════════════════════════════════════════════════════
;; main — the entry point
;; ══════════════════════════════════════════════════════════════════════

(define (main [config : CliConfig])
  ;; 1. Build the world
  (let (((ent c) (build-enterprise config))
        (ledger (init-ledger (:ledger-path config) config))
        (candle-count 0)
        (log-batch '()))

    ;; 2. The loop — the fold driver
    (for-each (lambda (raw-candle)
      ;; Kill switch check every 1000 candles
      (when (and (> candle-count 0) (= (mod candle-count 1000) 0))
        (when (kill-switch?)
          'abort))  ; in Rust: break or return

      ;; Process one candle
      (let (((logs misses) (on-candle ent raw-candle c)))
        ;; The one seam: insert cache misses between candles
        (insert-cache-misses c misses)
        ;; Batch log entries
        (set! log-batch (append log-batch logs))
        ;; Flush every 100 candles
        (when (= (mod candle-count 100) 0)
          (flush-logs ledger log-batch)
          (set! log-batch '()))
        ;; Progress display every 5000 candles
        (when (and (> candle-count 0) (= (mod candle-count 5000) 0))
          (display-progress ent candle-count 0.0)))

      (inc! candle-count)

      ;; Max candles check
      (when (and (> (:max-candles config) 0)
                 (>= candle-count (:max-candles config)))
        'stop))  ; in Rust: break

      ;; The stream — from parquet or websocket
      (read-candle-stream (:data-sources config)))

    ;; 3. Flush remaining logs
    (flush-logs ledger log-batch)

    ;; 4. Summary
    (let ((equity (total-equity (:treasury ent)))
          (trade-count (fold + 0
            (map (lambda (p)
              (fold + 0 (map (lambda (b) (:trade-count b)) (:registry p))))
              (:posts ent)))))
      (format "Final equity: {:.2} | Trades: {} | Candles: {}"
              equity trade-count candle-count))))
