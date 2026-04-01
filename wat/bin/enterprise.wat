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

(struct enterprise-state
  ;; Learning
  mgr-journal mgr-buy mgr-sell prev-mgr-thought
  exit-journal exit-hold exit-exit exit-pending

  ;; Observers (6: momentum, structure, volume, narrative, regime, full)
  observers

  ;; Risk
  risk-branches cached-risk-mult
  cached-curve-a cached-curve-b kelly-curve-valid
  mgr-curve-valid mgr-resolved mgr-proven-band

  ;; Panel engram
  panel-engram panel-recalib-wins panel-recalib-total

  ;; Treasury + portfolio
  treasury portfolio peak-treasury-equity

  ;; Positions
  pending positions next-position-id
  last-exit-price last-exit-atr

  ;; Hold-mode
  hold-swaps hold-wins

  ;; Adaptive decay
  adaptive-decay in-adaptation highconv-wins

  ;; Tracking
  encode-count labeled-count noise-count
  move-sum move-count log-step db-batch

  ;; Conviction
  conviction-threshold conviction-history
  resolved-preds pending-logs cursor)

;; ── The event ───────────────────────────────────────────────────────

(struct enriched-event-candle
  candle fact-labels observer-vecs)

;; rune:reap(scaffolding) — Deposit/Withdraw exist but are never constructed.

;; ── The fold step ───────────────────────────────────────────────────

(define (on-event state event ctx)
  (match event
    (enriched-event-candle candle fact-labels observer-vecs)
      (on-candle state candle fact-labels observer-vecs ctx)
    :deposit  (deposit (:treasury state) (:asset event) (:amount event))
    :withdraw (withdraw (:treasury state) (:asset event) (:amount event))))

;; ── The candle step (honest execution order) ────────────────────────

