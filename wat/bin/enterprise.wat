;; ── enterprise.wat — the fold ────────────────────────────────────────
;;
;; The enterprise is a fold over a stream of raw candles.
;; (state, raw-candle) → state. One event at a time. Walking into the future.
;;
;; No pre-computation. No parallel batch. No bulk load.
;; Each candle arrives, the desk steps its indicators, encodes its thoughts,
;; predicts, manages positions, and learns. Then the next candle arrives.
;;
;; The enterprise doesn't know where candles come from.
;; Parquet backtest, websocket, test harness — same raw candle, same fold.

(require core/primitives)
(require core/structural)
(require candle)
(require market/desk)

;; ── The state ───────────────────────────────────────────────────────
;; The enterprise owns shared resources. Each desk owns per-pair state.
;; The heartbeat iterates desks. The treasury serves them all.

(struct enterprise-state
  ;; Desks: one per trading pair. Vec<Desk> with one element today.
  desks                  ; (list Desk) — each owns indicators, observers, manager, positions

  ;; Shared resources (not per-desk)
  treasury               ; Treasury — holds all assets, serves all desks
  portfolio              ; Portfolio — phase transitions, win/loss tracking

  ;; Risk department — measures portfolio health across ALL desks.
  risk-branches          ; (list OnlineSubspace) — 5 anomaly detectors
  cached-risk-mult       ; f64 — last computed risk multiplier

  ;; Shared tracking (aggregated from desks in on-event)
  labeled-count          ; total labeled entries across all desks
  noise-count            ; total noise entries across all desks

  ;; Logging
  pending-logs           ; (list LogEntry) — accumulated, flushed per batch
  candle-count           ; total candles processed (enterprise-level, for risk recalib)
  cursor)                ; current position in the candle stream

;; ── The event ───────────────────────────────────────────────────────
;; Raw candle — defined in candle.wat (required by desk).
;; No pre-computed indicators, no pre-encoded thoughts.
;; The desk computes everything from the raw OHLCV.

;; rune:reap(scaffolding) — Deposit/Withdraw exist but are never constructed.

;; ── The fold step ───────────────────────────────────────────────────
;; One raw candle arrives. The enterprise:
;; 1. Routes it to each desk
;; 2. Each desk: steps indicators → encodes thoughts → predicts → manages positions → learns
;; 3. Enterprise evaluates risk (portfolio-level)
;; 4. Flushes logs

