;; bin/enterprise.wat — the outer shell
;; The driver of the fold. Creates the world, feeds candles, writes the
;; ledger, displays progress. It does not think. It does not predict.
;; It does not learn. It orchestrates.
;; Depends on: everything

(require primitives)
(require raw-candle)
(require candle)
(require enums)
(require newtypes)
(require distances)
(require indicator-bank)
(require window-sampler)
(require scalar-accumulator)
(require thought-encoder)
(require ctx)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require trade)
(require settlement)
(require log-entry)
(require trade-origin)
(require post)
(require treasury)
(require enterprise)

;; ═══════════════════════════════════════════════════════════════════════
;; CLI — parse arguments
;; ═══════════════════════════════════════════════════════════════════════

(struct cli-config
  [dims : usize]
  [recalib-interval : usize]
  [denomination : String]
  [assets : Vec<(String, f64)>]
  [data-sources : Vec<String>]
  [max-candles : usize]
  [swap-fee : f64]
  [slippage : f64]
  [max-window-size : usize]
  [ledger-path : String])

(define (default-config)
  : CliConfig
  (cli-config
    10000                              ; dims
    500                                ; recalib-interval
    "USD"                              ; denomination
    (list (list "USDC" 10000.0)        ; assets
          (list "WBTC" 0.0))
    (list "data/analysis.db")          ; data-sources
    0                                  ; max-candles (0 = all)
    0.0010                             ; swap-fee (10bps)
    0.0025                             ; slippage
    2016                               ; max-window-size
    ""))                               ; ledger-path (auto-generated)

;; ═══════════════════════════════════════════════════════════════════════
;; Construction — build the world, then the machine
;; ═══════════════════════════════════════════════════════════════════════

(define (build-enterprise [config : CliConfig])
  : (Enterprise, Ctx)
  (let ((dims (:dims config))
        (recalib-interval (:recalib-interval config))
        ;; Create ctx
        (vm (make-vector-manager dims))
        (encoder (make-thought-encoder vm))
        (ctx (ctx encoder dims recalib-interval))
        ;; Create assets
        (denomination (make-asset (:denomination config)))
        (asset-pairs (list (list (make-asset "USDC") (make-asset "WBTC"))))
        ;; Build initial balances map
        (initial-balances (fold-left (lambda (m pair)
                            (let (((name amount) pair))
                              (assoc m (make-asset name) amount)))
                          (map-of) (:assets config))))

    ;; Build posts — one per asset pair
    (let ((posts
            (map (lambda (pair-and-idx)
              (let (((pair idx) pair-and-idx)
                    ((source target) pair)
                    ;; MarketLens variants
                    (market-lenses (list :momentum :structure :volume :narrative :regime :generalist))
                    ;; ExitLens variants
                    (exit-lenses (list :volatility :structure :timing :generalist))
                    (n (length market-lenses))
                    (m (length exit-lenses))
                    ;; Default exit distances
                    (default-trail 0.015)
                    (default-stop 0.030)
                    (default-tp 0.045)
                    (default-runner-trail 0.030))

                ;; Build market observers — one per MarketLens variant
                (let ((market-observers
                        (map (lambda (lens-and-seed)
                          (let (((lens seed) lens-and-seed)
                                (min-window 12)
                                (max-window (:max-window-size config))
                                (ws (make-window-sampler seed min-window max-window)))
                            (make-market-observer lens dims recalib-interval ws)))
                          ;; Each lens gets a distinct seed
                          (list (list :momentum 7919) (list :structure 7927)
                                (list :volume 7933) (list :narrative 7937)
                                (list :regime 7949) (list :generalist 7951)))))

                ;; Build exit observers — one per ExitLens variant
                (let ((exit-observers
                        (map (lambda (lens)
                          (make-exit-observer lens dims recalib-interval
                            default-trail default-stop default-tp default-runner-trail))
                          exit-lenses)))

                ;; Build broker registry — N × M brokers
                (let ((registry
                        (apply append
                          (map (lambda (mi)
                            (let ((market-lens (nth market-lenses mi))
                                  (market-name (format "{}" market-lens)))
                              (map (lambda (ei)
                                (let ((exit-lens (nth exit-lenses ei))
                                      (exit-name (format "{}" exit-lens))
                                      (slot-idx (+ (* mi m) ei))
                                      (observer-names (list market-name exit-name))
                                      (accums (list
                                        (make-scalar-accumulator "trail-distance" :log)
                                        (make-scalar-accumulator "stop-distance" :log)
                                        (make-scalar-accumulator "tp-distance" :log)
                                        (make-scalar-accumulator "runner-trail-distance" :log))))
                                  (make-broker observer-names slot-idx m dims recalib-interval accums)))
                                (range 0 m))))
                            (range 0 n)))))

                  (make-post idx source target dims recalib-interval
                    (:max-window-size config)
                    (make-indicator-bank)
                    market-observers exit-observers registry))))))
              ;; Enumerate pairs with indices
              (map (lambda (i) (list (nth asset-pairs i) i))
                   (range 0 (length asset-pairs))))))

      ;; Build treasury
      (let ((treasury (make-treasury denomination initial-balances))
            (ent (make-enterprise posts treasury)))
        (list ent ctx)))))

