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

;; ── Constants ──────────────────────────────────────────────────

(define BATCH-SIZE 50)

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

;; ── Construction ────────────────────────────────────────────────
;; Build the world, then the machine.

(define (construct [args : CliArgs])
  : (Enterprise, Ctx)
  (let* ((dims (:dims args))
         (recalib-interval (:recalib-interval args))

         ;; Build ctx — the immutable world
         (ctx (make-ctx dims recalib-interval))

         ;; Single asset pair
         (source (make-asset (:source-asset args)))
         (target (make-asset (:target-asset args)))
         (initial-balances
           (assoc (assoc (map-of) source (:source-balance args))
                  target (:target-balance args)))

         ;; One post for the single pair
         (bank (make-indicator-bank))

         ;; Market observers — one per MarketLens variant
         (market-observers
           (map (lambda (lens)
                  (make-market-observer lens dims recalib-interval
                    (make-window-sampler 7919 12 (:max-window-size args))))
                MARKET-LENSES))

         ;; Exit observers — one per ExitLens variant
         (exit-observers
           (map (lambda (lens)
                  (make-exit-observer lens dims recalib-interval
                    0.015 0.030))
                EXIT-LENSES))

         ;; Brokers — N x M grid
         (n (len MARKET-LENSES))
         (m (len EXIT-LENSES))
         (registry
           (map (lambda (slot-idx)
                  (let ((market-idx (/ slot-idx m))
                        (exit-idx (mod slot-idx m)))
                    (make-broker
                      (list (nth MARKET-LENSES market-idx)
                            (nth EXIT-LENSES exit-idx))
                      slot-idx m dims recalib-interval
                      (list (make-scalar-accumulator "trail-distance" :log dims)
                            (make-scalar-accumulator "stop-distance" :log dims)))))
                (range (* n m))))

         (post (make-post 0 source target dims recalib-interval
                 (:max-window-size args) bank
                 market-observers exit-observers registry))

         ;; Treasury
         (treasury (make-treasury
                     (make-asset (:denomination args))
                     initial-balances
                     (:swap-fee args)
                     (:slippage args)))

         ;; Enterprise
         (ent (make-enterprise (list post) treasury)))

    (list ent ctx)))

;; ── Ledger ──────────────────────────────────────────────────────
;; Initialize SQLite database for this run.

(define (init-ledger [path : String] [args : CliArgs] [posts : Vec<Post>])
  : Ledger
  (make-ledger path args posts))

;; ── Pipe types ─────────────────────────────────────────────────
;; Named for clarity. These are the values that cross pipe boundaries.