;; rune:assay(hollow) — on-candle expresses steps 1-3 and 6. Steps 4-5, 7-13 are
;; prose descriptions, not s-expressions. The fold step returns state unchanged.
;; 30% expressed, 70% narrated. The forge cannot test the narrated joints.
(define (on-candle state candle fact-labels observer-vecs ctx)
  "One candle. The fold's inner step. Order matches state.rs on_candle_inner."

  ;; ─── 1. Observer predictions ──────────────────────────────────────
  ;; Each observer predicts from its pre-encoded thought vector.
  ;; The generalist is observers[5] with profile "full".
  (let* ((observer-preds
           (map (lambda (obs vec) (predict (:journal obs) vec))
                (:observers state) observer-vecs))
         (generalist-pred (nth observer-preds 5))
         (generalist-vec  (nth observer-vecs 5))

  ;; ─── 2. Manager encoding + prediction ─────────────────────────────
  ;; Encodes expert opinions as signed convictions with credibility.
  ;; Then DELTA-ENRICHES: binds difference(prev-thought, current-thought)
  ;; so the manager sees MOTION, not just position.
         ;; encode-manager-thought: defined in market/manager.wat as manager-thought.
         ;; Encodes observer predictions as signed convictions with credibility,
         ;; plus panel shape, market context, and motion delta.
         (mgr-facts    (manager-thought observer-preds candle state ctx))
         (mgr-thought  (bundle mgr-facts))
         (delta        (when (:prev-mgr-thought state)
                         (bind (:delta-atom ctx)
                               (difference (:prev-mgr-thought state) mgr-thought))))
         (final-thought (if delta (bundle mgr-thought delta) mgr-thought))
         (manager-pred  (predict (:mgr-journal state) final-thought))

  ;; ─── 3. Panel engram ──────────────────────────────────────────────
  ;; Template 2 reaction: learns what "good panel state" looks like.
  ;; panel-familiar = residual < threshold. Display only (for now).
         (panel-state   (map :raw-cosine observer-preds))
         (panel-familiar (< (residual (:panel-engram state) panel-state)
                            (threshold (:panel-engram state))))

  ;; ─── 4. Conviction threshold ──────────────────────────────────────
  ;; Recomputed periodically. Two modes:
  ;;   "quantile" — percentile of conviction history
  ;;   "auto" — exponential curve fit (20 bins, log-linear regression)
  ;; This determines what conviction level counts as "high."
         ;; (recompute-conviction-threshold state ctx)

  ;; ─── 5. Position tick + exit expert ───────────────────────────────
  ;; For each open managed position:
  ;;   a. Exit observer encodes position state (8 bound facts)
  ;;   b. Exit expert buffers observation for deferred learning
  ;;   c. Position ticks (trailing stop, high-water mark)
  ;;   d. On exit signal: treasury swap, fee accounting, ledger log
         ;; (tick-positions state candle ctx)

  ;; ─── 6. Risk evaluation ───────────────────────────────────────────
  ;; Portfolio → 5 risk branch feature vectors (drawdown, accuracy,
  ;; volatility, correlation, panel). Gated update: only learn from
  ;; healthy states (drawdown < 2%, accuracy > 55%, positive returns,
  ;; 20+ trades). Risk multiplier = min(threshold/residual) across
  ;; branches, floored at 0.1.
         ;; risk-multiplier: defined in risk/mod.wat. Updates branches when healthy,
         ;; returns min(threshold/residual) across all branches, floored at 0.1.
         (risk-mult (risk-multiplier (:portfolio state)))

  ;; ─── 7. Position opening ──────────────────────────────────────────
  ;; 8 gate conditions, ALL must pass:
  ;;   1. asset-mode == "hold"
  ;;   2. portfolio phase != Observe
  ;;   3. manager curve valid (proven band exists)
  ;;   4. conviction in proven band
  ;;   5. market moved since last exit (k-stop × last-exit-atr)
  ;;   6. risk allows (cached-risk-mult > 0.3)
  ;;   7. manager direction is Buy or Sell (not silence)
  ;;   8. expected move > 2 × fee rate (profitability gate)
         ;; (when (all-gates-pass? state manager-pred risk-mult candle ctx)
         ;;   (open-managed-position state manager-pred candle ctx))

  ;; ─── 8. Sizing ────────────────────────────────────────────────────
  ;; How much capital: (* (/ band-edge 2.0) risk-mult)
  ;; Capped by max-single-position. This is half-Kelly modulated by risk.
  ;; The most important economic decision in the fold.
         ;; (position-size band-edge risk-mult)

  ;; ─── 9. Pending push ─────────────────────────────────────────────
  ;; Store entry state for deferred learning. 25+ fields on Pending.
  ;; Includes: entry price, ATR, all observer vectors and predictions,
  ;; the complete manager thought (for one-encoding-path learning).

  ;; ─── 10. Decay ────────────────────────────────────────────────────
  ;; All journals decay once per candle.
  ;; Generalist: adaptive-decay (regime-responsive).
  ;; Specialists: fixed decay rate.
         ;; (for-each (lambda (obs) (decay (:journal obs) decay-rate)) (:observers state))
         ;; (decay (:mgr-journal state) adaptive-decay)

  ;; ─── 11. Event-driven learning ────────────────────────────────────
  ;; For each pending entry, every candle:
  ;;   a. Track directional excursion (MFE, MAE)
  ;;   b. Manage trailing stop and take-profit per entry
  ;;   c. On first threshold crossing:
  ;;      - Label = Buy if price up, Sell if price down
  ;;      - All 6 observers learn (observe journal vec label signal-weight)
  ;;      - signal-weight scales by move magnitude
  ;;      - Record crossing metadata (candles, timestamp, price)

  ;; ─── 12. Resolution ───────────────────────────────────────────────
  ;; Pending entries expire at 10× horizon (safety valve).
  ;; On resolution:
  ;;   a. Manager learns direction from stored thought
  ;;      (observe mgr-journal stored-thought price-direction-label 1.0)
  ;;   b. Track manager accuracy in mgr-resolved deque
  ;;   c. TradePnl computed (pure accounting)
  ;;   d. Treasury settles (close-position)
  ;;   e. Ledger logs trade
  ;;   f. Risk diagnostics (adaptive decay state machine)
  ;;   g. On recalibration: refit Kelly curve, scan proven band,
  ;;      feed panel engram, decode discriminant

  ;; ─── 13. Log ──────────────────────────────────────────────────────
  ;; pending-logs accumulates LogEntry values. The caller flushes.
         )
    state))

;; ── The organization ────────────────────────────────────────────────
;;
;;  Treasury (root — holds assets, executes swaps)
;;  ├── Manager (branch — reads expert opinions, learns configurations)
;;  │   ├── Momentum      (leaf — speed and direction)
;;  │   ├── Structure     (leaf — geometric shape)
;;  │   ├── Volume        (leaf — participation)
;;  │   ├── Narrative     (leaf — story and timing)
;;  │   ├── Regime        (leaf — market character)
;;  │   └── Generalist    (leaf — all facts, fixed window)
;;  ├── Exit expert (leaf — position state → hold/exit)
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
;;   See proposal 004 (streaming indicators).

;; ── What the enterprise does NOT do ─────────────────────────────────
;; - Does NOT know its event source (backtest, websocket, test harness)
;; - Does NOT encode candle→thought (that's the encoding functor, outside)
;;   (But it DOES encode manager thoughts, exit expert thoughts, and risk features)
;; - Does NOT write to the database (pending-logs, caller flushes)

;; ── Open questions (from std-candidates graduation) ─────────────────
;;
;; zero-vector: The identity element of bundle needs dims because vectors
;; are fixed-dimensionality. (bundle) alone cannot know the size.
;; The Rust creates vec![0.0; dims]. No wat equivalent exists yet.
;;
;; Designer question: Should (bundle) with no args be a lazy identity
;; that adopts the dimensionality of the next bundle call? If so,
;; zero-vector becomes (bundle) and dims is unnecessary.
;; This is an algebra question: does the monoid identity know its size?
