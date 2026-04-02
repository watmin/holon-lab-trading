;; ── enterprise.wat — the fold ────────────────────────────────────────
;;
;; The enterprise is a fold over Stream<EnrichedEvent>.
;; (state, event) → state. One struct. One step function.
;; The enterprise doesn't know where events come from.
;;
;; The fold mutates &mut self in place. It is a fold in shape
;; (state × event → state) but not in purity. This is Rust, not Lisp.

(require core/primitives)
(require core/structural)
(require std/memory)
(require patterns)

;; ── The state ───────────────────────────────────────────────────────
;; The enterprise owns shared resources. Each desk owns per-pair state.
;; The heartbeat iterates desks. The treasury serves them all.

(struct enterprise-state
  ;; Desks: one per trading pair. Vec<Desk> with one element today.
  desks                  ; (list Desk) — each owns observers, manager, positions

  ;; Shared resources (not per-desk)
  treasury               ; Treasury — holds all assets, serves all desks
  portfolio              ; Portfolio — phase transitions, win/loss tracking

  ;; Risk department — measures portfolio health across ALL desks.
  ;; Drawdown, accuracy, volatility, correlation, panel.
  ;; The desk produces signals. Risk gates the enterprise's response.
  risk-branches          ; (list OnlineSubspace) — 5 anomaly detectors
  cached-risk-mult       ; f64 — last computed risk multiplier

  ;; Shared tracking (aggregated from desks in on-event)
  labeled-count          ; total labeled entries across all desks
  noise-count            ; total noise entries across all desks

  ;; Logging
  pending-logs           ; (list LogEntry) — accumulated, flushed per batch
  cursor)                ; current position in the candle stream

;; ── The event ───────────────────────────────────────────────────────

(struct enriched-event-candle
  candle fact-labels observer-vecs)

;; rune:reap(scaffolding) — Deposit/Withdraw exist but are never constructed.

;; ── The fold step ───────────────────────────────────────────────────
;; The enterprise iterates desks. Each desk processes events for its pair.
;; The treasury is shared — passed to each desk for position management.

(define (on-event state event ctx)
  (match event
    (enriched-event-candle candle fact-labels observer-vecs)
      ;; Route candle to the desk that trades this pair.
      ;; For now: one desk, one pair, all candles go to desk[0].
      ;; Multi-pair: match event asset to desk's source/target.
      (let* ((desk (first (:desks state)))
             ;; Risk department: evaluate portfolio health before desk acts.
             ;; rune:scry(evolved) — Rust caches at recalib intervals; wat evaluates every candle.
             (risk-mult (risk-multiplier (:portfolio state) (:risk-branches state)))
             ((updated-desk treasury portfolio)
               (on-candle-desk desk candle fact-labels observer-vecs
                               (:treasury state) (:portfolio state) risk-mult ctx)))
          (update state
            :desks (list updated-desk)
            :treasury treasury
            :portfolio portfolio
            :cached-risk-mult risk-mult
            :move-sum (:move-sum updated-desk)
            :move-count (:move-count updated-desk)
            :labeled-count (+ (:labeled-count state) (:labeled-count updated-desk))
            :noise-count (+ (:noise-count state) (:noise-count updated-desk)))))
    :deposit  (update state :treasury (deposit (:treasury state) (:asset event) (:amount event)))
    :withdraw (update state :treasury (withdraw (:treasury state) (:asset event) (:amount event)))))

;; ── Pure gates and decisions ────────────────────────────────────────
;;
;; The forgeable cores. Each is a pure function — data in, data out.
;; The fold calls these. The mutation wraps them.

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



(define (should-label? entry candle ctx)
  "Has the price crossed the move threshold since entry?"
  (let ((move (/ (abs (- (:close candle) (:entry-price entry)))
                 (:entry-price entry))))
    (and (not (:first-outcome entry))
         (> move (:move-threshold ctx)))))

(define (entry-label entry candle mgr-buy mgr-sell)
  "Buy if price went up, Sell if price went down."
  (if (> (:close candle) (:entry-price entry)) mgr-buy mgr-sell))

(define (entry-expired? entry candle-idx ctx)
  "Safety valve: pending entries expire at 10× horizon."
  (> (- candle-idx (:candle-idx entry)) (* 10 (:horizon ctx))))

