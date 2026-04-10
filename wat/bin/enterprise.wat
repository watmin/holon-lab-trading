;; bin/enterprise.wat — the outer shell
;; Depends on: everything
;; Drives the fold, writes the ledger. Does not think.

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

;; ── CLI Configuration ──────────────────────────────────────────────

(struct cli-config
  [dims : usize]                       ; default 10000
  [recalib-interval : usize]           ; default 500
  [denomination : String]              ; default "USD"
  [assets : Vec<(String, f64)>]        ; (name, initial-balance)
  [data-sources : Vec<String>]         ; parquet paths or websocket URLs
  [max-candles : usize]                ; 0 = run all
  [swap-fee : f64]                     ; default 0.0010
  [slippage : f64]                     ; default 0.0025
  [max-window-size : usize]            ; default 2016
  [ledger-path : String]               ; SQLite path
  [update-cost : f64])                 ; default 0.0 (configurable)

(define (default-config)
  : CliConfig
  (cli-config 10000 500 "USD"
    (list (list "USDC" 10000.0) (list "WBTC" 0.0))
    '() 0 0.0010 0.0025 2016 "run.db" 0.0))

;; ── Construction ───────────────────────────────────────────────────
;; Build the world, then the machine.

(define (build-enterprise [config : CliConfig])
  : (Enterprise Ctx)
  (let ((dims (:dims config))
        (recalib-interval (:recalib-interval config))

        ;; Build ctx
        (vm (make-vector-manager dims))
        (te (make-thought-encoder vm))
        (c (make-ctx te dims recalib-interval))

        ;; Build assets
        (asset-list (map (lambda (pair) (make-asset (first pair))) (:assets config)))
        (initial-balances
          (fold (lambda (m pair)
                  (assoc m (make-asset (first pair)) (second pair)))
                (map-of)
                (:assets config)))

        ;; Build posts — one per asset pair
        ;; For now: source = first asset, target = second asset
        (source (nth asset-list 0))
        (target (nth asset-list 1))

        ;; MarketLens variants
        (market-lenses '(:momentum :structure :volume :narrative :regime :generalist))
        (n (length market-lenses))

        ;; ExitLens variants
        (exit-lenses '(:volatility :structure :timing :generalist))
        (m (length exit-lenses))

        ;; Build market observers
        (market-observers
          (map (lambda (pair)
                 (let (((i lens) pair)
                       (seed (+ 7919 (* i 1000))))
                   (make-market-observer lens dims recalib-interval
                     (make-window-sampler seed 12 (:max-window-size config)))))
               (map (lambda (i) (list i (nth market-lenses i)))
                    (range 0 n))))

        ;; Build exit observers
        (exit-observers
          (map (lambda (lens)
                 (make-exit-observer lens dims recalib-interval
                   0.015 0.030 0.045 0.030))
               exit-lenses))

        ;; Build brokers — N×M grid
        (registry
          (map (lambda (slot-idx)
                 (let ((mi (/ slot-idx m))
                       (ei (mod slot-idx m))
                       (market-name (format "{}" (nth market-lenses mi)))
                       (exit-name (format "{}" (nth exit-lenses ei))))
                   (make-broker
                     (list market-name exit-name)
                     slot-idx m dims recalib-interval
                     (list (make-scalar-accumulator "trail-distance" :log)
                           (make-scalar-accumulator "stop-distance" :log)
                           (make-scalar-accumulator "tp-distance" :log)
                           (make-scalar-accumulator "runner-trail-distance" :log)))))
               (range 0 (* n m))))

        ;; Build the post
        (the-post (make-post 0 source target dims recalib-interval
                    (:max-window-size config)
                    (make-indicator-bank) market-observers exit-observers registry))

        ;; Build treasury
        (denom (make-asset (:denomination config)))
        (the-treasury (make-treasury denom initial-balances
                        (:swap-fee config) (:slippage config)))

        ;; Build enterprise
        (ent (make-enterprise (list the-post) the-treasury)))

    (list ent c)))

;; ── Ledger ─────────────────────────────────────────────────────────
;; Initialize SQLite database for this run.

(struct ledger
  [path : String]
  [batch : Vec<LogEntry>]
  [batch-size : usize])

(define (make-ledger [path : String])
  : Ledger
  ;; Create tables: meta, log
  (ledger path '() 1000))

(define (flush-ledger [l : Ledger] [entries : Vec<LogEntry>])
  : Ledger
  (let ((new-batch (append (:batch l) entries)))
    (if (>= (length new-batch) (:batch-size l))
      ;; Flush to DB
      (begin
        (for-each (lambda (entry)
                    ;; Write entry to SQLite log table
                    (match entry
                      ((ProposalSubmitted slot thought dists) None)
                      ((ProposalFunded tid slot amount) None)
                      ((ProposalRejected slot reason) None)
                      ((TradeSettled tid outcome amount duration pred) None)
                      ((PaperResolved slot outcome optimal) None)
                      ((Propagated slot count) None)))
                  new-batch)
        (update l :batch '()))
      (update l :batch new-batch))))

;; ── Progress ───────────────────────────────────────────────────────
;; Every N candles, display diagnostics.

(define (display-progress [ent : Enterprise] [candle-num : usize] [elapsed-ms : f64])
  : ()
  (let ((throughput (if (= elapsed-ms 0.0) 0.0
                      (/ (* (+ 0.0 candle-num) 1000.0) elapsed-ms)))
        (equity (total-equity (:treasury ent)))
        (post-ref (nth (:posts ent) 0)))
    ;; Display encode-count, throughput
    (format "candle={} throughput={:.0}/s equity={:.2}" candle-num throughput equity)
    ;; Per-observer stats
    (for-each (lambda (pair)
                (let (((i obs) pair))
                  (format "  market-{}: recalib={} experience={:.2} resolved={}"
                    (:lens obs)
                    (recalib-count (:reckoner obs))
                    (market-observer-experience obs)
                    (:resolved obs))))
              (map (lambda (i) (list i (nth (:market-observers post-ref) i)))
                   (range 0 (length (:market-observers post-ref)))))
    ;; Per-broker stats
    (for-each (lambda (pair)
                (let (((i b) pair))
                  (format "  broker-{}: papers={} grace={:.4} violence={:.4} trades={} edge={:.4}"
                    (:slot-idx b)
                    (paper-count b)
                    (:cumulative-grace b)
                    (:cumulative-violence b)
                    (:trade-count b)
                    (broker-edge b))))
              (map (lambda (i) (list i (nth (:registry post-ref) i)))
                   (range 0 (length (:registry post-ref)))))
    ;; Scalar accumulator stats
    (for-each (lambda (b)
                (for-each (lambda (acc)
                            (format "    accum-{}: count={}"
                              (:name acc) (:count acc)))
                          (:scalar-accums b)))
              (:registry post-ref))))

;; ── Summary ────────────────────────────────────────────────────────
;; After the loop completes.

(define (display-summary [ent : Enterprise] [total-candles : usize] [elapsed-ms : f64])
  : ()
  (let ((equity (total-equity (:treasury ent)))
        (throughput (if (= elapsed-ms 0.0) 0.0
                      (/ (* (+ 0.0 total-candles) 1000.0) elapsed-ms)))
        (post-ref (nth (:posts ent) 0))
        (total-trades (fold (lambda (s b) (+ s (:trade-count b))) 0
                        (:registry post-ref)))
        (total-grace (fold (lambda (s b) (+ s (:cumulative-grace b))) 0.0
                       (:registry post-ref)))
        (total-violence (fold (lambda (s b) (+ s (:cumulative-violence b))) 0.0
                          (:registry post-ref))))
    (format "=== SUMMARY ===")
    (format "candles: {} throughput: {:.0}/s" total-candles throughput)
    (format "equity: {:.2}" equity)
    (format "trades: {} grace: {:.4} violence: {:.4}"
      total-trades total-grace total-violence)
    (format "win-rate: {:.2}%"
      (if (= total-trades 0) 0.0
        (* 100.0 (/ total-grace (+ total-grace total-violence)))))))

;; ── The loop — the fold driver ─────────────────────────────────────

(define (run-enterprise [config : CliConfig] [stream : Stream<RawCandle>])
  : ()
  (let (((ent c) (build-enterprise config))
        (l (make-ledger (:ledger-path config)))
        (progress-interval 1000)
        (kill-check-interval 1000))

    ;; The fold
    (fold (lambda (state rc)
            (let (((ent ctx ledger candle-num) state))
              ;; Kill switch check
              (when (and (= (mod candle-num kill-check-interval) 0)
                         (file-exists? "trader-stop"))
                (format "Kill switch triggered at candle {}" candle-num)
                (display-summary ent candle-num 0.0)
                state)

              ;; Max candles check
              (when (and (> (:max-candles config) 0)
                         (>= candle-num (:max-candles config)))
                state)

              ;; Process candle
              (let (((new-ent logs misses) (on-candle ent rc ctx))
                    ;; Insert cache misses — the one seam
                    (new-ctx (insert-cache-misses ctx misses))
                    ;; Flush logs
                    (new-ledger (flush-ledger ledger logs))
                    (new-num (+ candle-num 1)))

                ;; Progress display
                (when (= (mod new-num progress-interval) 0)
                  (display-progress new-ent new-num 0.0))

                (list new-ent new-ctx new-ledger new-num))))

          (list ent c l 0)
          stream)

    ;; Final summary
    (display-summary ent 0 0.0)))
