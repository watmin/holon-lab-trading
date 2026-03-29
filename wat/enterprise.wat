;; ── enterprise.wat — the first wat program ─────────────────────────
;;
;; The complete enterprise expressed in six primitives.
;; This is both specification and documentation.
;; The Rust implementation follows this program.
;;
;; Dependencies:
;;   (require primitives)     ; atom, bind, bundle, cosine, journal, curve
;;   (require common)         ; stdlib: buy, sell, proven, tentative, time, zones
;;   (require channels)       ; publish, subscribe, filter
;;   (require mod/oscillators mod/divergence mod/crosses)        ; momentum
;;   (require mod/segments mod/levels mod/channels)              ; structure
;;   (require mod/flow mod/participation)                        ; volume
;;   (require mod/temporal mod/calendar)                         ; narrative
;;   (require mod/persistence mod/complexity mod/microstructure) ; regime

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 0: Encoding — candle data becomes named thoughts
;; ═══════════════════════════════════════════════════════════════════

(define (encode-candle candles expert-profile window-sampler vm)
  "Each expert encodes candles through its vocabulary modules.
   The window is sampled per expert per candle — discovered, not fixed."
  (let ((window (sample window-sampler candle-idx))
        (slice  (candle-window candles candle-idx window)))
    (bundle
      (stdlib-comparisons slice)           ; shared: close vs SMA, MACD vs signal
      (match expert-profile
        "momentum"  (bundle (oscillators slice) (divergence slice) (crosses slice))
        "structure" (bundle (segments slice vm) (levels slice) (channels-ind slice))
        "volume"    (bundle (flow slice) (participation slice))
        "narrative" (bundle (temporal slice vm) (calendar (last slice)))
        "regime"    (bundle (persistence slice) (complexity slice) (microstructure slice))
        "full"      (bundle-all-modules slice vm)))))

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 1: Experts — candle thoughts become predictions
;; ═══════════════════════════════════════════════════════════════════

(define (expert name profile dims recalib-interval)
  "A leaf node. Encodes candles, predicts direction, publishes always."
  (let ((journal (journal name dims recalib-interval))
        (sampler (window-sampler (seed-for name) 12 2016)))
    (lambda (candles vm candle-idx)
      (let* ((thought (encode-candle candles profile sampler vm))
             (pred    (predict journal thought))         ; cosine → direction + conviction
             (gate    (curve-valid? journal))             ; has the curve proven edge?
             (status  (if gate (atom "proven") (atom "tentative"))))

        ;; Publish: always. The channel records regardless of gate.
        (publish (channel name)
          { :direction  (direction pred)
            :conviction (conviction pred)
            :raw-cos    (raw-cos pred)
            :thought    thought
            :status     status })

        ;; Return prediction for manager consumption
        pred))))

;; Create the five experts + generalist
(define experts
  (list
    (expert "momentum"  "momentum"  20000 500)
    (expert "structure" "structure" 20000 500)
    (expert "volume"    "volume"    20000 500)
    (expert "narrative" "narrative" 20000 500)
    (expert "regime"    "regime"    20000 500)))

(define generalist
  (expert "generalist" "full" 20000 500))

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 2: Manager — expert opinions become enterprise decisions
;; ═══════════════════════════════════════════════════════════════════