;; ── The candle step ────────────────────────────────────────────────
;; Pure-ish function: desk owns prediction/learning state.
;; Treasury and portfolio are passed in (shared across desks) and returned
;; because position management mutates them.
;;
;; (desk, candle, fact-labels, observer-vecs, treasury, portfolio, ctx)
;;   → (desk, treasury, portfolio)

(define (on-candle-desk desk candle fact-labels observer-vecs treasury portfolio risk-mult ctx)
  "One candle for one desk. Returns (desk treasury portfolio).
   risk-mult is from the enterprise's risk department, not the desk."

  (let ((quote-price (:close candle))
        (fee-rate    (+ (:swap-fee ctx) (:slippage ctx))))

  ;; ─── 1. Observer predictions ──────────────────────────────────────
  (let* ((observer-preds
           (map (lambda (obs vec) (predict (:journal obs) vec))
                (:observers desk) observer-vecs))
         (generalist-pred (nth observer-preds 5))
         (generalist-vec  (nth observer-vecs 5))

  ;; ─── 2. Manager encoding + prediction ─────────────────────────────
         (mgr-ctx      (build-manager-context desk observer-preds observer-vecs candle ctx))
         (mgr-facts    (encode-manager-thought
                         (:manager-atoms ctx) mgr-ctx
                         (:dims ctx) (:prev-manager-thought? desk)))
         (mgr-thought  (bundle mgr-facts))
         (manager-pred (predict (:manager-journal desk) mgr-thought))
         (meta-dir        (:direction manager-pred))
         (meta-conviction (:conviction manager-pred))

  ;; ─── 3. Panel engram state (for engram update at recalibration) ────
         (panel-state   (map :raw-cosine observer-preds))
         ;; rune:reap(aspirational) — panel-familiar will gate position entry
         ;; when panel engram matures. Currently computed in Rust for logging only.

  ;; ─── 6. Risk — passed in from enterprise, not computed per-desk ────
         )

    ;; ─── 4. Conviction tracking ───────────────────────────────────────
    (push-back (:conviction-history desk) meta-conviction)
    (when (> (len (:conviction-history desk)) (:conviction-window ctx))
      (pop-front (:conviction-history desk)))

    (when (and (>= (len (:conviction-history desk)) (:conviction-warmup ctx))
               (= (mod (:encode-count desk) (:recalib-interval ctx)) 0))
      (match (:conviction-mode ctx)
        :quantile
          (set! (:conviction-threshold desk)
                (conviction-threshold-quantile (:conviction-history desk)
                                               (:conviction-quantile ctx)))
        :auto
          ;; rune:assay(prose) — auto mode fits exponential curve via log-linear
          ;; regression on 20 binned resolved predictions. See sizing.wat
          ;; kelly-frac for the shared curve-fitting algorithm.
          (when-let ((curve (log-linear-regression
                      (bin (:resolved-preds desk) 20))))
            (let* ((a (first curve)) (b (second curve)))
              (when (and (> b 0.0) (> (:min-edge ctx) 0.50))
                (let ((target (/ (- (:min-edge ctx) 0.50) a)))
                  (when (> target 0.0)
                    (let ((thresh (/ (ln target) b)))
                      (when (and (> thresh 0.0) (< thresh 1.0))
                        (set! (:conviction-threshold desk) thresh))))))))))

    ;; ─── 5. Position tick ─────────────────────────────────────────────
    (for-each (lambda (pos)
      ;; Exit observer encodes + buffers observation
      ;; Rate = source/target. Buy: rate = price. Sell: rate = 1/price.
      (let* ((is-buy     (= (:source-asset pos) (:base-asset ctx)))
             (current-rate (if is-buy quote-price (/ 1.0 quote-price)))
             (pnl-frac    (return-pct pos current-rate))
             (exit-thought (encode-position pos pnl-frac current-rate (:atr-r candle) is-buy)))
        (when (= (mod (:candles-held pos) (:exit-observe-interval ctx)) 0)
          (push-back (:exit-pending desk)
            (exit-observation :thought exit-thought
                              :pos-id (:id pos)
                              :snapshot-pnl pnl-frac
                              :snapshot-candle (:encode-count desk)))))

      ;; Tick trailing stop + take profit
      (let ((signal (tick pos current-rate (:k-trail ctx))))
        (when signal
          ;; Treasury settles the exit: release target, swap target→source.
          ;; Two-pass: pass 1 collects exit signals, pass 2 settles.
          (let ((sell-target (:target-held pos)))
            (release treasury (:target-asset pos) sell-target)
            (swap treasury (:target-asset pos) (:source-asset pos)
                  sell-target (/ 1.0 current-rate) fee-rate))
          (set! (:last-exit-price desk) quote-price)
          (set! (:last-exit-atr desk) (:atr-r candle))
          (set! (:phase pos) :closed))))
      (:positions desk))

    ;; ─── 7-8. Position opening + sizing ───────────────────────────────
    ;; One path for both directions. Direction determines source/target.
    ;; Buy: USDC→WBTC (rate = price). Sell: WBTC→USDC (rate = 1/price).
    (when (all-gates-pass? desk portfolio manager-pred risk-mult candle fee-rate ctx)
      (let* ((frac (compute-position-size 0.03 risk-mult (:max-single-position ctx)))
             (dir-label (:direction manager-pred))
             (is-buy (= dir-label (:manager-buy desk)))
             (source-asset (if is-buy (:base-asset ctx) (:quote-asset ctx)))
             (target-asset (if is-buy (:quote-asset ctx) (:base-asset ctx)))
             (rate (if is-buy quote-price (/ 1.0 quote-price)))
             (deploy-amount (* (balance treasury source-asset) frac))
             (usd-value (if is-buy deploy-amount (* deploy-amount quote-price))))
        (when (> usd-value 10.0)
          (let* (((spent received) (swap treasury source-asset target-asset
                                         deploy-amount rate fee-rate))
                 ;; Symmetric claim: lock received target in deployed.
                 (claimed (claim treasury target-asset received))
                 (pos (new-position
                        (position-entry
                          :id (:next-position-id desk)
                          :candle-idx (:encode-count desk)
                          :source-asset source-asset
                          :target-asset target-asset
                          :source-amount spent
                          :target-received received
                          :entry-rate rate
                          :entry-atr (:atr-r candle)
                          :entry-fee (* usd-value fee-rate)
                          :k-stop (:k-stop ctx)
                          :k-tp (:k-tp ctx)))))
            (push! (:positions desk) pos)
            (inc! (:next-position-id desk))
            (inc! (:position-swaps desk))))))

    ;; ─── 9. Pending push (ALL candles — learning, not treasury) ─────
    ;; Pending entries are for LEARNING, not for treasury. They record the
    ;; prediction so observers and manager can resolve against the outcome.
    ;; The treasury moves through ManagedPosition lifecycle (swap/claim/release),
    ;; NOT through pending entry resolution. No double-spending.
    (push! (:pending desk)
      (pending :candle-idx (:encode-count desk)
               :tht-vec mgr-thought
               :tht-pred manager-pred
               :meta-dir meta-dir
               :meta-conviction meta-conviction
               :entry-price quote-price
               :entry-atr (:atr-r candle)
               :observer-vecs observer-vecs
               :observer-preds observer-preds
               :manager-thought mgr-thought
               :fact-labels fact-labels))

    ;; ─── 10. Decay ──────────────────────────────────────────────────
    (for-each (lambda (obs)
      (decay (:journal obs) (:decay ctx)))
      (:observers desk))
    (decay (:manager-journal desk) (:adaptive-decay desk))

    ;; ─── 11-12. Learning + Resolution (single pass over pending) ─────
    ;; Tempered: was three separate passes (learn, resolve, filter).
    ;; Now one for-each handles all three concerns per entry.
    (let ((surviving (list)))
      (for-each (lambda (entry)
        ;; rune:temper(clarity) — price delta computed 3x per entry (move-pct, abs-move,
        ;; record-trade). The Rust will hoist (- close entry-price) once and derive all
        ;; three from it. The wat keeps the three separate for readability.
        ;; 11a. Track excursion
        (let ((move-pct (/ (- (:close candle) (:entry-price entry))
                           (:entry-price entry))))
          (set! (:max-favorable entry) (max (:max-favorable entry) move-pct))
          (set! (:max-adverse entry)   (min (:max-adverse entry) move-pct)))

        ;; 11b. First threshold crossing -> label + learn
        (when (should-label? entry candle ctx)
          (let ((label    (entry-label entry candle (:manager-buy desk) (:manager-sell desk)))
                (abs-move (/ (abs (- (:close candle) (:entry-price entry)))
                             (:entry-price entry)))
                (signal-wt (signal-weight abs-move (:move-sum desk) (:move-count desk))))
            (set! (:first-outcome entry) label)
            (for-each (lambda (obs vec)
              (observe (:journal obs) vec label signal-wt))
              (:observers desk) (:observer-vecs entry))
            (inc! (:labeled-count desk))))

        ;; 12. Resolution (if expired) or keep
        (if (entry-expired? entry (:encode-count desk) ctx)
            (let ((price-label (if (> (:close candle) (:entry-price entry))
                                   (:manager-buy desk) (:manager-sell desk))))
              (observe (:manager-journal desk) (:manager-thought entry) price-label 1.0)
              (push-back (:manager-resolved desk)
                (list (:meta-conviction entry)
                      (= (:first-outcome entry) price-label)))
              (for-each (lambda (obs pred)
                (resolve obs (:tht-vec entry) pred price-label 1.0
                         (:conviction-quantile ctx) (:conviction-window ctx)))
                (:observers desk) (:observer-preds entry))
              ;; Portfolio tracks every resolved prediction for phase transitions.
              ;; Treasury is NOT touched — capital moves through ManagedPosition only.
              ;; frac=0.0: this is a paper outcome, not a capital event.
              (record-trade portfolio
                            (/ (- (:close candle) (:entry-price entry))
                               (:entry-price entry))
                            0.0 (if (= (:meta-dir entry) (:manager-buy desk)) :long :short)
                            (:swap-fee ctx) (:slippage ctx)))
            ;; Not expired -- keep
            (push! surviving entry)))
        (:pending desk))
      (set! (:pending desk) surviving))

    ;; ─── 13. State bookkeeping ──────────────────────────────────────
    (set! (:prev-manager-thought? desk) mgr-thought)
    (inc! (:encode-count desk))
    ;; risk-mult is enterprise-level, not stored on desk

    ;; Return the triple: mutated desk, treasury, portfolio.
    (list desk treasury portfolio))))