;; ObsInput:    (Candle, Arc<Vec<Candle>>, usize)
;; ObsOutput:   (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
;; ObsLearn:    (Vector, Direction, f64)
;; BrokerInput: (Vector, Distances, f64, Side, f64, Prediction)
;; BrokerOutput:(Proposal, Vec<Resolution>)
;; BrokerLearn: (Vector, Outcome, f64, Direction, Distances)

;; ── The fold ────────────────────────────────────────────────────
;; The main loop. The driver of the enterprise.

(define (run [args : CliArgs])
  : ()
  (let* (((ent ctx) (construct args))
         (ledger (init-ledger (:ledger args) args))
         (stream (open-parquet-stream (:parquet args)))
         (kill-file "trader-stop")
         (n (len MARKET-LENSES))
         (m (len EXIT-LENSES))
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
         ((log-service log-handles)
           (log-service-spawn 1 ledger))
         (log-handle (first log-handles))

         ;; ── Per-post pipe wiring ──
         ;; One set of pipes per asset pair. No magic index.
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

                    ;; Observer pipes + threads
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
                                  (loop
                                    (match (recv obs-rx)
                                      ((Some (candle window encode-count))
                                        ;; Drain at most MAX-DRAIN learn signals per candle.
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
                                               (result (observe obs thought '())))
                                          (send thought-tx
                                            (list (:thought result) (:prediction result)
                                                  (:edge result) '()))))
                                      (None (break))))
                                  obs)))))))

                    ;; Broker pipes + threads
                    (for-each (range (* n m))
                      (lambda (slot-idx)
                        (let (((in-tx in-rx)       (make-pipe :capacity 1 :carries BrokerInput))
                              ((out-tx out-rx)     (make-pipe :capacity 1 :carries BrokerOutput))
                              ((blearn-tx blearn-rx) (make-pipe :capacity :unbounded :carries BrokerLearn)))
                          (push! broker-in-txs in-tx)
                          (push! broker-out-rxs out-rx)
                          (push! broker-learn-txs blearn-tx)

                          (let ((broker (take! (:registry post) slot-idx))
                                (src (:source-asset post))
                                (tgt (:target-asset post))
                                (recalib (:recalib-interval args)))
                            (push! broker-handles
                              (spawn
                                (lambda ()
                                  (loop
                                    (match (recv in-rx)
                                      ((Some (composed dists price side edge pred))
                                        ;; Drain at most MAX-DRAIN learn signals per candle.
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

                                        (propose broker composed)
                                        (register-paper broker (clone composed) price dists)
                                        (let ((resolutions (tick-papers broker price))
                                              (prop (make-proposal composed dists edge side
                                                      src tgt pred
                                                      (current-post-idx) slot-idx)))
                                          (send out-tx (list prop resolutions))))
                                      (None (break))))
                                  broker)))))))

                    (list obs-txs thought-rxs learn-txs observer-handles
                          broker-in-txs broker-out-rxs broker-learn-txs broker-handles
                          n m)))
                (:posts ent)))

         ;; Loop state
         (bnh-entry 0.0)
         (last-close 0.0)
         (candle-num 0)
         (progress-every BATCH-SIZE)
         (end-idx (if (> (:max-candles args) 0)
                    (min (:max-candles args) (len stream))
                    (len stream))))

    ;; ── The fold — main thread is a ROUTER ──
    (for-each stream
      (lambda (rc)
        (when (and (> (:max-candles args) 0) (>= candle-num (:max-candles args)))
          (break))

        (when (and (= (mod candle-num 1000) 0) (file-exists? kill-file))
          (display "Kill switch triggered.")
          (delete-file kill-file)
          (break))

        (when (= candle-num 0)
          (set! bnh-entry (:close rc)))
        (set! last-close (:close rc))

        ;; Route candle to the right post by asset pair
        (let ((pipes (find all-pipes
                       (lambda (p) (and (= (:source-asset p) (:source-asset rc))
                                        (= (:target-asset p) (:target-asset rc)))))))
          (when pipes
            ;; Step 1: SETTLE TRIGGERED TRADES
            (let (((settlements settle-logs) (settle-triggered (:treasury ent))))
              (for-each settle-logs (lambda (entry) (log log-handle entry)))
              (for-each settlements
                (lambda (stl)
                  (let ((slot (:broker-slot-idx (:trade stl)))
                        (mi (/ slot m))
                        (ei (mod slot m))
                        (direction (if (> (:exit-price stl) (:entry-price (:trade stl)))
                                     :up :down))
                        (optimal (compute-optimal-distances
                                   (:price-history (:trade stl)) direction)))
                    ;; Market observer learns via pipe
                    (send (nth (:learn-txs pipes) mi)
                      (list (:composed-thought stl) direction (:amount stl)))
                    ;; Broker learns via pipe
                    (send (nth (:broker-learn-txs pipes) slot)
                      (list (:composed-thought stl) (:outcome stl) (:amount stl)
                            direction optimal))))))

            ;; Step 2: Tick indicator bank, fan-out to observer pipes
            (let* ((post (nth (:posts ent) (post-idx-of pipes)))
                   (enriched (tick (:indicator-bank post) rc))
                   (window (arc (to-vec (:candle-window post)))))

              ;; Fan-out: send enriched candle to all observers
              (for-each (:obs-txs pipes)
                (lambda (tx)
                  (send tx (list enriched (clone window) (:encode-count post)))))

              ;; Collect thoughts from all observers (bounded(1) — they block until we read)
              (let ((market-thoughts '())
                    (market-predictions '())
                    (market-edges '()))
                (for-each (:thought-rxs pipes)
                  (lambda (rx)
                    (let (((thought pred edge _misses) (recv rx)))
                      (push! market-thoughts thought)
                      (push! market-predictions pred)
                      (push! market-edges edge))))

                ;; N x M grid: compute and send to broker pipes
                (let ((price (current-price post)))
                  (for-each (range (* n m))
                    (lambda (slot-idx)
                      (let* ((mi (/ slot-idx m))
                             (ei (mod slot-idx m))
                             (exit-facts (exit-lens-facts
                                           (:lens (nth (:exit-observers post) ei)) enriched))
                             (exit-bundle (ThoughtAST/Bundle exit-facts))
                             (exit-vec (match (encoder-get (nth grid-handles slot-idx) exit-bundle)
                                         ((Some cached) cached)
                                         (None
                                           (let (((vec _) (encode (:thought-encoder ctx-arc) exit-bundle)))
                                             (encoder-set (nth grid-handles slot-idx) exit-bundle vec)
                                             vec))))
                             (composed (bundle (nth market-thoughts mi) exit-vec))
                             ((dists _) (recommended-distances
                                          (nth (:exit-observers post) ei)
                                          composed '()
                                          (scalar-encoder (:thought-encoder ctx-arc))))
                             (side (derive-side (nth market-predictions mi)))
                             (edge 0.0)  ; broker computes edge on its thread
                             (pred (prediction-convert (nth market-predictions mi))))
                        (send (nth (:broker-in-txs pipes) slot-idx)
                          (list composed dists price side edge pred)))))

                  ;; Collect from broker pipes
                  (let ((all-resolutions '()))
                    (for-each (:broker-out-rxs pipes)
                      (lambda (rx)
                        (let (((prop resolutions) (recv rx)))
                          (submit-proposal (:treasury ent) prop)
                          (for-each resolutions
                            (lambda (res)
                              (log log-handle (make-paper-resolved
                                (:broker-slot-idx res) (:outcome res)
                                (:optimal-distances res)))))
                          (extend! all-resolutions resolutions))))

                    ;; Propagate — send learning signals to pipes
                    (for-each all-resolutions
                      (lambda (res)
                        (let ((mi (/ (:broker-slot-idx res) m))
                              (ei (mod (:broker-slot-idx res) m)))
                          ;; Market observer learns via pipe
                          (send (nth (:learn-txs pipes) mi)
                            (list (:composed-thought res) (:direction res) (:amount res)))
                          ;; Broker learns via pipe
                          (send (nth (:broker-learn-txs pipes) (:broker-slot-idx res))
                            (list (:composed-thought res) (:outcome res) (:amount res)
                                  (:direction res) (:optimal-distances res))))))))))))

        (set! candle-num (+ candle-num 1))))

    ;; ── Shutdown — cascade ──
    ;; Drop all sender ends. The threads drain and exit.
    ;; Join all thread handles. Then join the services.
    (summary ent ledger candle-num)))

;; ── Progress ────────────────────────────────────────────────────
;; Every N candles, display diagnostics.

(define (progress [ent : Enterprise] [count : usize])
  : ()
  (let* ((equity (total-equity (:treasury ent))))
    (display (format "candle {} | equity {:.2}" count equity))))

;; ── Summary ─────────────────────────────────────────────────────
;; After the loop completes.

(define (summary [ent : Enterprise] [ledger : Ledger] [count : usize])
  : ()
  (let* ((equity (total-equity (:treasury ent)))
         (treasury (:treasury ent)))
    (begin
      (display (format "=== Run Summary ==="))
      (display (format "Candles processed: {}" count))
      (display (format "Final equity: {:.2}" equity))
      (display (format "Ledger: {}" (:path ledger))))))