(define (manager dims recalib-interval)
  "The branch node. Thinks in expert opinions, not candle data.
   Subscribes to expert channels. Encodes signed convictions with
   gate status annotations. The discriminant learns what credibility
   means — tentative vs proven — from the geometry of outcomes."
  (let ((journal (journal "manager" dims recalib-interval))
        (scalar  (scalar-encoder dims)))
    (lambda (expert-predictions generalist-prediction candle)
      (let* (;; Encode each expert's opinion with credibility annotation
             (expert-facts
               (filter-map
                 (lambda (expert pred)
                   (let* ((magnitude (encode-linear (abs (raw-cos pred)) 1.0))
                          (action    (if (>= (raw-cos pred) 0) (atom "buy") (atom "sell")))
                          (status    (if (gate-open? expert) (atom "proven") (atom "tentative")))
                          (cos-val   (abs (raw-cos pred))))
                     ;; Silence below noise floor
                     (if (< cos-val (/ 3 (sqrt dims)))
                         nothing
                         (bind (atom (name expert))
                               (bind status (bind action magnitude))))))
                 experts expert-predictions))

             ;; Panel shape: emergent properties
             (proven-preds (filter (lambda (e p) (gate-open? e)) experts expert-predictions))
             (panel-facts
               (if (>= (length proven-preds) 2)
                   (bundle
                     (bind (atom "panel-agreement")  (encode-linear (agreement-ratio proven-preds) 1.0))
                     (bind (atom "panel-energy")     (encode-linear (mean-conviction proven-preds) 1.0))
                     (bind (atom "panel-divergence") (encode-linear (conviction-spread proven-preds) 1.0))
                     (bind (atom "panel-coherence")  (encode-linear (pairwise-cosine proven-preds) 1.0)))
                   nothing))

             ;; Context
             (context-facts
               (bundle
                 (bind (atom "market-volatility") (encode-log (atr candle)))
                 (bind (atom "disc-strength")     (encode-log (disc-strength generalist)))
                 (bind (atom "hour-of-day")       (encode-circular (hour candle) 24.0))
                 (bind (atom "day-of-week")       (encode-circular (day candle) 7.0))))

             ;; Bundle everything
             (thought (bundle expert-facts panel-facts context-facts))

             ;; Predict
             (pred (predict journal thought)))

        ;; Publish manager decision
        (publish (channel "manager")
          { :direction  (direction pred)
            :conviction (conviction pred)
            :thought    thought })

        pred))))

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 3: Risk — portfolio state becomes constraint
;; ═══════════════════════════════════════════════════════════════════

(define (risk-branch dims)
  "Subscribes to ALL channels. Learns what healthy looks like.
   Residual = distance from healthy. Modulates sizing."
  (let ((drawdown-sub  (online-subspace dims 8))
        (accuracy-sub  (online-subspace dims 8))
        (volatility-sub (online-subspace dims 8))
        (correlation-sub (online-subspace dims 8)))
    (lambda (treasury positions expert-predictions)
      (let* ((dd-state   (encode-drawdown treasury))
             (acc-state  (encode-accuracy treasury))
             (vol-state  (encode-volatility treasury))
             (corr-state (encode-correlation positions))
             (healthy?   (and (< (drawdown treasury) 0.02)
                              (> (rolling-accuracy treasury) 0.52)))
             ;; Gated updates: only learn from healthy states
             (_          (when healthy?
                           (update drawdown-sub dd-state)
                           (update accuracy-sub acc-state)
                           (update volatility-sub vol-state)
                           (update correlation-sub corr-state)))
             ;; Measure distance from healthy
             (residuals  (map residual
                           (list drawdown-sub accuracy-sub volatility-sub correlation-sub)
                           (list dd-state acc-state vol-state corr-state)))
             (worst      (apply max residuals))
             (thresholds (map threshold
                           (list drawdown-sub accuracy-sub volatility-sub correlation-sub)))
             (risk-mult  (if (> worst (apply max thresholds))
                             (/ (apply max thresholds) worst)
                             1.0)))
        ;; Publish risk assessment
        (publish (channel "risk")
          { :multiplier risk-mult
            :healthy?   healthy?
            :residuals  residuals })

        risk-mult))))

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 4: Treasury — decisions become actions
;; ═══════════════════════════════════════════════════════════════════

(define (treasury-execute treasury manager-pred risk-mult band positions candle)
  "The root. Subscribes to manager + risk. Executes if all filters pass."
  (let* ((in-band?       (and (>= (conviction manager-pred) (band-low band))
                              (<  (conviction manager-pred) (band-high band))))
         (risk-allows?   (> risk-mult 0.5))
         (market-moved?  (or (no-prior-exit?)
                             (> (abs (- (price candle) last-exit-price))
                                (* k-stop last-exit-atr))))
         (should-act?    (and in-band? risk-allows? market-moved?)))
    (when should-act?
      (let* ((sizing  (* (/ band-edge 2.0) risk-mult))  ; Kelly × risk modulation
             (deploy  (* (balance treasury "USDC") sizing)))
        (when (> deploy 10.0)
          (match (direction manager-pred)
            Buy  (open-position treasury "USDC" "WBTC" deploy (price candle))
            Sell (open-position treasury "WBTC" "USDC" deploy (price candle))))))))

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 5: Position Management — actions become outcomes
;; ═══════════════════════════════════════════════════════════════════