;; ── The organization ────────────────────────────────────────────────
;;
;;  Treasury (root — holds assets, executes swaps)
;;  ├── Manager (branch — reads observer opinions, learns configurations)
;;  │   ├── Momentum      (leaf — speed and direction)
;;  │   ├── Structure     (leaf — geometric shape)
;;  │   ├── Volume        (leaf — participation)
;;  │   ├── Narrative     (leaf — story and timing)
;;  │   ├── Regime        (leaf — market character)
;;  │   └── Generalist    (leaf — all facts, fixed window)
;;  ├── Exit observer (leaf — position state → hold/exit)
;;  │   rune:scry(aspirational) — learns but does not yet act
;;  ├── Risk branches (5 × OnlineSubspace — anomaly, not direction)
;;  │   rune:scry(aspirational) — risk manager with Journal not yet built
;;  └── Ledger (records everything, decides nothing)

;; ── Interfaces ──────────────────────────────────────────────────────
;;
;; Observer  → (predict journal thought)              → Prediction
;; Manager   → (predict mgr-journal final-thought)    → Prediction
;; Risk      → (risk-multiplier portfolio)            → Float [0.1, 1.0]
;; Treasury  → (swap treasury from to amount price fee) → (spent, received)
;; Ledger    → pending-logs : Vec<LogEntry> — flushed by caller

;; ── Multi-desk (future) ─────────────────────────────────────────────
;;
;; rune:scry(aspirational) — the architecture supports N desks:
;;   Treasury (shared) → BTC Desk | ETH Desk | ...
;;   Cross-desk risk (Template 2 on treasury-level observables)

;; ── What the enterprise does NOT do ─────────────────────────────────
;; - Does NOT know its event source (backtest, websocket, test harness)
;; - Does NOT encode candle→thought (that's the encoding functor, outside)
;;   (But it DOES encode manager thoughts, exit observer thoughts, and risk features)
;; - Does NOT write to the database (pending-logs, caller flushes)
