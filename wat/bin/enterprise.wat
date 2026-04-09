;; bin/enterprise.wat — the binary. The outer shell.
;; Depends on: everything.
;; Drives the fold, writes the ledger, displays progress.

(require primitives)
(require raw-candle)
(require enums)
(require newtypes)
(require candle)
(require indicator-bank)
(require window-sampler)
(require scalar-accumulator)
(require distances)
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

;; ═══════════════════════════════════════════════════════════════════
;; CLI — configuration constants
;; ═══════════════════════════════════════════════════════════════════

(struct cli-config
  [dims : usize]
  [recalib-interval : usize]
  [denomination : String]
  [assets : Vec<(String, f64)>]
  [data-source : String]
  [max-candles : usize]
  [swap-fee : f64]
  [slippage : f64]
  [max-window-size : usize]
  [ledger-path : String])

(define (default-config)
  : CliConfig
  (cli-config
    10000           ; dims
    500             ; recalib-interval
    "USD"           ; denomination
    '(("USDC" 10000.0) ("WBTC" 0.0))  ; assets
    "data/analysis.db"  ; data-source
    0               ; max-candles (0 = all)
    0.0010          ; swap-fee
    0.0025          ; slippage
    2016            ; max-window-size
    ""))            ; ledger-path (auto-generate if empty)

;; ═══════════════════════════════════════════════════════════════════
;; Construction — build the world, then the machine
;; ═══════════════════════════════════════════════════════════════════