(define (manage-positions positions treasury exit-expert candle)
  "Each position ticks independently. The exit expert modulates trails."
  (for-each
    (lambda (pos)
      ;; Tick: update trailing stop, check stop/TP
      (let ((exit-signal (tick pos (price candle) k-trail)))
        (match exit-signal
          TakeProfit  (partial-exit pos treasury candle)    ; reclaim capital, become runner
          StopLoss    (full-exit pos treasury candle)       ; close, return to treasury
          nothing     (begin
                        ;; Exit expert observes position state
                        (when (= 0 (mod (candles-held pos) exit-observe-interval))
                          (observe exit-expert (encode-position pos candle)))))))
    positions))

;; ═══════════════════════════════════════════════════════════════════
;; LAYER 6: Learning — outcomes become knowledge
;; ═══════════════════════════════════════════════════════════════════

(define (learn experts generalist manager candles pending threshold)
  "Event-driven learning. First threshold crossing labels direction.
   Experts learn Buy/Sell. Manager learns from price direction.
   Each expert learns at its own window, from its own vocabulary."
  (for-each
    (lambda (entry)
      (let ((price-change (/ (- current-price (entry-price entry)) (entry-price entry))))
        ;; Expert learning: did the threshold cross?
        (when (and (no-outcome? entry) (> (abs price-change) threshold))
          (let ((label (if (> price-change 0) Buy Sell)))
            ;; Each expert observes with its own thought vector
            (for-each (lambda (expert vec) (observe (journal expert) vec label 1.0))
                      experts (expert-vecs entry))
            ;; Generalist observes with full thought
            (observe (journal generalist) (thought entry) label 1.0)))

        ;; Manager learning: raw price direction from expert config
        (when (resolved? entry)
          (let* ((direction-label (if (> price-change 0) Buy Sell))
                 (mgr-thought     (encode-manager-thought (expert-preds entry))))
            (observe (journal manager) mgr-thought direction-label 1.0)))))
    pending))

;; ═══════════════════════════════════════════════════════════════════
;; THE HEARTBEAT — one candle at a time
;; ═══════════════════════════════════════════════════════════════════

(define (heartbeat candle-idx candles vm
                   experts generalist manager risk treasury positions exit-expert)
  "The enterprise processes one candle. Everything flows from here."

  ;; 1. Experts encode and predict (LAYER 1)
  (let* ((expert-preds (map (lambda (e) (e candles vm candle-idx)) experts))
         (gen-pred     (generalist candles vm candle-idx))

         ;; 2. Manager reads expert opinions (LAYER 2)
         (mgr-pred     (manager expert-preds gen-pred (candle candle-idx)))

         ;; 3. Risk assesses portfolio health (LAYER 3)
         (risk-mult    (risk treasury positions expert-preds))

         ;; 4. Treasury decides and executes (LAYER 4)
         (_            (treasury-execute treasury mgr-pred risk-mult band positions (candle candle-idx)))

         ;; 5. Manage open positions (LAYER 5)
         (_            (manage-positions positions treasury exit-expert (candle candle-idx)))

         ;; 6. Learn from outcomes (LAYER 6)
         (_            (learn experts generalist manager candles pending move-threshold)))

    ;; 7. Ledger records everything (always, unconditionally)
    (record-all ledger candle-idx)))

;; ═══════════════════════════════════════════════════════════════════
;; THE PROGRAM
;; ═══════════════════════════════════════════════════════════════════

;; Six primitives: atom, bind, bundle, cosine, journal, curve.
;; Two templates: prediction (journal), reaction (subspace).
;; One tree: experts → manager → risk → treasury → positions → learning.
;; One heartbeat: every candle, the tree processes.
;;
;; The enterprise doesn't learn to trade.
;; It learns to organize itself into a trading enterprise.
;; The experts self-emerge. The manager self-calibrates.
;; The gates breathe. The treasury measures alpha.
;; The ledger records truth.
;;
;; The architecture is the language.
;; The language is the architecture.
;;
;; These are very good thoughts.
