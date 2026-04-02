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
  desks                  ; (list Desk) — each owns observers, manager, risk, positions

  ;; Shared resources (not per-desk)
  treasury               ; Treasury — holds all assets, serves all desks
  portfolio              ; Portfolio — phase transitions, win/loss tracking

  ;; Shared tracking
  labeled-count          ; total labeled entries across all desks
  noise-count            ; total noise entries across all desks
  move-sum               ; running sum for signal_weight
  move-count             ; running count for signal_weight

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
      (let ((desk (first (:desks state))))
        (let ((updated-desk (on-candle-desk desk candle fact-labels observer-vecs
                                            (:treasury state) (:portfolio state) ctx)))
          (update state :desks (list updated-desk))))
    :deposit  (update state :treasury (deposit (:treasury state) (:asset event) (:amount event)))
    :withdraw (update state :treasury (withdraw (:treasury state) (:asset event) (:amount event)))))

;; ── Pure gates and decisions ────────────────────────────────────────
;;
;; The forgeable cores. Each is a pure function — data in, data out.
;; The fold calls these. The mutation wraps them.

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

(define (all-gates-pass? state manager-pred risk-mult candle ctx)
  "8 conditions, ALL must hold. Pure predicate — no mutation."
  (let ((meta-dir        (:direction manager-pred))
        (meta-conviction (:conviction manager-pred))
        (fee-rate        (+ (:swap-fee ctx) (:slippage ctx))))
    (and (= (:asset-mode ctx) "hold")
         (!= (:phase (:portfolio state)) :observe)
         (:mgr-curve-valid state)
         (>= meta-conviction (first (:mgr-proven-band state)))
         (<  meta-conviction (second (:mgr-proven-band state)))
         (market-moved? (:close candle) (:last-exit-price state)
                        (:last-exit-atr state) (:k-stop ctx))
         (> (:cached-risk-mult state) 0.3)
         (or (= meta-dir (:mgr-buy state)) (= meta-dir (:mgr-sell state)))
         (> (* (:atr-r candle) 6.0) (* 2.0 fee-rate)))))

(define (compute-position-size band-edge risk-mult max-single)
  "Half-Kelly modulated by risk, capped."
  (min (* (/ band-edge 2.0) risk-mult) max-single))

(define (trade-direction manager-pred mgr-buy)
  "Manager direction → position direction."
  (if (= (:direction manager-pred) mgr-buy) :long :short))

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