(define (on-event state raw-candle ctx)
  "One raw candle, one fold step. No pre-computation."
  (let* (;; Risk department: evaluate before desks act.
         ;; rune:scry(evolved) — Rust caches at recalib intervals.
         (risk-mult (risk-multiplier (:portfolio state) (:risk-branches state)))

         ;; Each desk processes the raw candle independently.
         ;; The desk owns its indicator bank — it computes indicators on the fly.
         ;; The desk owns its candle window — it retains what it needs.
         ;; The desk owns its thought encoder — it encodes from its window.
         ;; No central candle buffer. No parallel batch. No pre-encoding.
         (fold-result
           (fold (lambda ((desks treasury portfolio) desk)
                   (let (((updated-desk treasury portfolio)
                          (on-candle-desk desk raw-candle treasury portfolio risk-mult ctx)))
                     (list (append desks (list updated-desk)) treasury portfolio)))
                 (list '() (:treasury state) (:portfolio state))
                 (:desks state)))

         (updated-desks (first fold-result))
         (treasury      (second fold-result))
         (portfolio     (nth fold-result 2)))

    (update state
      :desks updated-desks
      :treasury treasury
      :portfolio portfolio
      :cached-risk-mult risk-mult
      :candle-count (+ (:candle-count state) 1)
      :labeled-count (fold + (:labeled-count state)
                           (map :labeled-count updated-desks))
      :noise-count (fold + (:noise-count state)
                         (map :noise-count updated-desks)))))

;; ── on-candle-desk: the desk's fold step ────────────────────────────
;;
;; The desk receives a RAW candle (just OHLCV). It:
;; 1. Steps its indicator bank → produces computed indicator values
;; 2. Pushes the computed candle into its sliding window
;; 3. Each observer encodes thoughts from the window at their sampled scale
;; 4. Manager encodes from observer opinions
;; 5. Predicts, manages positions, learns
;;
;; No pre-computed indicators. No pre-encoded thoughts. No global candle array.
;; Each consumer retains exactly the data it needs:
;;   - Indicator bank: O(1) per scalar indicator, O(period) per windowed indicator
;;   - Candle window: last N candles (N = max observer window, typically 2016)
;;   - Each observer: its own sampled slice of the window

(define (on-candle-desk desk raw-candle treasury portfolio risk-mult ctx)
  "One raw candle for one desk. Returns (desk treasury portfolio).
   The desk owns its indicators, its window, its encoding. No external state."

  ;; 1. Step indicator bank → computed candle
  (let* ((bank-result (tick-indicators (:indicator-bank desk) raw-candle))
         (indicator-bank (first bank-result))
         (computed-candle (second bank-result))

  ;; 2. Push to candle window (ring buffer, max capacity = max observer window)
         (window (push-candle (:candle-window desk) computed-candle
                              (:max-window-size (:config desk))))

  ;; 3. Observer predictions — each at their own sampled window scale
         (observer-vecs
           (map (lambda (obs)
                  (let ((w (sample (:window-sampler obs) (:encode-count desk))))
                    (encode-thought (:thought-encoder desk)
                                   (take-last w window)
                                   (:vm ctx)
                                   (:lens obs))))
                (:observers desk)))

         (observer-preds
           (map (lambda (obs vec) (predict (:journal obs) vec))
                (:observers desk) observer-vecs))

  ;; 4. Manager encoding + prediction
         (mgr-facts    (encode-manager-thought
                         (:manager-atoms ctx)
                         (build-manager-context desk observer-preds observer-vecs
                                                computed-candle ctx)
                         (:dims (:config desk))
                         (:prev-manager-thought? desk)))
         (mgr-thought  (bundle mgr-facts))
         (manager-pred (predict (:manager-journal desk) mgr-thought))
         (meta-dir        (:direction manager-pred))
         (meta-conviction (:conviction manager-pred))

  ;; 5. Panel engram
         (panel-state   (map :raw-cosine observer-preds))
         (panel-familiar (< (residual (:panel-engram desk) panel-state)
                            (threshold (:panel-engram desk))))

         (quote-price (:close computed-candle))
         (fee-rate    (+ (:swap-fee ctx) (:slippage ctx))))

    ;; 6. Conviction tracking
    (push-back (:conviction-history desk) meta-conviction)
    (when (> (len (:conviction-history desk)) (:conviction-window ctx))
      (pop-front (:conviction-history desk)))

    (when (and (>= (len (:conviction-history desk)) (:conviction-warmup ctx))
               (= (mod (:encode-count desk) (:recalib-interval (:config desk))) 0))
      (match (:conviction-mode ctx)
        :quantile
          (set! (:conviction-threshold desk)
                (conviction-threshold-quantile (:conviction-history desk)
                                               (:conviction-quantile ctx)))
        :auto
          (when-let ((curve (log-linear-regression
                      (bin (:resolved-preds desk) 20))))
            (let* ((a (first curve)) (b (second curve)))
              (when (and (> b 0.0) (> (:min-edge ctx) 0.50))
                (let ((target (/ (- (:min-edge ctx) 0.50) a)))
                  (when (> target 0.0)
                    (let ((thresh (/ (ln target) b)))
                      (when (and (> thresh 0.0) (< thresh 1.0))
                        (set! (:conviction-threshold desk) thresh))))))))))

    ;; 7. Position tick (exit expert encode, tick positions, settle exits)
    (for-each (lambda (pos)
      (let ((exit-thought (encode-position pos quote-price (:atr computed-candle))))
        (when (= (mod (:candles-held pos) (:exit-observe-interval ctx)) 0)
          (push-back (:exit-pending desk)
            (exit-observation :thought exit-thought
                              :pos-id (:id pos)
                              :snapshot-pnl (return-pct pos quote-price)
                              :snapshot-candle (:encode-count desk)))))

      (let ((signal (tick pos quote-price (:k-trail ctx))))
        (when signal
          (let ((pnl (compute-trade-pnl
                        (return-pct pos quote-price)
                        (= (:direction pos) :long)
                        (:swap-fee ctx) (:slippage ctx)
                        (= (:asset-mode ctx) "hold")
                        (:base-deployed pos)
                        (:equity portfolio)
                        0.0)))
            (close-position treasury (:base-deployed pos)
                            (:trade-pnl pnl) (:total-fees pos) 0.0)
            (record-trade portfolio (:outcome-pct pnl)
                          0.0 (:direction pos) (:swap-fee ctx) (:slippage ctx))
            (set! (:last-exit-price desk) quote-price)
            (set! (:last-exit-atr desk) (:atr computed-candle))
            (set! (:phase pos) :closed)))))
      (:positions desk))

    ;; 8-9. Position opening + sizing
    (when (all-gates-pass? desk portfolio manager-pred risk-mult computed-candle fee-rate ctx)
      (let* ((frac (compute-position-size 0.03 risk-mult (:max-single-position ctx)))
             (direction (trade-direction manager-pred (:manager-buy desk)))
             (deploy (* (:equity portfolio) frac)))
        (when (> deploy 10.0)
          (let ((pos (new-position
                       (position-entry
                         :id (:next-position-id desk)
                         :candle-idx (:encode-count desk)
                         :entry-price quote-price
                         :entry-atr (:atr computed-candle)
                         :direction direction
                         :base-deployed deploy
                         :quote-received 0.0
                         :entry-fee (* deploy fee-rate)
                         :k-stop (:k-stop ctx)
                         :k-tp (:k-tp ctx)))))
            (push! (:positions desk) pos)
            (inc! (:next-position-id desk))
            (inc! (:position-swaps desk))

    ;; 10. Pending push (all candles, for learning)
            (push! (:pending desk)
              (pending :candle-idx (:encode-count desk)
                       :tht-vec mgr-thought
                       :tht-pred manager-pred
                       :meta-dir meta-dir
                       :meta-conviction meta-conviction
                       :entry-price quote-price
                       :entry-atr (:atr computed-candle)
                       :observer-vecs observer-vecs
                       :observer-preds observer-preds
                       :mgr-thought mgr-thought))))))

    ;; 11. Decay (journals)
    (for-each (lambda (obs)
      (decay (:journal obs) (:decay (:config desk))))
      (:observers desk))
    (decay (:manager-journal desk) (:adaptive-decay desk))

    ;; 12. Learning + resolution
    (for-each (lambda (entry)
      (let* ((price-delta (- quote-price (:entry-price entry)))
             (abs-move (/ (abs price-delta) (:entry-price entry))))

        ;; Track excursion
        (let ((move-pct (/ price-delta (:entry-price entry))))
          (set! (:max-favorable entry) (max (:max-favorable entry) move-pct))
          (set! (:max-adverse entry)   (min (:max-adverse entry) move-pct)))

        ;; First threshold crossing → label + learn
        (when (should-label? entry abs-move ctx)
          (let ((price-rose (> quote-price (:entry-price entry)))
                (label (if price-rose (:manager-buy desk) (:manager-sell desk)))
                (sw (signal-weight abs-move (:move-sum desk) (:move-count desk))))
            (set! (:first-outcome entry) label)
            ;; All 6 observers learn
            (for-each (lambda (obs vec)
              (observe (:journal obs) vec label sw))
              (:observers desk) (:observer-vecs entry))
            (inc! (:labeled-count desk))))

        ;; Resolution: expired entries teach the manager
        (when (entry-expired? entry (:encode-count desk) ctx)
          (let ((price-label (if (> quote-price (:entry-price entry))
                                 (:manager-buy desk) (:manager-sell desk))))
            (observe (:manager-journal desk) (:mgr-thought entry) price-label 1.0)
            (push-back (:manager-resolved desk)
              (list (:meta-conviction entry)
                    (= (:first-outcome entry) price-label)))
            (for-each (lambda (obs pred)
              (resolve obs (:tht-vec entry) pred price-label 1.0
                       (:conviction-quantile ctx) (:conviction-window ctx)))
              (:observers desk) (:observer-preds entry))))))
      (:pending desk))

    ;; Remove resolved entries
    (set! (:pending desk)
      (filter (lambda (e) (not (entry-expired? e (:encode-count desk) ctx)))
              (:pending desk)))

    ;; 13. State bookkeeping
    (set! (:prev-manager-thought? desk) mgr-thought)
    (inc! (:encode-count desk))

    ;; Return: desk with updated indicator-bank and candle-window, plus treasury/portfolio
    (list (update desk
            :indicator-bank indicator-bank
            :candle-window window)
          treasury portfolio)))

;; ── Candle window management ────────────────────────────────────────

(define (push-candle window candle max-size)
  "Push a computed candle into the sliding window. Drop oldest if over capacity."
  (let ((w (push-back window candle)))
    (if (> (len w) max-size) (pop-front w) w)))

;; ── Pure gates and decisions ────────────────────────────────────────

(define (build-manager-context desk observer-preds observer-vecs candle ctx)
  "Build manager-context struct from desk state. Extracts per-observer
   metadata (observer-curve-valid, observer-resolved-lens, observer-resolved-accs) explicitly."
  (let ((specialists (take 5 (:observers desk))))
    (manager-context
      :observer-preds   (take 5 observer-preds)
      :observer-atoms   (take 5 (:observer-atoms ctx))
      :observer-curve-valid (map :curve-valid specialists)
      :observer-resolved-lens (map (lambda (o) (len (:resolved o))) specialists)
      :observer-resolved-accs (map :cached-acc specialists)
      :observer-vecs    (take 5 observer-vecs)
      :generalist-pred  (nth observer-preds 5)
      :generalist-atom  (:generalist-atom ctx)
      :generalist-curve-valid (:curve-valid (nth (:observers desk) 5))
      :candle-atr       (:atr-r candle)
      :candle-hour      (:hour candle)
      :candle-day       (:day-of-week candle)
      :disc-strength    (last-disc-strength (:journal (nth (:observers desk) 5))))))

(define (conviction-threshold-quantile history quantile)
  "Percentile of conviction history."
  (let ((sorted (sort history)))
    (nth sorted (min (- (len sorted) 1)
                     (round (* (len sorted) quantile))))))

(define (market-moved? current-price last-exit-price last-exit-atr k-stop)
  "Has the market moved enough since the last exit to justify re-entry?
   A condition, not a timer — the market tells us when it's ready."
  (or (= last-exit-price 0)
      (> (/ (abs (- current-price last-exit-price)) last-exit-price)
         (* k-stop last-exit-atr))))

(define (all-gates-pass? desk portfolio manager-pred risk-mult candle fee-rate ctx)
  "8 conditions, ALL must hold. Pure predicate — no mutation.
   fee-rate is pre-computed by caller (tempered: computed once, not per-gate)."
  (let ((meta-dir        (:direction manager-pred))
        (meta-conviction (:conviction manager-pred)))
    (and (= (:asset-mode ctx) "hold")
         (!= (:phase portfolio) :observe)
         (:manager-curve-valid desk)
         (>= meta-conviction (first (:manager-proven-band desk)))
         (<  meta-conviction (second (:manager-proven-band desk)))
         (market-moved? (:close candle) (:last-exit-price desk)
                        (:last-exit-atr desk) (:k-stop ctx))
         (> risk-mult 0.3)
         (or (= meta-dir (:manager-buy desk)) (= meta-dir (:manager-sell desk)))
         (> (* (:atr-r candle) 6.0) (* 2.0 fee-rate)))))

(define (compute-position-size band-edge risk-mult max-single)
  "Half-Kelly modulated by risk, capped."
  (min (* (/ band-edge 2.0) risk-mult) max-single))

(define (should-label? entry abs-move ctx)
  "Has the price crossed the move threshold since entry?
   abs-move is pre-computed by the caller (tempered: no recomputation)."
  (and (not (:first-outcome entry))
       (> abs-move (:move-threshold ctx))))

;; entry-label was inlined into the let* block (price-rose already bound).

(define (entry-expired? entry encode-count ctx)
  "Has the entry been pending longer than 10× the horizon?"
  (> (- encode-count (:candle-idx entry)) (* 10 (:horizon ctx))))

;; ── The organization ────────────────────────────────────────────────
;;
;;  Treasury (root — holds assets, executes swaps)
;;  ├── Desk[0] (btc-usdc — one pair's full enterprise tree)
;;  │   ├── Indicator bank (streaming fold — SMA, RSI, ATR, MACD, ...)
;;  │   ├── Candle window (ring buffer — last N computed candles)
;;  │   ├── Thought encoder (encodes from window, not global array)
;;  │   ├── Observers[6] (5 specialists + generalist, each at own window scale)
;;  │   │   └── each: Journal, WindowSampler, proof gate
;;  │   ├── Manager (reads observer opinions → direction + conviction)
;;  │   │   rune:scry(aspirational) — learns but does not yet act
;;  │   ├── Exit Observer (learns Hold/Exit from position state)
;;  │   │   rune:scry(aspirational) — risk manager with Journal not yet built
;;  │   └── Positions (ManagedPosition lifecycle: entry → runner → exit)
;;  ├── Desk[1] (future: eth-usdc, sol-usdc, ...)
;;  ├── Risk department (OnlineSubspace × 5 — portfolio-level health)
;;  └── Portfolio (phase transitions, win/loss tracking)
;;
;; Each desk owns its indicators, its window, its encoding.
;; No consumer reaches into a global candle array.
;; Each consumer retains exactly the data it needs.
;;
;; rune:scry(aspirational) — the architecture supports N desks:
;;   (for-each on-candle-desk (:desks state))
;; One desk today. The list has one element. Adding a pair = pushing a desk.

;; ── What the enterprise does NOT do ─────────────────────────────────
;; - Does NOT pre-compute indicators (that's the desk's indicator bank)
;; - Does NOT pre-encode thoughts (that's the desk's thought encoder)
;; - Does NOT hold a global candle array (each desk owns its window)
;; - Does NOT batch encode in parallel (websocket doesn't batch)
;; - Does NOT write to the database (that's the ledger flush, called by the binary)
;;   (But it DOES encode manager thoughts, exit observer thoughts, and risk features)
;;
;;   Cross-desk risk (Template 2 on treasury-level observables)
;;   Cross-desk treasury (shared asset pool with claim/release)
;;   Cross-desk portfolio (shared phase transitions)
