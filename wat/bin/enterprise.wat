;; bin/enterprise.wat — the outer shell. Drives the fold, writes the ledger.
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

;; ── CLI configuration ───────────────────────────────────────────────

(struct cli-config
  [dims : usize]                      ; vector dimensionality (default 10000)
  [recalib-interval : usize]          ; observations between recalibrations (default 500)
  [denomination : String]             ; what "value" means (e.g. "USD")
  [assets : Vec<(String, f64)>]       ; (name, initial-balance) pairs
  [data-sources : Vec<String>]        ; one per asset pair
  [max-candles : usize]               ; stop after N (0 = run all)
  [swap-fee : f64]                    ; per-swap venue cost as fraction
  [slippage : f64]                    ; per-swap slippage estimate
  [max-window-size : usize]           ; maximum candle history (default 2016)
  [ledger-path : String])             ; SQLite output path

;; ── Construction ────────────────────────────────────────────────────

(define (build-world [config : CliConfig])
  : (Enterprise, Ctx)
  (let ((dims (:dims config))
        (recalib-interval (:recalib-interval config))
        ;; Build ThoughtEncoder and ctx
        (vm (make-vector-manager dims))
        (te (make-thought-encoder vm))
        (ctx (make-ctx te dims recalib-interval))
        ;; Build denomination asset
        (denomination (make-asset (:denomination config)))
        ;; Build initial balances map
        (initial-balances
          (fold (lambda (acc pair)
            (assoc acc (:name (make-asset (first pair))) (second pair)))
            (map-of) (:assets config)))
        ;; Build treasury
        (treasury (make-treasury denomination initial-balances))
        ;; Build posts — one per unique asset pair
        (asset-names (map first (:assets config)))
        (posts (build-posts asset-names dims recalib-interval (:max-window-size config)))
        ;; Build enterprise
        (ent (make-enterprise posts treasury)))
    (list ent ctx)))