(define (build-enterprise [config : CliConfig])
  : (Enterprise, Ctx)
  (let ((dims (:dims config))
        (recalib-interval (:recalib-interval config))
        (max-window-size (:max-window-size config))

        ;; Build ctx
        (vm (make-vector-manager dims))
        (te (make-thought-encoder vm))
        (c (make-ctx te dims recalib-interval))

        ;; Build assets
        (denomination (make-asset (:denomination config)))
        (initial-balances (map-of))

        ;; Market lens variants — one observer per lens
        (market-lenses '(:momentum :structure :volume :narrative :regime :generalist))
        (n-market (length market-lenses))

        ;; Exit lens variants — one observer per lens
        (exit-lenses '(:volatility :structure :timing :generalist))
        (n-exit (length exit-lenses))

        ;; Default exit distances (the crutches)
        (default-trail 0.015)
        (default-stop 0.030)
        (default-tp 0.045)
        (default-runner-trail 0.030)

        ;; Window sampler seeds — one per market observer, deterministic
        (base-seed 7919))

    ;; Build initial balances from assets config
    (for-each (lambda (asset-pair)
      (let (((name balance) asset-pair)
            (asset (make-asset name)))
        (set! initial-balances asset (balance))))
      (:assets config))

    ;; Build posts — one per unique asset pair
    ;; For now: one post (USDC, WBTC)
    (let ((source (make-asset (first (first (:assets config)))))
          (target (make-asset (first (second (:assets config)))))
          (post-idx 0)

          ;; Market observers
          (market-observers
            (map (lambda (i)
              (let ((lens (nth market-lenses i))
                    (seed (+ base-seed (* i 1000)))
                    (ws (make-window-sampler seed 12 max-window-size)))
                (make-market-observer lens dims recalib-interval ws)))
              (range 0 n-market)))

          ;; Exit observers
          (exit-observers
            (map (lambda (i)
              (let ((lens (nth exit-lenses i)))
                (make-exit-observer lens dims recalib-interval
                  default-trail default-stop default-tp default-runner-trail)))
              (range 0 n-exit)))

          ;; Brokers — N×M flat vec
          (registry
            (map (lambda (slot-idx)
              (let ((mi (/ slot-idx n-exit))
                    (ei (mod slot-idx n-exit))
                    (market-name (format "{}" (nth market-lenses mi)))
                    (exit-name (format "{}" (nth exit-lenses ei)))
                    (accums (list
                      (make-scalar-accumulator "trail-distance" :log)
                      (make-scalar-accumulator "stop-distance" :log)
                      (make-scalar-accumulator "tp-distance" :log)
                      (make-scalar-accumulator "runner-trail-distance" :log))))
                (make-broker (list market-name exit-name) slot-idx n-exit
                  dims recalib-interval accums)))
              (range 0 (* n-market n-exit))))

          ;; Indicator bank
          (bank (make-indicator-bank))

          ;; Post
          (p (make-post post-idx source target dims recalib-interval
               max-window-size bank market-observers exit-observers registry))

          ;; Treasury
          (treas (make-treasury denomination initial-balances))

          ;; Enterprise
          (ent (make-enterprise (list p) treas)))

      (list ent c))))

;; ═══════════════════════════════════════════════════════════════════
;; Diagnostics — query functions exercise the wiring
;; ═══════════════════════════════════════════════════════════════════

;; paper-count — total papers across all brokers in a post
(define (diagnostic-paper-count [ent : Enterprise] [post-idx : usize])
  : usize
  (let ((p (nth (:posts ent) post-idx)))
    (fold (lambda (acc b) (+ acc (paper-count b))) 0 (:registry p))))

;; experience — average market observer experience for a post
(define (diagnostic-experience [ent : Enterprise] [post-idx : usize])
  : f64
  (let ((p (nth (:posts ent) post-idx))
        (n (length (:market-observers p))))
    (if (= n 0) 0.0
      (/ (fold (lambda (acc obs) (+ acc (market-observer-experience obs)))
           0.0 (:market-observers p))
         n))))

;; edge — average broker edge for a post
(define (diagnostic-edge [ent : Enterprise] [post-idx : usize])
  : f64
  (let ((p (nth (:posts ent) post-idx))
        (n (length (:registry p))))
    (if (= n 0) 0.0
      (/ (fold (lambda (acc b) (+ acc (broker-edge b)))
           0.0 (:registry p))
         n))))

;; recalib-count — total recalibrations across market observers
(define (diagnostic-recalib-count [ent : Enterprise] [post-idx : usize])
  : usize
  (let ((p (nth (:posts ent) post-idx)))
    (fold (lambda (acc obs) (+ acc (recalib-count (:reckoner obs))))
      0 (:market-observers p))))

;; encode-count — how many candles this post has processed
(define (diagnostic-encode-count [ent : Enterprise] [post-idx : usize])
  : usize
  (:encode-count (nth (:posts ent) post-idx)))

;; total-equity — from treasury
(define (diagnostic-total-equity [ent : Enterprise])
  : f64
  (total-equity (:treasury ent)))

;; ═══════════════════════════════════════════════════════════════════
;; Progress display — every N candles
;; ═══════════════════════════════════════════════════════════════════

(define (display-progress [ent : Enterprise] [candle-count : usize]
                          [start-equity : f64] [elapsed-ms : f64])
  (let ((post-idx 0)
        (equity (diagnostic-total-equity ent))
        (return-pct (if (= start-equity 0.0) 0.0
                      (* 100.0 (/ (- equity start-equity) start-equity))))
        (throughput (if (= elapsed-ms 0.0) 0.0
                      (/ (* candle-count 1000.0) elapsed-ms)))
        (enc-count (diagnostic-encode-count ent post-idx))
        (avg-edge (diagnostic-edge ent post-idx))
        (papers (diagnostic-paper-count ent post-idx))
        (recalibs (diagnostic-recalib-count ent post-idx))
        (experience (diagnostic-experience ent post-idx)))
    (format "[{}] equity={:.2} return={:.2}% throughput={:.0}/s edge={:.4} papers={} recalibs={} experience={:.2}"
      enc-count equity return-pct throughput avg-edge papers recalibs experience)))

;; ═══════════════════════════════════════════════════════════════════
;; The loop — the fold driver
;; ═══════════════════════════════════════════════════════════════════

(define (run-loop [ent : Enterprise] [c : Ctx] [stream : Vec<RawCandle>]
                  [config : CliConfig])
  (let ((start-equity (diagnostic-total-equity ent))
        (candle-count 0)
        (max-candles (:max-candles config))
        (kill-file "trader-stop")
        (kill-check-interval 1000)
        (progress-interval 1000)
        (all-log-entries '()))

    (for-each (lambda (raw-candle)
      ;; Kill switch check
      (when (= (mod candle-count kill-check-interval) 0)
        (when (file-exists? kill-file)
          (begin
            (format "Kill switch activated at candle {}" candle-count)
            (return))))

      ;; The fold step
      (let (((log-entries cache-misses) (on-candle ent raw-candle c)))

        ;; The one seam: insert cache misses between candles
        (insert-misses c cache-misses)

        ;; Accumulate log entries
        (set! all-log-entries (append all-log-entries log-entries))

        ;; Progress display
        (when (and (> candle-count 0) (= (mod candle-count progress-interval) 0))
          (let ((elapsed 0.0))  ; Rust provides actual elapsed time
            (display-progress ent candle-count start-equity elapsed)))

        ;; Increment
        (set! candle-count (+ candle-count 1))

        ;; Max candles check
        (when (and (> max-candles 0) (>= candle-count max-candles))
          (return))))
      stream)

    ;; ═════════════════════════════════════════════════════════════
    ;; Summary — after the loop completes
    ;; ═════════════════════════════════════════════════════════════

    (let ((final-equity (diagnostic-total-equity ent))
          (return-pct (if (= start-equity 0.0) 0.0
                        (* 100.0 (/ (- final-equity start-equity) start-equity))))
          (post-idx 0)
          (p (nth (:posts ent) post-idx)))

      (format "\n=== Summary ===")
      (format "Candles processed: {}" candle-count)
      (format "Final equity: {:.2}" final-equity)
      (format "Return: {:.2}%" return-pct)
      (format "Encode count: {}" (diagnostic-encode-count ent post-idx))
      (format "Recalibrations: {}" (diagnostic-recalib-count ent post-idx))
      (format "Average edge: {:.4}" (diagnostic-edge ent post-idx))
      (format "Total papers: {}" (diagnostic-paper-count ent post-idx))
      (format "Average experience: {:.2}" (diagnostic-experience ent post-idx))

      ;; Per-broker summary
      (format "\n--- Broker Panel ---")
      (for-each (lambda (b)
        (let ((grace (:cumulative-grace b))
              (violence (:cumulative-violence b))
              (ratio (if (= violence 0.0) f64-infinity (/ grace violence)))
              (edge (broker-edge b))
              (papers (paper-count b))
              (trades (:trade-count b)))
          (format "Broker {}: G={:.2} V={:.2} G/V={:.2} edge={:.4} papers={} trades={}"
            (:slot-idx b) grace violence ratio edge papers trades)))
        (:registry p))

      ;; Per-observer summary
      (format "\n--- Market Observer Panel ---")
      (for-each (lambda (obs)
        (let ((exp (market-observer-experience obs))
              (recalibs (recalib-count (:reckoner obs)))
              (resolved (:resolved obs)))
          (format "Observer {}: experience={:.2} recalibs={} resolved={}"
            (:lens obs) exp recalibs resolved)))
        (:market-observers p))

      (format "\n--- Exit Observer Panel ---")
      (for-each (lambda (obs)
        (let ((experienced (exit-experienced? obs)))
          (format "Exit {}: experienced={}"
            (:lens obs) experienced)))
        (:exit-observers p)))))

;; ═══════════════════════════════════════════════════════════════════
;; Main — the entry point
;; ═══════════════════════════════════════════════════════════════════

(define (main [args : Vec<String>])
  ;; Parse CLI args (the Rust handles actual parsing)
  (let ((config (default-config))
        ;; Build the world
        ((ent c) (build-enterprise config))
        ;; Load the stream (the Rust handles parquet/websocket)
        (stream (load-candle-stream (:data-source config))))
    ;; Drive the fold
    (run-loop ent c stream config)))
