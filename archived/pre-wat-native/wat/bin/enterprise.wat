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
(require market-observer)
(require exit-observer)
(require broker)
(require encoder-service)
(require log-service)

;; ── Constants ──────────────────────────────────────────────────

;; Max learn signals to drain per candle per thread.
;; The reckoner is a CRDT — deferral is safe. The queue drains over
;; subsequent candles. Production rate ~1/candle. Drain rate 5/candle.
;; The queue converges to empty.
(define MAX-DRAIN 5)

(define MARKET-LENSES (list :momentum :structure :volume
                            :narrative :regime :generalist))

(define EXIT-LENSES (list :volatility :structure :timing :generalist))

;; ── CLI arguments ───────────────────────────────────────────────
;; The configuration that the enterprise receives as constants.

(struct cli-args
  [dims : usize]                       ; vector dimensionality (default 10000)
  [recalib-interval : usize]           ; observations between recalibrations (default 500)
  [denomination : String]              ; what "value" means (e.g. "USD")
  [source-asset : String]              ; source asset name (e.g. "USDC")
  [target-asset : String]              ; target asset name (e.g. "WBTC")
  [source-balance : f64]               ; initial balance for the source asset (default 10000.0)
  [target-balance : f64]               ; initial balance for the target asset (default 0.0)
  [parquet : String]                   ; raw OHLCV parquet file path
  [ledger : String]                    ; path to output SQLite database (optional, auto-generated)
  [max-candles : usize]                ; stop after N candles (0 = run all)
  [swap-fee : f64]                     ; per-swap venue cost as fraction (default 0.0010)
  [slippage : f64]                     ; per-swap slippage estimate as fraction (default 0.0025)
  [max-window-size : usize])           ; maximum candle history (default 2016)

;; ── Pipe type aliases ─────────────────────────────────────────
;; Named for clarity. These are the values that cross pipe boundaries.