;; Build all posts from asset names. Each unique pair becomes a post.
(define (build-posts [asset-names : Vec<String>] [dims : usize]
                     [recalib-interval : usize] [max-window-size : usize])
  : Vec<Post>
  (let ((posts '())
        (post-idx 0))
    ;; For now: one pair (first = source, second = target)
    (when (>= (length asset-names) 2)
      (let ((source (make-asset (nth asset-names 0)))
            (target (make-asset (nth asset-names 1)))
            (bank (make-indicator-bank))
            ;; Build market observers — one per MarketLens variant
            (market-observers
              (map (lambda (lens-pair)
                (let (((lens seed) lens-pair))
                  (make-market-observer lens dims recalib-interval
                    (make-window-sampler seed 12 max-window-size))))
                (list (list :momentum 7919)
                      (list :structure 7927)
                      (list :volume 7933)
                      (list :narrative 7937)
                      (list :regime 7949)
                      (list :generalist 7951))))
            ;; Build exit observers — one per ExitLens variant
            (exit-observers
              (map (lambda (lens)
                (make-exit-observer lens dims recalib-interval
                  0.015 0.030 0.045 0.030))
                (list :volatility :structure :timing :generalist)))
            (n (length market-observers))
            (m (length exit-observers))
            ;; Build broker registry — N×M brokers
            (registry
              (apply append
                (map (lambda (mi)
                  (map (lambda (ei)
                    (let ((slot (+ (* mi m) ei))
                          (market-name (match (nth market-observers mi)
                                         (obs (match (:lens obs)
                                           (:momentum "momentum")
                                           (:structure "structure")
                                           (:volume "volume")
                                           (:narrative "narrative")
                                           (:regime "regime")
                                           (:generalist "generalist")))))
                          (exit-name (match (nth exit-observers ei)
                                      (obs (match (:lens obs)
                                        (:volatility "volatility")
                                        (:structure "structure")
                                        (:timing "timing")
                                        (:generalist "generalist"))))))
                      (make-broker (list market-name exit-name) slot m dims recalib-interval
                        (list (make-scalar-accumulator "trail-distance" :log)
                              (make-scalar-accumulator "stop-distance" :log)
                              (make-scalar-accumulator "tp-distance" :log)
                              (make-scalar-accumulator "runner-trail-distance" :log)))))
                    (range 0 m)))
                  (range 0 n)))))
        (push! posts
          (make-post post-idx source target dims recalib-interval max-window-size
                     bank market-observers exit-observers registry))))
    posts))

;; ── Ledger ──────────────────────────────────────────────────────────

(define (init-ledger [path : String] [config : CliConfig])
  ;; Initialize SQLite database with meta and log tables
  ;; meta table: run parameters
  ;; log table: receives LogEntry values
  (begin
    (sql-exec path "CREATE TABLE IF NOT EXISTS meta (key TEXT, value TEXT)")
    (sql-exec path "CREATE TABLE IF NOT EXISTS log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      candle_idx INTEGER,
      entry_type TEXT,
      broker_slot INTEGER,
      trade_id INTEGER,
      outcome TEXT,
      amount REAL,
      details TEXT)")
    ;; Insert config
    (sql-exec path (format "INSERT INTO meta VALUES ('dims', '{}')" (:dims config)))
    (sql-exec path (format "INSERT INTO meta VALUES ('recalib_interval', '{}')" (:recalib-interval config)))
    (sql-exec path (format "INSERT INTO meta VALUES ('swap_fee', '{}')" (:swap-fee config)))
    (sql-exec path (format "INSERT INTO meta VALUES ('slippage', '{}')" (:slippage config)))))

(define (flush-logs [path : String] [candle-idx : usize] [logs : Vec<LogEntry>])
  (for-each (lambda (entry)
    (match entry
      ((ProposalSubmitted slot thought dists)
        (sql-exec path (format "INSERT INTO log (candle_idx, entry_type, broker_slot) VALUES ({}, 'proposal_submitted', {})"
                        candle-idx slot)))
      ((ProposalFunded trade-id slot amount)
        (sql-exec path (format "INSERT INTO log (candle_idx, entry_type, broker_slot, trade_id, amount) VALUES ({}, 'proposal_funded', {}, {}, {})"
                        candle-idx slot trade-id amount)))
      ((ProposalRejected slot reason)
        (sql-exec path (format "INSERT INTO log (candle_idx, entry_type, broker_slot, details) VALUES ({}, 'proposal_rejected', {}, '{}')"
                        candle-idx slot reason)))
      ((TradeSettled trade-id outcome amount duration)
        (sql-exec path (format "INSERT INTO log (candle_idx, entry_type, trade_id, outcome, amount, details) VALUES ({}, 'trade_settled', {}, '{}', {}, 'duration={}')"
                        candle-idx trade-id
                        (match outcome (:grace "grace") (:violence "violence"))
                        amount duration)))
      ((PaperResolved slot outcome dists)
        (sql-exec path (format "INSERT INTO log (candle_idx, entry_type, broker_slot, outcome) VALUES ({}, 'paper_resolved', {}, '{}')"
                        candle-idx slot
                        (match outcome (:grace "grace") (:violence "violence")))))
      ((Propagated slot observers-updated)
        (sql-exec path (format "INSERT INTO log (candle_idx, entry_type, broker_slot, details) VALUES ({}, 'propagated', {}, 'observers={}')"
                        candle-idx slot observers-updated)))))
    logs))

;; ── Progress display ────────────────────────────────────────────────

(define (display-progress [ent : Enterprise] [candle-idx : usize]
                          [elapsed-secs : f64])
  (let ((throughput (if (= elapsed-secs 0.0) 0.0 (/ (+ candle-idx 0.0) elapsed-secs)))
        (equity (total-equity (:treasury ent))))
    (format "[{}] throughput={:.1}/s equity={:.2}"
            candle-idx throughput equity)
    ;; Per-post stats
    (for-each (lambda (post)
      (format "  post[{}] encode-count={}"
              (:post-idx post) (:encode-count post))
      ;; Per-broker stats
      (for-each (lambda (broker)
        (let ((gc (:cumulative-grace broker))
              (gv (:cumulative-violence broker))
              (tc (:trade-count broker))
              (pc (paper-count broker))
              (e (edge broker)))
          (format "    broker[{}] grace={:.2} violence={:.2} trades={} papers={} edge={:.4}"
                  (:slot-idx broker) gc gv tc pc e)))
        (:registry post)))
      (:posts ent))))

;; ── Summary ─────────────────────────────────────────────────────────

(define (display-summary [ent : Enterprise] [candle-idx : usize]
                         [elapsed-secs : f64])
  (let ((equity (total-equity (:treasury ent)))
        (throughput (if (= elapsed-secs 0.0) 0.0 (/ (+ candle-idx 0.0) elapsed-secs))))
    (format "=== Summary ===")
    (format "Candles processed: {}" candle-idx)
    (format "Throughput: {:.1}/s" throughput)
    (format "Final equity: {:.2}" equity)
    ;; Observer panel
    (for-each (lambda (post)
      (format "Post[{}] {}-{}" (:post-idx post)
              (:name (:source-asset post)) (:name (:target-asset post)))
      (for-each (lambda (obs)
        (format "  MarketObserver[{}] resolved={} experience={:.2}"
                (:lens obs) (:resolved obs) (experience obs)))
        (:market-observers post))
      (for-each (lambda (broker)
        (format "  Broker[{}] grace={:.2} violence={:.2} trades={}"
                (:slot-idx broker)
                (:cumulative-grace broker)
                (:cumulative-violence broker)
                (:trade-count broker)))
        (:registry post)))
      (:posts ent))))

;; ── The main loop ───────────────────────────────────────────────────

(define (main [config : CliConfig])
  ;; 1. Build the world
  (let (((ent ctx) (build-world config)))
    ;; 2. Initialize ledger
    (init-ledger (:ledger-path config) config)
    ;; 3. The fold — consume the candle stream
    (let ((candle-idx 0)
          (start-time (now))
          (progress-interval 1000)
          (kill-check-interval 1000))
      (for-each (lambda (raw-candle)
        ;; Kill switch check
        (when (and (> candle-idx 0) (= (mod candle-idx kill-check-interval) 0))
          (when (file-exists? "trader-stop")
            (format "Kill switch activated at candle {}" candle-idx)
            (display-summary ent candle-idx (elapsed-since start-time))
            (return)))
        ;; Max candles check
        (when (and (> (:max-candles config) 0) (>= candle-idx (:max-candles config)))
          (return))
        ;; Process candle
        (let (((logs misses) (on-candle ent raw-candle ctx)))
          ;; Insert cache misses — the one seam
          (insert-cache-misses ctx misses)
          ;; Flush logs to ledger
          (flush-logs (:ledger-path config) candle-idx logs)
          ;; Progress display
          (when (= (mod candle-idx progress-interval) 0)
            (display-progress ent candle-idx (elapsed-since start-time)))
          (inc! candle-idx)))
        (stream-candles (:data-sources config)))
      ;; 4. Summary
      (display-summary ent candle-idx (elapsed-since start-time)))))
