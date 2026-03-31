;; ── enterprise.wat — the fold ────────────────────────────────────────
;;
;; The enterprise is a fold over Stream<EnrichedEvent>.
;; (state, event) → state. One struct. One step function.
;; The enterprise doesn't know where events come from.

(require core/primitives)
(require core/structural)
(require std/memory)
(require std/patterns)

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

;; rune:reap(scaffolding) — Deposit/Withdraw variants exist but are
;; never constructed in the current backtest runner.

;; ── The fold step ───────────────────────────────────────────────────

(define (on-event state event ctx)
  "The enterprise processes one event. The fold IS the heartbeat."
  (match event
    (enriched-event-candle candle fact-labels observer-vecs)
      (on-candle state candle fact-labels observer-vecs ctx)
    :deposit
      (update state :treasury (deposit (:treasury state) (:asset event) (:amount event)))
    :withdraw
      (update state :treasury (withdraw (:treasury state) (:asset event) (:amount event)))))

;; ── The candle step ─────────────────────────────────────────────────

(define (on-candle state candle fact-labels observer-vecs ctx)
  "One candle. The fold's inner step."
  ;; rune:scry(stale-spec) — the layer ordering below says risk(3) → open(4) → tick(5),
  ;; but the Rust executes tick(5) → open(4) → risk(3). Positions are ticked before
  ;; new ones open, and risk is computed after opening — not before. The wat layer
  ;; numbers do not match the actual execution order in state.rs on_candle_inner.

  (let* (;; 1. Experts predict (LAYER 1)
         (observer-preds (map (lambda (obs vec) (predict (:journal obs) vec))
                              (:observers state) observer-vecs))
         (generalist-pred (nth observer-preds 5))

         ;; 2. Manager reads expert opinions (LAYER 2)
         (manager-thought (encode-manager-thought observer-preds candle state ctx))
         (manager-pred    (predict (:mgr-journal state) manager-thought))

         ;; 3. Risk assesses portfolio health (LAYER 3)
         (risk-mult (risk-multiplier (:portfolio state)))

         ;; 4. Treasury decides and executes (LAYER 4)
         ;; rune:scry(evolved) — code has 8 gate conditions, see treasury.wat
         (_  (when (should-open? state manager-pred risk-mult candle ctx)
               (open-managed-position state manager-pred candle ctx)))

         ;; 5. Manage open positions (LAYER 5)
         (_  (tick-positions state candle ctx))

         ;; 6. Learn from outcomes (LAYER 6)
         (_  (resolve-pending state candle ctx)))

    ;; rune:scry(evolved) — code has additional unlisted steps between layers:
    ;; - Panel engram (Template 2 reaction) between manager(2) and tick
    ;; - Conviction threshold recomputation (quantile or exponential curve fit)
    ;; - Adaptive decay (generalist vs specialist rates) after pending push
    ;; - Manager proven band scan after recalibration
    ;; These are real fold steps that mutate state but the wat omits them.

    ;; 7. Ledger: pending-logs accumulates LogEntry values.
    ;; The caller flushes. The fold is pure.
    ;; rune:scry(stale-spec) — "the fold is pure" is aspirational. The Rust fold
    ;; takes &mut self and returns (). It IS a fold (state × event → state) but
    ;; purity is a lie — the implementation mutates in place, not via return.
    state))

;; ── The organization ────────────────────────────────────────────────
;;
;;  Treasury (root — holds assets, executes swaps)
;;  │
;;  ├── Manager (branch — reads expert opinions, learns configurations)
;;  │   ├── Momentum observer      (leaf — speed and direction)
;;  │   ├── Structure observer     (leaf — geometric shape)
;;  │   ├── Volume observer        (leaf — participation)
;;  │   ├── Narrative observer     (leaf — story and timing)
;;  │   ├── Regime observer        (leaf — market character)
;;  │   └── Generalist observer    (leaf — all facts, fixed window)
;;  │
;;  ├── Exit expert (leaf — position state → hold/exit)
;;  │
;;  ├── Risk branches (5 × OnlineSubspace — anomaly, not direction)
;;  │   ├── Drawdown, Accuracy, Volatility, Correlation, Panel
;;  │   └── rune:scry(aspirational) — risk manager with Journal not yet built
;;  │
;;  └── Ledger (records everything, decides nothing)

;; ── Interfaces ──────────────────────────────────────────────────────
;;
;; Observer  → (predict journal thought) → Prediction
;; Manager   → (predict mgr-journal manager-thought) → Prediction
;; Exit      → (predict exit-journal exit-thought) → Prediction
;;   rune:scry(aspirational) — exit expert learns but does not yet act;
;;   see rune in state.rs ExitAtoms. Prediction is computed but never read.
;; Risk      → (risk-multiplier portfolio) → Float [0.0, 1.0]
;;   rune:scry(stale-spec) — risk-multiplier range is [0.1, 1.0] in code,
;;   not [0.0, 1.0]. worst_ratio is clamped with .max(0.1) in state.rs.
;; Treasury  → (swap treasury from to amount price fee) → (spent, received)
;; Ledger    → pending-logs : Vec<LogEntry> — flushed by caller

;; ── Multi-desk (future) ─────────────────────────────────────────────
;;
;; rune:scry(aspirational) — the architecture supports N desks:
;;
;;  Treasury (shared root)
;;  ├── BTC Desk (own observers, own manager, own risk, own portfolio)
;;  ├── ETH Desk (same shape, different candle stream)
;;  └── Cross-desk risk (Template 2 on treasury-level observables)
;;
;; Each desk is a self-contained fold. The treasury is shared.
;; Per-asset indicator engines feed per-asset encoding functors
;; into a merged event stream consumed by the shared fold.
;; See proposal 004 (streaming indicators).

;; ── What the enterprise does NOT do ─────────────────────────────────
;; - Does NOT know its event source (backtest, websocket, test harness)
;; - Does NOT encode candles (that's the encoding functor, outside the fold)
;;   rune:scry(stale-spec) — partially true. Candle→thought encoding is outside
;;   the fold (enterprise.rs parallel loop). But manager encoding, exit expert
;;   encoding, and risk branch encoding all happen INSIDE on_candle_inner.
;;   The fold does encode — just not candle→thought.
;; - Does NOT write to the database (that's the caller, via flush-logs)
;; - The fold is pure: State × Event → State
;;   rune:scry(stale-spec) — &mut self, returns (). See purity rune above.