;; ObsInput:     (Candle, Arc<Vec<Candle>>, usize)
;;   — enriched candle, shared window snapshot, encode count
;; ObsOutput:    (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
;;   — thought, prediction, edge, cache misses
;; ObsLearn:     (Vector, Direction, f64)
;;   — composed thought, direction, weight
;; BrokerInput:  (Vector, Distances, f64, Side, f64, Prediction)
;;   — composed thought, distances, price, side, edge, prediction
;; BrokerOutput: (Proposal, Vec<Resolution>)
;;   — proposal for treasury, paper resolutions
;; BrokerLearn:  (Vector, Outcome, f64, Direction, Distances)
;;   — composed thought, outcome, weight, direction, optimal distances

;; ── Ledger ──────────────────────────────────────────────────────
;; Initialize SQLite database for this run.
;; Four tables: meta (key-value config), brokers (slot→lens mapping),
;; log (event stream), diagnostics (per-candle timing + counts).

(define (create-ledger [path : String])
  : Connection
  (let ((conn (open-sqlite path)))
    (execute-batch conn
      "CREATE TABLE IF NOT EXISTS meta (
         key   TEXT PRIMARY KEY,
         value TEXT
       );
       CREATE TABLE IF NOT EXISTS brokers (
         slot_idx      INTEGER PRIMARY KEY,
         market_lens   TEXT NOT NULL,
         exit_lens     TEXT NOT NULL
       );
       CREATE TABLE IF NOT EXISTS log (
         step              INTEGER PRIMARY KEY AUTOINCREMENT,
         kind              TEXT NOT NULL,
         broker_slot_idx   INTEGER,
         trade_id          INTEGER,
         outcome           TEXT,
         amount            REAL,
         duration          INTEGER,
         reason            TEXT,
         observers_updated INTEGER
       );
       CREATE TABLE IF NOT EXISTS diagnostics (
         candle            INTEGER PRIMARY KEY,
         throughput        REAL,
         cache_hits        INTEGER,
         cache_misses      INTEGER,
         cache_hit_pct     REAL,
         cache_size        INTEGER,
         equity            REAL,
         us_settle         INTEGER,
         us_tick           INTEGER,
         us_observers      INTEGER,
         us_grid           INTEGER,
         us_brokers        INTEGER,
         us_propagate      INTEGER,
         us_triggers       INTEGER,
         us_fund           INTEGER,
         us_total          INTEGER,
         num_settlements   INTEGER,
         num_resolutions   INTEGER,
         num_active_trades INTEGER
       );")
    conn))

;; Register broker lens names into the brokers table.
(define (register-brokers [conn : Connection] [post : Post])
  : ()
  (let ((m (len (:exit-observers post))))
    (for-each (:registry post)
      (lambda (broker)
        (let ((mi (/ (:slot-idx broker) m))
              (ei (mod (:slot-idx broker) m)))
          (execute conn
            "INSERT INTO brokers (slot_idx, market_lens, exit_lens) VALUES (?1, ?2, ?3)"
            (list (:slot-idx broker)
                  (format "{}" (nth (:market-observers post) mi :lens))
                  (format "{}" (nth (:exit-observers post) ei :lens)))))))))

;; Write log entries to the log table. Dispatches on LogEntry variant.
(define (flush-logs [logs : Vec<LogEntry>] [conn : Connection])
  : ()
  (for-each logs
    (lambda (entry)
      (match entry
        ((LogEntry/ProposalSubmitted broker-slot-idx)
          (execute conn "INSERT INTO log (kind, broker_slot_idx) VALUES (?1, ?2)"
            (list "ProposalSubmitted" broker-slot-idx)))
        ((LogEntry/ProposalFunded trade-id broker-slot-idx amount-reserved)
          (execute conn "INSERT INTO log (kind, broker_slot_idx, trade_id, amount) VALUES (?1, ?2, ?3, ?4)"
            (list "ProposalFunded" broker-slot-idx trade-id amount-reserved)))
        ((LogEntry/ProposalRejected broker-slot-idx reason)
          (execute conn "INSERT INTO log (kind, broker_slot_idx, reason) VALUES (?1, ?2, ?3)"
            (list "ProposalRejected" broker-slot-idx reason)))
        ((LogEntry/TradeSettled trade-id outcome amount duration)
          (execute conn "INSERT INTO log (kind, trade_id, outcome, amount, duration) VALUES (?1, ?2, ?3, ?4, ?5)"
            (list "TradeSettled" trade-id (format "{}" outcome) amount duration)))
        ((LogEntry/PaperResolved broker-slot-idx outcome)
          (execute conn "INSERT INTO log (kind, broker_slot_idx, outcome) VALUES (?1, ?2, ?3)"
            (list "PaperResolved" broker-slot-idx (format "{}" outcome))))
        ((LogEntry/Propagated broker-slot-idx observers-updated)
          (execute conn "INSERT INTO log (kind, broker_slot_idx, observers_updated) VALUES (?1, ?2, ?3)"
            (list "Propagated" broker-slot-idx observers-updated)))
        ((LogEntry/Diagnostic _)
          ;; Diagnostics go to the diagnostics table, not the log table.
          ;; Handled by the log service directly.
          ())))))

;; ── Construction ────────────────────────────────────────────────
;; Build the world, then the machine.

(define (build-enterprise [args : CliArgs])
  : (Enterprise, Ctx)
  (let* ((dims (:dims args))
         (recalib-interval (:recalib-interval args))

         ;; Build ctx — the immutable world
         (ctx (make-ctx dims recalib-interval))

         ;; Single asset pair
         (source (make-asset (:source-asset args)))
         (target (make-asset (:target-asset args)))

         (n (len MARKET-LENSES))
         (m (len EXIT-LENSES))

         ;; Market observers — one per MarketLens variant
         ;; Each gets a unique seed offset for its window sampler.
         (market-observers
           (map (lambda (i lens)
                  (make-market-observer lens dims recalib-interval
                    (make-window-sampler (+ 7919 (* i 1000)) 12
                                         (:max-window-size args))))
                (enumerate MARKET-LENSES)))

         ;; Exit observers — one per ExitLens variant
         ;; Default trail 0.015, default stop 0.030.
         (exit-observers
           (map (lambda (lens)
                  (make-exit-observer lens dims recalib-interval
                    0.015 0.030))
                EXIT-LENSES))

         ;; Brokers — N x M grid
         ;; Each broker binds one market observer to one exit observer.
         ;; Two scalar accumulators: trail-distance and stop-distance, both log-encoded.
         (registry
           (map (lambda (slot-idx)
                  (let ((mi (/ slot-idx m))
                        (ei (mod slot-idx m))
                        (market-name (format "{}" (nth MARKET-LENSES mi)))
                        (exit-name (format "{}" (nth EXIT-LENSES ei))))
                    (make-broker
                      (list market-name exit-name)
                      slot-idx m dims recalib-interval
                      (list (make-scalar-accumulator "trail-distance" :log dims)
                            (make-scalar-accumulator "stop-distance" :log dims)))))
                (range (* n m))))

         ;; The post — one per asset pair
         (the-post (make-post 0 source target
                     (make-indicator-bank)
                     (:max-window-size args)
                     market-observers exit-observers registry))

         ;; Treasury — available vs reserved capital
         (initial-balances
           (assoc (assoc (map-of)
                    (:source-asset args) (:source-balance args))
                  (:target-asset args) (:target-balance args)))
         (the-treasury (make-treasury
                         (make-asset (:denomination args))
                         initial-balances
                         (:swap-fee args)
                         (:slippage args)))

         ;; Enterprise
         (ent (make-enterprise (list the-post) the-treasury)))

    (list ent ctx)))

;; ── Progress ────────────────────────────────────────────────────
;; Every 50 candles, display stats to stderr.

(define (display-progress [ent : Enterprise] [candle-num : usize] [elapsed-ms : f64])
  : ()
  (let ((throughput (if (= elapsed-ms 0.0) 0.0
                      (/ (* candle-num 1000.0) elapsed-ms)))
        (equity (total-equity (:treasury ent))))
    (eprintln "  candle={} throughput={:.0}/s equity={:.2}"
      candle-num throughput equity)
    (for-each (:posts ent)
      (lambda (post)
        (for-each (:market-observers post)
          (lambda (obs)
            (eprintln "    market-{}: recalib={} experience={:.2} resolved={}"
              (:lens obs) (recalib-count (:reckoner obs))
              (experience obs) (:resolved obs))))
        (for-each (:registry post)
          (lambda (b)
            (eprintln "    broker-{}: papers={} grace={:.4} violence={:.4} trades={} edge={:.4}"
              (:slot-idx b) (paper-count b)
              (:cumulative-grace b) (:cumulative-violence b)
              (:trade-count b) (edge b))))))))

;; ── Summary ─────────────────────────────────────────────────────
;; After the loop completes. Final stats.

(define (display-summary [ent : Enterprise]
                         [total-candles : usize]
                         [elapsed-ms : f64]
                         [bnh-entry : f64]
                         [last-close : f64]
                         [swap-fee : f64]
                         [slippage : f64]
                         [log-rows : usize]
                         [ledger-path : String])
  : ()
  (let* ((equity (total-equity (:treasury ent)))
         (throughput (if (= elapsed-ms 0.0) 0.0
                      (/ (* total-candles 1000.0) elapsed-ms)))
         (total-trades (sum (flat-map (:posts ent)
                              (lambda (p) (map (lambda (b) (:trade-count b))
                                               (:registry p))))))
         (total-grace (sum (flat-map (:posts ent)
                             (lambda (p) (map (lambda (b) (:cumulative-grace b))
                                              (:registry p))))))
         (total-violence (sum (flat-map (:posts ent)
                                (lambda (p) (map (lambda (b) (:cumulative-violence b))
                                                 (:registry p))))))
         (win-rate (if (= total-trades 0) 0.0
                     (* (/ total-grace (+ total-grace total-violence)) 100.0)))
         (initial-equity (sum (append (values (:available (:treasury ent)))
                                      (values (:reserved (:treasury ent))))))
         (ret (if (= initial-equity 0.0) 0.0
                (* (/ (- equity initial-equity) initial-equity) 100.0)))
         (bnh-ret (if (= bnh-entry 0.0) 0.0
                    (* (/ (- last-close bnh-entry) bnh-entry) 100.0)))
         (venue-rt (* 2.0 (+ swap-fee slippage) 100.0)))

    (eprintln "=== SUMMARY ===")
    (eprintln "  candles: {} throughput: {:.0}/s" total-candles throughput)
    (eprintln "  equity: {:.2} ({:+.2}%)" equity ret)
    (eprintln "  buy-and-hold: {:+.2}%" bnh-ret)
    (eprintln "  trades: {} grace: {:.4} violence: {:.4}"
      total-trades total-grace total-violence)
    (eprintln "  win-rate: {:.2}%" win-rate)
    (when (or (> swap-fee 0.0) (> slippage 0.0))
      (eprintln "  venue: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip"
        (* swap-fee 10000.0) (* slippage 10000.0) venue-rt))

    (eprintln "  Observer panel:")
    (for-each (:posts ent)
      (lambda (post)
        (for-each (:market-observers post)
          (lambda (obs)
            (eprintln "    {}: recalib={} experience={:.2} resolved={}"
              (:lens obs) (recalib-count (:reckoner obs))
              (experience obs) (:resolved obs))))))

    (eprintln "  Run DB: {} ({} rows)" ledger-path log-rows)
    (eprintln "===============")))

;; ── The fold ────────────────────────────────────────────────────
;; The main loop. The driver of the enterprise.

(define (run [args : CliArgs])
  : ()
  (let* (((ent ctx) (build-enterprise args))
         (n (len MARKET-LENSES))
         (m (len EXIT-LENSES))

         ;; ── Parquet stream ──
         (total-candles (parquet-total-candles (:parquet args)))
         (stream (open-parquet-stream (:parquet args) (:source-asset args) (:target-asset args)))

         ;; ── Ledger ──
         (ledger-path (or (:ledger args)
                        (format "runs/enterprise_{}.db" (utc-now-fmt "%Y%m%d_%H%M%S"))))
         (ledger (create-ledger ledger-path))

         ;; Write meta table — all args + total candles
         (_ (for-each (list (list "binary" "enterprise")
                            (list "dims" (to-string (:dims args)))
                            (list "recalib_interval" (to-string (:recalib-interval args)))
                            (list "denomination" (:denomination args))
                            (list "source_asset" (:source-asset args))
                            (list "target_asset" (:target-asset args))
                            (list "source_balance" (to-string (:source-balance args)))
                            (list "target_balance" (to-string (:target-balance args)))
                            (list "max_candles" (to-string (:max-candles args)))
                            (list "swap_fee" (to-string (:swap-fee args)))
                            (list "slippage" (to-string (:slippage args)))
                            (list "max_window_size" (to-string (:max-window-size args)))
                            (list "total_candles" (to-string total-candles)))
              (lambda (kv)
                (execute ledger
                  "INSERT INTO meta (key,value) VALUES (?1,?2)"
                  kv))))

         ;; Register broker lens names
         (_ (for-each (:posts ent) (lambda (post) (register-brokers ledger post))))

         ;; ── Shared immutable context ──
         (ctx-arc (arc ctx))

         ;; ── Encoder service — the cache as a pipe ──
         ;; N observer handles + N*M grid handles + 1 step-3c handle
         (n-encoder-callers (+ n (* n m) 1))
         ((encoder-service encoder-handles)
           (encoder-service-spawn n-encoder-callers 65536))
         ;; Split handles: observers get [0..n], grid gets [n..n+n*m], step3c gets the last
         (step3c-handle (pop! encoder-handles))
         (grid-handles (drain! encoder-handles n))
         (obs-encoder-handles encoder-handles)

         ;; ── Log service — the DB writer as a pipe ──
         ;; One handle for the main thread. The log service owns the SQLite connection.
         ((log-service log-handles)
           (log-service-spawn 1 ledger))
         (log-handle (pop! log-handles))

         ;; ── Per-post pipe wiring ──
         ;; One set of pipes per asset pair. No magic index.
         ;; Each observer and broker is taken from the post, moved onto a thread,
         ;; and returned via join on shutdown.
         (all-pipes
           (map (lambda (post)
                  (let ((obs-txs '())
                        (thought-rxs '())
                        (learn-txs '())
                        (observer-handles '())
                        (broker-in-txs '())
                        (broker-out-rxs '())
                        (broker-learn-txs '())
                        (broker-handles '()))

                    ;; ── Observer pipes + threads ──
                    ;; bounded(1) input/output = lock-step = lazy enumerator
                    ;; unbounded learn = CRDT deferral
                    (for-each (range n)
                      (lambda (i)
                        (let (((obs-tx obs-rx)       (make-pipe :capacity 1 :carries ObsInput))
                              ((thought-tx thought-rx) (make-pipe :capacity 1 :carries ObsOutput))
                              ((learn-tx learn-rx)     (make-pipe :capacity :unbounded :carries ObsLearn)))
                          (push! obs-txs obs-tx)
                          (push! thought-rxs thought-rx)
                          (push! learn-txs learn-tx)

                          (let ((obs (take! (:market-observers post) i))
                                (enc-handle (pop! obs-encoder-handles))
                                (lens (:lens obs))
                                (recalib (:recalib-interval args)))
                            (push! observer-handles
                              (spawn
                                (lambda ()
                                  ;; Observer thread: drain learn, encode, observe, send
                                  (loop
                                    (match (recv obs-rx)
                                      ((Some (candle window encode-count))

                                        ;; Drain at most MAX-DRAIN learn signals.
                                        ;; The reckoner is a CRDT — deferral is safe.
                                        (let ((drained 0))
                                          (loop
                                            (when (>= drained MAX-DRAIN) (break))
                                            (match (try-recv learn-rx)
                                              ((Some (thought direction weight))
                                                (resolve obs thought direction weight recalib)
                                                (set! drained (+ drained 1)))
                                              (None (break)))))

                                        ;; Encode candle facts via cache pipe
                                        (let* ((facts (market-lens-facts lens candle window))
                                               (bundle-ast (ThoughtAST/Bundle facts))
                                               (thought (match (encoder-get enc-handle bundle-ast)
                                                          ((Some cached) cached)
                                                          (None
                                                            (let (((vec _) (encode (:thought-encoder ctx-arc) bundle-ast)))
                                                              (encoder-set enc-handle bundle-ast vec)
                                                              vec))))
                                               ;; Observe — reckoner updates, returns prediction
                                               (result (observe obs thought '())))

                                          ;; Send thought + prediction + edge downstream
                                          (send thought-tx
                                            (list (:thought result) (:prediction result)
                                                  (:edge result) '()))))

                                      (None (break))))
                                  ;; Return observer for restoration on shutdown
                                  obs)))))))

                    ;; ── Broker pipes + threads ──
                    ;; bounded(1) input/output, unbounded learn
                    (for-each (range (* n m))
                      (lambda (slot-idx)
                        (let (((in-tx in-rx)         (make-pipe :capacity 1 :carries BrokerInput))
                              ((out-tx out-rx)       (make-pipe :capacity 1 :carries BrokerOutput))
                              ((blearn-tx blearn-rx) (make-pipe :capacity :unbounded :carries BrokerLearn)))
                          (push! broker-in-txs in-tx)
                          (push! broker-out-rxs out-rx)
                          (push! broker-learn-txs blearn-tx)

                          (let ((broker (take! (:registry post) slot-idx))
                                (src (:source-asset post))
                                (tgt (:target-asset post))
                                (post-idx-for-broker (len all-pipes))  ; current post index
                                (recalib (:recalib-interval args)))
                            (push! broker-handles
                              (spawn
                                (lambda ()
                                  ;; Broker thread: drain learn, propose, register paper, tick, send
                                  (loop
                                    (match (recv in-rx)
                                      ((Some (composed dists price side edge pred))

                                        ;; Drain at most MAX-DRAIN learn signals.
                                        ;; The reckoner is a CRDT. Deferral is safe.
                                        (let ((drained 0))
                                          (loop
                                            (when (>= drained MAX-DRAIN) (break))
                                            (match (try-recv blearn-rx)
                                              ((Some (thought outcome weight direction optimal))
                                                (propagate broker thought outcome weight
                                                  direction optimal recalib
                                                  (scalar-encoder-placeholder))
                                                (set! drained (+ drained 1)))
                                              (None (break)))))

                                        ;; Propose — reckoner updates
                                        (propose broker composed)
                                        ;; Register paper trade for accountability tracking
                                        (register-paper broker (clone composed) price dists)
                                        ;; Tick active paper trades at current price
                                        (let ((resolutions (tick-papers broker price))
                                              (prop (make-proposal composed dists edge side
                                                      src tgt pred
                                                      post-idx-for-broker (:slot-idx broker))))
                                          (send out-tx (list prop resolutions))))

                                      (None (break))))
                                  ;; Return broker for restoration on shutdown
                                  broker)))))))

                    ;; Return pipe bundle for this post
                    (list (:source-asset post) (:target-asset post)
                          obs-txs thought-rxs learn-txs observer-handles
                          broker-in-txs broker-out-rxs broker-learn-txs broker-handles
                          n m)))
                (:posts ent)))

         ;; ── Loop state ──
         (bnh-entry 0.0)
         (last-close 0.0)
         (candle-num 0)
         (progress-every 50)
         (end-idx (if (> (:max-candles args) 0)
                    (min (:max-candles args) total-candles)
                    total-candles))
         (kill-file "trader-stop")
         (t-start (now))
         (accumulated-misses '()))

    (eprintln "enterprise: four-step loop, {} observers, {} exit, {} brokers"
      n (len EXIT-LENSES) (* n m))
    (eprintln "  {}D  recalib={}  max-window={}"
      (:dims args) (:recalib-interval args) (:max-window-size args))
    (when (or (> (:swap-fee args) 0.0) (> (:slippage args) 0.0))
      (let ((rt (* 2.0 (+ (:swap-fee args) (:slippage args)) 100.0)))
        (eprintln "  venue: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip"
          (* (:swap-fee args) 10000.0) (* (:slippage args) 10000.0) rt)))
    (eprintln "  Parquet: {} ({} candles)" (:parquet args) total-candles)
    (eprintln "  Run database: {}" ledger-path)
    (eprintln "  Walk-forward: up to {} candles..." end-idx)

    ;; ── The fold — main thread is a ROUTER ──────────────────────
    ;; Each candle routes to the right post's pipes by asset pair.
    ;; The fold decomposes into sub-folds connected by rendezvous channels.
    ;; bounded(1) = lock step = lazy enumerator.
    ;; The composition of folds IS the enterprise fold.

    (for-each stream
      (lambda (rc)
        (when (and (> (:max-candles args) 0) (>= candle-num (:max-candles args)))
          (break))

        (when (and (= (mod candle-num 1000) 0) (file-exists? kill-file))
          (eprintln "  Kill switch triggered at candle {}" candle-num)
          (delete-file kill-file)
          (break))

        (when (= candle-num 0)
          (set! bnh-entry (:close rc)))
        (set! last-close (:close rc))

        ;; Route candle to the right post by asset pair
        (let ((found (find-indexed all-pipes
                       (lambda (p) (and (= (first p) (:source-asset-name rc))
                                        (= (second p) (:target-asset-name rc)))))))
          (when found
            (let ((post-idx (first found))
                  (pipes (second found))
                  (t-candle (now)))

              ;; ── Step 1: SETTLE TRIGGERED TRADES ──────────────────
              ;; Settle trades that hit their stop levels. Propagate outcomes
              ;; to observer and broker learn channels + exit observer main thread.
              (let* ((current-prices (map (lambda (p)
                                           (list (list (:source-asset p) (:target-asset p))
                                                 (current-price p)))
                                         (:posts ent)))
                     ((settlements settle-logs) (settle-triggered (:treasury ent) current-prices)))
                (for-each settle-logs (lambda (entry) (log-send log-handle entry)))
                (for-each settlements
                  (lambda (stl)
                    (let* ((slot (:broker-slot-idx (:trade stl)))
                           (stl-post-idx (:post-idx (:trade stl)))
                           (mi (/ slot m))
                           (ei (mod slot m))
                           (direction (if (> (:exit-price stl) (:entry-price (:trade stl)))
                                        :up :down))
                           (optimal (compute-optimal-distances
                                      (:price-history (:trade stl)) direction))
                           (stl-pipes (nth all-pipes stl-post-idx)))
                      ;; Market observer learns via channel
                      (send (nth (learn-txs-of stl-pipes) mi)
                        (list (:composed-thought stl) direction (:amount stl)))
                      ;; Broker learns via channel
                      (send (nth (broker-learn-txs-of stl-pipes) slot)
                        (list (:composed-thought stl) (:outcome stl) (:amount stl)
                              direction optimal))
                      ;; Exit observer learns on main thread
                      (when (< ei (len (:exit-observers (nth (:posts ent) stl-post-idx))))
                        (observe-distances
                          (nth (:exit-observers (nth (:posts ent) stl-post-idx)) ei)
                          (:composed-thought stl) optimal (:amount stl)))))))

              (let ((t-step1 (elapsed t-candle)))

                ;; ── Step 2: TICK + FAN-OUT + COLLECT + GRID + BROKERS ──
                ;; Tick indicator bank (sequential — streaming state)
                (let* ((post (nth (:posts ent) post-idx))
                       (enriched (tick (:indicator-bank post) rc)))
                  (push-back! (:candle-window post) enriched)
                  (while (> (len (:candle-window post)) (:max-window-size post))
                    (pop-front! (:candle-window post)))
                  (inc! (:encode-count post))

                  (let ((window (arc (to-vec (:candle-window post))))
                        (encode-count (:encode-count post))
                        (t-tick (elapsed t-candle)))

                    ;; Fan-out: send enriched candle to all observers
                    (for-each (obs-txs-of pipes)
                      (lambda (tx)
                        (send tx (list enriched (clone window) encode-count))))

                    ;; Collect thoughts from all observers (bounded(1) — they block until we read)
                    (let ((market-thoughts '())
                          (market-predictions '())
                          (market-edges '())
                          (all-misses '()))
                      (for-each (thought-rxs-of pipes)
                        (lambda (rx)
                          (let (((thought pred edge misses) (recv rx)))
                            (push! market-thoughts thought)
                            (push! market-predictions pred)
                            (push! market-edges edge)
                            (extend! all-misses misses))))

                      (let ((t-observers (elapsed t-candle))
                            (price (current-price post)))

                        ;; ── N x M grid: parallel computation → send to broker pipes ──
                        ;; Pure reads. Exit facts + encode + compose + distances.
                        ;; Edge is 0.0 — brokers compute edge on their threads.
                        (let ((grid-values
                                (pmap (lambda (slot-idx)
                                        (let* ((mi (/ slot-idx m))
                                               (ei (mod slot-idx m))
                                               (exit-facts (exit-lens-facts
                                                             (:lens (nth (:exit-observers post) ei))
                                                             enriched))
                                               (exit-bundle (ThoughtAST/Bundle exit-facts))
                                               (exit-vec (match (encoder-get (nth grid-handles slot-idx) exit-bundle)
                                                           ((Some cached) cached)
                                                           (None
                                                             (let (((vec _) (encode (:thought-encoder ctx-arc) exit-bundle)))
                                                               (encoder-set (nth grid-handles slot-idx) exit-bundle vec)
                                                               vec))))
                                               (composed (bundle (nth market-thoughts mi) exit-vec))
                                               (empty-accums '())
                                               ((dists _) (recommended-distances
                                                            (nth (:exit-observers post) ei)
                                                            composed empty-accums
                                                            (scalar-encoder (:thought-encoder ctx-arc))))
                                               (side (derive-side (nth market-predictions mi)))
                                               (edge 0.0)
                                               (pred (prediction-convert (nth market-predictions mi))))
                                          (list slot-idx composed dists side edge pred)))
                                      (range (* n m)))))

                          (let ((t-grid (elapsed t-candle)))

                            ;; Send to broker pipes — bounded(1), each broker gets its input
                            (for-each grid-values
                              (lambda (gv)
                                (let ((slot-idx (nth gv 0))
                                      (composed (nth gv 1))
                                      (dists (nth gv 2))
                                      (side (nth gv 3))
                                      (edge (nth gv 4))
                                      (pred (nth gv 5)))
                                  (send (nth (broker-in-txs-of pipes) slot-idx)
                                    (list composed dists price side edge pred)))))

                            ;; Collect from broker pipes — bounded(1), all N*M produce
                            (let ((all-resolutions '()))
                              (for-each (broker-out-rxs-of pipes)
                                (lambda (rx)
                                  (let (((prop resolutions) (recv rx)))
                                    ;; Submit proposal to treasury for funding evaluation
                                    (submit-proposal (:treasury ent) prop)
                                    ;; Log paper resolutions
                                    (for-each resolutions
                                      (lambda (res)
                                        (log-send log-handle
                                          (LogEntry/PaperResolved
                                            (:broker-slot-idx res) (:outcome res)))))
                                    (extend! all-resolutions resolutions))))

                              (let ((t-brokers (elapsed t-candle)))

                                ;; ── Step 3: PROPAGATE ──────────────────────
                                ;; Channel sends to market observers and brokers (cheap, sequential).
                                ;; Exit observer learning: parallel across M observers.
                                (let ((exit-work (make-vec m '())))
                                  (for-each (enumerate all-resolutions)
                                    (lambda (ri res)
                                      (let ((mi (/ (:broker-slot-idx res) m))
                                            (ei (mod (:broker-slot-idx res) m)))
                                        ;; Market observer: learn via channel
                                        (send (nth (learn-txs-of pipes) mi)
                                          (list (:composed-thought res) (:direction res) (:amount res)))
                                        ;; Broker: learn via channel
                                        (send (nth (broker-learn-txs-of pipes) (:broker-slot-idx res))
                                          (list (:composed-thought res) (:outcome res) (:amount res)
                                                (:direction res) (:optimal-distances res)))
                                        ;; Collect exit work for parallel application
                                        (push! (nth exit-work ei) (list ei ri)))))

                                  ;; Exit observer learning — parallel across M, sequential within.
                                  ;; Each exit observer is independent. MAX-DRAIN per observer.
                                  (pfor-each (zip (:exit-observers post) exit-work)
                                    (lambda (eobs work)
                                      (let ((drained 0))
                                        (for-each work
                                          (lambda (pair)
                                            (when (< drained MAX-DRAIN)
                                              (let ((ri (second pair))
                                                    (res (nth all-resolutions ri)))
                                                (observe-distances eobs
                                                  (:composed-thought res)
                                                  (:optimal-distances res)
                                                  (:amount res))
                                                (set! drained (+ drained 1))))))))))

                                (let ((t-propagate (elapsed t-candle)))

                                  ;; ── Step 3c: UPDATE TRIGGERS ─────────────
                                  ;; Refresh stop distances on active trades.
                                  ;; Pre-encode exit vecs per exit observer (M, not per-trade).
                                  ;; Then parallel compose + distance query per trade.
                                  (let* ((trade-info
                                           (filter-map (lambda (id-trade)
                                                         (let ((id (first id-trade))
                                                               (t (second id-trade)))
                                                           (when (and (= (:post-idx t) post-idx)
                                                                      (or (= (:phase t) :active)
                                                                          (= (:phase t) :runner)))
                                                             (list id (:broker-slot-idx t) (:side t)))))
                                                       (entries (:trades (:treasury ent)))))

                                         ;; Pre-encode exit vecs — M, not per-trade.
                                         ;; Each exit lens produces the same facts for the same candle.
                                         (exit-vecs
                                           (map (lambda (ei)
                                                  (let* ((exit-facts (exit-lens-facts
                                                                       (:lens (nth (:exit-observers post) ei))
                                                                       enriched))
                                                         (exit-bundle (ThoughtAST/Bundle exit-facts)))
                                                    (match (encoder-get step3c-handle exit-bundle)
                                                      ((Some cached) cached)
                                                      (None
                                                        (let (((vec _) (encode (:thought-encoder ctx-arc) exit-bundle)))
                                                          (encoder-set step3c-handle exit-bundle vec)
                                                          vec)))))
                                                (range m)))

                                         ;; Parallel: compose + distance query per trade. Independent.
                                         (level-updates
                                           (pmap (lambda (info)
                                                   (let* ((tid (nth info 0))
                                                          (slot (nth info 1))
                                                          (side (nth info 2))
                                                          (mi (/ slot m))
                                                          (ei (mod slot m))
                                                          (composed (bundle (nth market-thoughts mi)
                                                                           (nth exit-vecs ei)))
                                                          (empty-accums '())
                                                          ((dists _) (recommended-distances
                                                                       (nth (:exit-observers post) ei)
                                                                       composed empty-accums
                                                                       (scalar-encoder (:thought-encoder ctx-arc))))
                                                          (new-levels (to-levels dists price side)))
                                                     (list tid new-levels)))
                                                 trade-info)))

                                    ;; Apply level updates
                                    (for-each level-updates
                                      (lambda (update)
                                        (update-trade-stops (:treasury ent) (first update) (second update)))))

                                  (let ((t-triggers (elapsed t-candle)))

                                    ;; Tick trade price histories
                                    (for-each (entries (:trades (:treasury ent)))
                                      (lambda (id-trade)
                                        (tick (second id-trade) (:close rc))))

                                    ;; Collect cache misses
                                    (extend! accumulated-misses all-misses)

                                    (let ((t-misc (elapsed t-candle)))

                                      ;; ── Step 4: FUND PROPOSALS ─────────────
                                      (let ((fund-logs (fund-proposals (:treasury ent))))
                                        (for-each fund-logs
                                          (lambda (entry) (log-send log-handle entry))))

                                      (let ((t-fund (elapsed t-candle)))

                                        (set! candle-num (+ candle-num 1))

                                        ;; Diagnostics every 10 candles — timing + counts + cache
                                        (when (and (= (mod candle-num 10) 0) (> candle-num 0))
                                          (let* ((t-total (elapsed t-candle))
                                                 (elapsed-ms (* (elapsed-secs t-start) 1000.0))
                                                 (throughput (if (> elapsed-ms 0.0)
                                                               (/ (* candle-num 1000.0) elapsed-ms)
                                                               0.0))
                                                 (num-active
                                                   (count (lambda (id-t)
                                                            (or (= (:phase (second id-t)) :active)
                                                                (= (:phase (second id-t)) :runner)))
                                                     (entries (:trades (:treasury ent))))))
                                            (log-send log-handle
                                              (LogEntry/Diagnostic
                                                candle-num throughput
                                                (hit-count encoder-service)
                                                (miss-count encoder-service)
                                                (cache-len encoder-service)
                                                (total-equity (:treasury ent))
                                                (us t-step1)
                                                (us (- t-tick t-step1))
                                                (us (- t-observers t-tick))
                                                (us (- t-grid t-observers))
                                                (us (- t-brokers t-grid))
                                                (us (- t-propagate t-brokers))
                                                (us (- t-triggers t-propagate))
                                                (us (- t-fund t-misc))
                                                (us t-total)
                                                0  ; num-settlements (TODO)
                                                (len all-resolutions)
                                                num-active))))

                                        ;; Progress display to stderr — every 50 candles
                                        (when (= (mod candle-num progress-every) 0)
                                          (let ((elapsed-ms (* (elapsed-secs t-start) 1000.0)))
                                            (display-progress ent candle-num elapsed-ms))))))))))))))))))))))

    ;; ── Shutdown — cascade ──────────────────────────────────────
    ;; Drop all sender ends. The threads drain and exit.
    ;; Join all thread handles. Restore observers and brokers to posts.
    (for-each (enumerate all-pipes)
      (lambda (post-idx pipes)
        ;; Drop senders to close channels — threads exit their loops
        (drop! (obs-txs-of pipes))
        (drop! (broker-in-txs-of pipes))
        (drop! (learn-txs-of pipes))
        (drop! (broker-learn-txs-of pipes))

        ;; Join observer threads — restore to post
        (let ((restored-observers
                (map (lambda (handle) (join handle))
                     (observer-handles-of pipes))))
          (set! (:market-observers (nth (:posts ent) post-idx))
            restored-observers))

        ;; Join broker threads — restore to post
        (let ((restored-brokers
                (map (lambda (handle) (join handle))
                     (broker-handles-of pipes))))
          (set! (:registry (nth (:posts ent) post-idx))
            restored-brokers))))

    ;; Shutdown encoder service — report cache stats
    (eprintln "  Cache: {} hits, {} misses ({:.1}% hit rate)"
      (hit-count encoder-service)
      (miss-count encoder-service)
      (if (> (+ (hit-count encoder-service) (miss-count encoder-service)) 0)
        (* 100.0 (/ (hit-count encoder-service)
                     (+ (hit-count encoder-service) (miss-count encoder-service))))
        0.0))
    (drop! grid-handles)
    (drop! step3c-handle)
    (shutdown encoder-service)

    ;; Shutdown log service — drop handle, cascade closes pipe, writer drains and exits
    (let ((log-rows (rows log-service)))
      (drop! log-handle)
      (shutdown log-service)

      ;; ── Summary ──
      (let ((elapsed-ms (* (elapsed-secs t-start) 1000.0)))
        (display-summary ent candle-num elapsed-ms
          bnh-entry last-close
          (:swap-fee args) (:slippage args)
          log-rows ledger-path)))))