;; ═══════════════════════════════════════════════════════════════════════
;; Ledger — SQLite database for this run
;; ═══════════════════════════════════════════════════════════════════════

(define (init-ledger [path : String] [config : CliConfig])
  ;; Create meta table with run parameters
  ;; Create log table for LogEntry values
  ;; The Rust implementation uses rusqlite.
  (begin))

(define (flush-logs [ledger : Ledger] [entries : Vec<LogEntry>])
  ;; Batch insert log entries
  (for-each (lambda (entry)
    (match entry
      ((ProposalSubmitted slot thought dists)
        (begin)) ; INSERT INTO log ...
      ((ProposalFunded tid slot amount)
        (begin))
      ((ProposalRejected slot reason)
        (begin))
      ((TradeSettled tid outcome amount duration)
        (begin))
      ((PaperResolved slot outcome dists)
        (begin))
      ((Propagated slot observers)
        (begin))))
    entries))

;; ═══════════════════════════════════════════════════════════════════════
;; Progress — diagnostics every N candles
;; ═══════════════════════════════════════════════════════════════════════

(define (display-progress [ent : Enterprise]
                          [candle-count : usize]
                          [start-time : f64]
                          [initial-equity : f64])
  (let ((equity (total-equity (:treasury ent)))
        (elapsed (- (current-time) start-time))
        (throughput (if (= elapsed 0.0) 0.0 (/ (+ 0.0 candle-count) elapsed)))
        (return-pct (if (= initial-equity 0.0) 0.0
                      (* (/ (- equity initial-equity) initial-equity) 100.0))))
    ;; Print summary line
    (format "candles={} throughput={:.0}/s equity={:.2} return={:.2}%"
      candle-count throughput equity return-pct)
    ;; Per-observer diagnostics
    (for-each (lambda (p)
      (for-each (lambda (obs)
        (let ((reck (:reckoner obs))
              (rc (recalib-count reck))
              (exp (experience reck)))
          (format "  observer={} lens={} recalibs={} experience={:.1}"
            (:lens obs) (:lens obs) rc exp)))
        (:market-observers p))
      ;; Per-broker diagnostics
      (for-each (lambda (brk)
        (let ((grace (:cumulative-grace brk))
              (violence (:cumulative-violence brk))
              (count (:trade-count brk))
              (papers (paper-count brk))
              (brk-edge (edge brk))
              (rc (recalib-count (:reckoner brk))))
          (format "  broker={} g={:.2} v={:.2} trades={} papers={} edge={:.3} recalibs={}"
            (:observer-names brk) grace violence count papers brk-edge rc)))
        (:registry p)))
      (:posts ent))))

;; ═══════════════════════════════════════════════════════════════════════
;; The loop — the fold driver
;; ═══════════════════════════════════════════════════════════════════════