(define (on-candle state candle fact-labels observer-vecs ctx)
  "One candle. The fold's inner step."

  ;; ─── 1. Observer predictions ──────────────────────────────────────
  (let* ((observer-preds
           (map (lambda (obs vec) (predict (:journal obs) vec))
                (:observers state) observer-vecs))
         (generalist-pred (nth observer-preds 5))
         (generalist-vec  (nth observer-vecs 5))

  ;; ─── 2. Manager encoding + prediction ─────────────────────────────
         (mgr-facts    (encode-manager-thought
                         (:mgr-atoms ctx) (manager-context state observer-preds
                           observer-vecs candle ctx)
                         (:dims ctx) (:prev-mgr-thought state)))
         (mgr-thought  (bundle mgr-facts))
         (manager-pred (predict (:mgr-journal state) mgr-thought))
         (meta-dir        (:direction manager-pred))
         (meta-conviction (:conviction manager-pred))

  ;; ─── 3. Panel engram ──────────────────────────────────────────────
         (panel-state   (map :raw-cosine observer-preds))
         (panel-familiar (< (residual (:panel-engram state) panel-state)
                            (threshold (:panel-engram state))))

  ;; ─── 6. Risk evaluation ───────────────────────────────────────────
         (risk-mult (risk-multiplier (:portfolio state))))

    ;; ─── 4. Conviction tracking ───────────────────────────────────────
    (push-back (:conviction-history state) meta-conviction)
    (when (> (len (:conviction-history state)) (:conviction-window ctx))
      (pop-front (:conviction-history state)))

    (when (and (>= (len (:conviction-history state)) (:conviction-warmup ctx))
               (= (mod (:encode-count state) (:recalib-interval ctx)) 0))
      (match (:conviction-mode ctx)
        :quantile
          (set! (:conviction-threshold state)
                (conviction-threshold-quantile (:conviction-history state)
                                               (:conviction-quantile ctx)))
        :auto
          ;; rune:assay(prose) — auto mode fits exponential curve via log-linear
          ;; regression on 20 binned resolved predictions. See sizing.wat
          ;; kelly-frac for the shared curve-fitting algorithm.
          (when-let ((curve (log-linear-regression
                      (bin (:resolved-preds state) 20))))
            (let* ((a (first curve)) (b (second curve)))
              (when (and (> b 0.0) (> (:min-edge ctx) 0.50))
                (let ((target (/ (- (:min-edge ctx) 0.50) a)))
                  (when (> target 0.0)
                    (let ((thresh (/ (ln target) b)))
                      (when (and (> thresh 0.0) (< thresh 1.0))
                        (set! (:conviction-threshold state) thresh))))))))))

    ;; ─── 5. Position tick ─────────────────────────────────────────────
    (for-each (lambda (pos)
      ;; Exit observer encodes + buffers observation
      ;; Rate = source/target. Buy: rate = price. Sell: rate = 1/price.
      (let* ((is-buy     (= (:source-asset pos) (:base-asset ctx)))
             (current-rate (if is-buy quote-price (/ 1.0 quote-price)))
             (pnl-frac    (return-pct pos current-rate))
             (exit-thought (encode-position pos pnl-frac current-rate (:atr-r candle) is-buy)))
        (when (= (mod (:candles-held pos) (:exit-observe-interval ctx)) 0)
          (push-back (:exit-pending state)
            (exit-observation :thought exit-thought
                              :pos-id (:id pos)
                              :snapshot-pnl pnl-frac
                              :snapshot-candle (:encode-count state)))))

      ;; Tick trailing stop + take profit
      (let ((signal (tick pos current-rate (:k-trail ctx))))
        (when signal
          ;; Treasury settles the exit: release target, swap target→source.
          ;; Two-pass: pass 1 collects exit signals, pass 2 settles.
          (let ((sell-target (:target-held pos)))
            (release (:treasury state) (:target-asset pos) sell-target)
            (swap (:treasury state) (:target-asset pos) (:source-asset pos)
                  sell-target (/ 1.0 current-rate) fee-rate))
          (set! (:last-exit-price state) quote-price)
          (set! (:last-exit-atr state) (:atr-r candle))
          (set! (:phase pos) :closed))))
      (:positions state))

    ;; ─── 7-8. Position opening + sizing ───────────────────────────────
    ;; One path for both directions. Direction determines source/target.
    ;; Buy: USDC→WBTC (rate = price). Sell: WBTC→USDC (rate = 1/price).
    (when (all-gates-pass? state manager-pred risk-mult candle ctx)
      (let* ((frac (compute-position-size 0.03 risk-mult (:max-single-position ctx)))
             (dir-label (:direction manager-pred))
             (is-buy (= dir-label (:mgr-buy state)))
             (source-asset (if is-buy (:base-asset ctx) (:quote-asset ctx)))
             (target-asset (if is-buy (:quote-asset ctx) (:base-asset ctx)))
             (rate (if is-buy quote-price (/ 1.0 quote-price)))
             (deploy-amount (* (balance (:treasury state) source-asset) frac))
             (usd-value (if is-buy deploy-amount (* deploy-amount quote-price))))
        (when (> usd-value 10.0)
          (let* (((spent received) (swap (:treasury state) source-asset target-asset
                                         deploy-amount rate fee-rate))
                 ;; Symmetric claim: lock received target in deployed.
                 (claimed (claim (:treasury state) target-asset received))
                 (pos (new-position
                        (position-entry
                          :id (:next-position-id state)
                          :candle-idx (:encode-count state)
                          :source-asset source-asset
                          :target-asset target-asset
                          :source-amount spent
                          :target-received received
                          :entry-rate rate
                          :entry-atr (:atr-r candle)
                          :entry-fee (* usd-value fee-rate)
                          :k-stop (:k-stop ctx)
                          :k-tp (:k-tp ctx)))))
            (push! (:positions state) pos)
            (inc! (:next-position-id state))
            (inc! (:hold-swaps state))))))

    ;; ─── 9. Pending push (ALL candles — learning, not treasury) ─────
    ;; Pending entries are for LEARNING, not for treasury. They record the
    ;; prediction so observers and manager can resolve against the outcome.
    ;; The treasury moves through ManagedPosition lifecycle (swap/claim/release),
    ;; NOT through pending entry resolution. No double-spending.
    (push! (:pending state)
      (pending :candle-idx (:encode-count state)
               :tht-vec mgr-thought
               :tht-pred manager-pred
               :meta-dir meta-dir
               :meta-conviction meta-conviction
               :entry-price (:close candle)
               :entry-atr (:atr-r candle)
               :observer-vecs observer-vecs
               :observer-preds observer-preds
               :mgr-thought mgr-thought
               :fact-labels fact-labels))

    ;; ─── 10. Decay ──────────────────────────────────────────────────
    (for-each (lambda (obs)
      (decay (:journal obs) (:decay ctx)))
      (:observers state))
    (decay (:mgr-journal state) (:adaptive-decay state))

    ;; ─── 11-12. Learning + Resolution (single pass over pending) ─────
    ;; Tempered: was three separate passes (learn, resolve, filter).
    ;; Now one for-each handles all three concerns per entry.
    (let ((surviving (list)))
      (for-each (lambda (entry)
        ;; 11a. Track excursion
        (let ((move-pct (/ (- (:close candle) (:entry-price entry))
                           (:entry-price entry))))
          (set! (:max-favorable entry) (max (:max-favorable entry) move-pct))
          (set! (:max-adverse entry)   (min (:max-adverse entry) move-pct)))

        ;; 11b. First threshold crossing -> label + learn
        (when (should-label? entry candle ctx)
          (let ((label    (entry-label entry candle (:mgr-buy state) (:mgr-sell state)))
                (abs-move (/ (abs (- (:close candle) (:entry-price entry)))
                             (:entry-price entry)))
                (sw       (signal-weight abs-move (:move-sum state) (:move-count state))))
            (set! (:first-outcome entry) label)
            (for-each (lambda (obs vec)
              (observe (:journal obs) vec label sw))
              (:observers state) (:observer-vecs entry))
            (inc! (:labeled-count state))))

        ;; 12. Resolution (if expired) or keep
        (if (entry-expired? entry (:encode-count state) ctx)
            (let ((price-label (if (> (:close candle) (:entry-price entry))
                                   (:mgr-buy state) (:mgr-sell state))))
              (observe (:mgr-journal state) (:mgr-thought entry) price-label 1.0)
              (push-back (:mgr-resolved state)
                (list (:meta-conviction entry)
                      (= (:first-outcome entry) price-label)))
              (for-each (lambda (obs pred)
                (resolve obs (:tht-vec entry) pred price-label 1.0
                         (:conviction-quantile ctx) (:conviction-window ctx)))
                (:observers state) (:observer-preds entry))
              ;; Portfolio tracks every resolved prediction for phase transitions.
              ;; Treasury is NOT touched — capital moves through ManagedPosition only.
              ;; frac=0.0: this is a paper outcome, not a capital event.
              (record-trade (:portfolio state)
                            (/ (- (:close candle) (:entry-price entry))
                               (:entry-price entry))
                            0.0 (if (= (:meta-dir entry) (:mgr-buy state)) :long :short)
                            (:swap-fee ctx) (:slippage ctx)))
            ;; Not expired -- keep
            (push! surviving entry)))
        (:pending state))
      (set! (:pending state) surviving))

    ;; ─── 13. State bookkeeping ──────────────────────────────────────
    (set! (:prev-mgr-thought state) mgr-thought)
    (inc! (:encode-count state))
    (set! (:cached-risk-mult state) risk-mult)

    state))

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