(define (run [config : CliConfig])
  ;; Build the world
  (let (((ent ctx) (build-enterprise config))
        (ledger-path (:ledger-path config))
        (initial-equity (total-equity (:treasury ent)))
        (start-time (current-time))
        (candle-count 0)
        (progress-interval 1000)
        (kill-check-interval 1000)
        (kill-file "trader-stop")
        (batch-size 100)
        (log-batch '()))

    ;; Initialize ledger
    (init-ledger ledger-path config)

    ;; The fold
    (for-each (lambda (raw-candle)
      ;; Kill switch check
      (when (and (> candle-count 0) (= (mod candle-count kill-check-interval) 0))
        (when (file-exists? kill-file)
          (format "Kill switch activated at candle {}" candle-count)
          (return)))

      ;; The candle
      (let (((log-entries cache-misses) (on-candle ent raw-candle ctx)))
        ;; The one seam: insert cache misses between candles
        (for-each (lambda (miss)
          (let (((ast vec) miss))
            (set! (:compositions (:thought-encoder ctx))
                  (assoc (:compositions (:thought-encoder ctx)) ast vec))))
          cache-misses)

        ;; Batch log entries
        (set! log-batch (append log-batch log-entries))
        (when (>= (length log-batch) batch-size)
          (flush-logs ledger-path log-batch)
          (set! log-batch '())))

      ;; Progress
      (inc! candle-count)
      (when (= (mod candle-count progress-interval) 0)
        (display-progress ent candle-count start-time initial-equity)))

      ;; The stream — from parquet or websocket
      (data-stream (:data-sources config) (:max-candles config)))

    ;; Flush remaining logs
    (when (not (empty? log-batch))
      (flush-logs ledger-path log-batch))

    ;; ═══════════════════════════════════════════════════════════════════
    ;; Summary — after the loop completes
    ;; ═══════════════════════════════════════════════════════════════════

    (let ((final-equity (total-equity (:treasury ent)))
          (return-pct (if (= initial-equity 0.0) 0.0
                        (* (/ (- final-equity initial-equity) initial-equity) 100.0)))
          (total-trades (fold + 0
                          (map (lambda (p)
                            (fold + 0 (map (lambda (brk) (:trade-count brk)) (:registry p))))
                            (:posts ent))))
          (total-grace (fold + 0.0
                         (map (lambda (p)
                           (fold + 0.0 (map (lambda (brk) (:cumulative-grace brk)) (:registry p))))
                           (:posts ent))))
          (total-violence (fold + 0.0
                            (map (lambda (p)
                              (fold + 0.0 (map (lambda (brk) (:cumulative-violence brk)) (:registry p))))
                              (:posts ent))))
          (win-rate (if (= (+ total-grace total-violence) 0.0) 0.0
                      (* (/ total-grace (+ total-grace total-violence)) 100.0))))

      (format "\n=== Summary ===")
      (format "Candles processed: {}" candle-count)
      (format "Final equity: {:.2}" final-equity)
      (format "Return: {:.2}%" return-pct)
      (format "Trades: {}" total-trades)
      (format "Win rate: {:.1}%" win-rate)
      (format "Total Grace: {:.2}" total-grace)
      (format "Total Violence: {:.2}" total-violence)

      ;; Observer panel summary
      (for-each (lambda (p)
        (format "\n--- Post {} ({} / {}) ---"
          (:post-idx p) (:name (:source-asset p)) (:name (:target-asset p)))
        (format "  encode-count: {}" (:encode-count p))
        (for-each (lambda (obs)
          (let ((reck (:reckoner obs))
                (rc (recalib-count reck)))
            (format "  market-observer lens={} recalibs={} experience={:.1}"
              (:lens obs) rc (experience reck))))
          (:market-observers p))
        (for-each (lambda (brk)
          (format "  broker {} g={:.2} v={:.2} trades={} edge={:.3} recalibs={}"
            (:observer-names brk)
            (:cumulative-grace brk)
            (:cumulative-violence brk)
            (:trade-count brk)
            (edge brk)
            (recalib-count (:reckoner brk))))
          (:registry p)))
        (:posts ent))

      (format "\nLedger: {}" ledger-path))))

;; ═══════════════════════════════════════════════════════════════════════
;; Main — entry point
;; ═══════════════════════════════════════════════════════════════════════

(define (main)
  (let ((config (parse-cli-args)))
    (run config)))
