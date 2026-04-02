;; -- market/desk.wat -- a trading pair's full enterprise tree -----------------
;;
;; A desk trades one pair (source-asset / target-asset). It owns the complete
;; prediction + learning stack for that pair:
;;   - Observer panel (5 specialists + 1 generalist)
;;   - Manager journal (aggregates observer opinions)
;;   - Exit expert journal (learns hold/exit from position state)
;;   - Risk branches (5 OnlineSubspace per desk)
;;   - Positions (managed allocations from the treasury)
;;   - Pending entries (learning queue)
;;
;; The desk is a value. The enterprise iterates Vec<Desk>.
;; Each desk folds independently over its candle stream.
;; The treasury is shared — desks don't own capital, they request it.
;;
;; Two phases per candle:
;;   observe — always. Encode thoughts. Predict. Buffer pending.
;;   act     — only when gates pass. Request swap from treasury.

(require core/structural)
(require market/observer)
(require journal)
(require position)

;; ── Constants ──────────────────────────────────────────────────────

(define OBSERVER_SEED_PRIME 7919)

;; ── Desk configuration ─────────────────────────────────────────────

(struct desk-config
  name                   ; string — "btc-usdc", "eth-usdc"
  source-asset           ; Asset — what we sell on a Buy (e.g. USDC)
  target-asset           ; Asset — what we receive on a Buy (e.g. WBTC)
  dims                   ; vector dimensionality
  recalib-interval       ; journal update count between recalibrations
  window                 ; candle window size for generalist
  decay)                 ; accumulator decay rate

;; ── Desk state ─────────────────────────────────────────────────────
;; Everything the heartbeat needs for ONE pair. The fold step mutates this.

(struct desk
  config                 ; DeskConfig — immutable pair identity

  ;; Observer panel: 5 specialists + 1 generalist
  observers              ; (list Observer) — each has own Journal + WindowSampler

  ;; Manager: reads observer opinions, predicts direction
  manager-journal        ; Journal — learns from price direction
  manager-buy            ; Label — the Buy direction label
  manager-sell           ; Label — the Sell direction label
  manager-resolved       ; (deque (conviction, correct)) — for band scan (cap 5000)
  manager-curve-valid    ; bool — conviction-accuracy curve exists
  ;; WHY: the band is the learned conviction range where this manager has
  ;; statistically proven edge. Only predictions inside the band gate trades.
  manager-proven-band    ; (low, high) — conviction range with proven edge
  prev-manager-thought?  ; Vector — previous candle's manager thought (for delta)

  ;; Exit expert
  exit-journal           ; Journal — learns Hold/Exit from position state
  exit-hold              ; Label — the Hold direction label
  exit-exit              ; Label — the Exit direction label
  exit-pending           ; (list ExitObservation) — buffered for resolution

  ;; Risk
  risk-branches          ; (list RiskBranch) — 5 OnlineSubspace anomaly detectors
  cached-risk-mult       ; f64 — last computed risk multiplier

  ;; Positions: managed allocations from the treasury
  positions              ; (list ManagedPosition)

  ;; Pending: learning queue (ALL candles, not just gated)
  pending                ; (deque Pending)

  ;; Conviction + curve
  conviction-history     ; (deque f64)
  conviction-threshold   ; f64
  resolved-preds         ; (deque (conviction, correct)) — for Kelly curve
  kelly-curve-valid      ; bool
  cached-curve-a         ; f64 — exponential curve parameter
  cached-curve-b         ; f64

  ;; WHY: the panel engram is a reaction-template subspace over the observer
  ;; panel's conviction vector. It learns which configurations of expert
  ;; agreement are normal vs anomalous — the manager's "gut feel" for regime.
  panel-engram           ; OnlineSubspace
  panel-recalib-wins     ; u32 — wins since last panel recalibration
  panel-recalib-total    ; u32 — total since last panel recalibration

  ;; Adaptive decay
  adaptive-decay         ; f64 — current decay rate
  in-adaptation          ; bool
  highconv-wins          ; (deque bool) — recent high-conviction outcomes for adaptive decay

  ;; Accounting
  encode-count           ; usize — candles processed by this desk
  position-swaps         ; usize — position opens + exits
  position-wins          ; usize — profitable exits
  last-exit-price        ; f64
  last-exit-atr          ; f64
  peak-treasury-equity   ; f64 — for drawdown cap
  next-position-id       ; usize

  ;; Logging
  log-step               ; i64
  pending-logs)          ; (list LogEntry)

;; ── Construction ────────────────────────────────────────────────────

(define (new-desk config)
  "Create a desk for one trading pair. All state initialized to empty/default."
  (let* ((dims (:dims config))
         (recalib (:recalib-interval config))
         (lenses '(:momentum :structure :volume :narrative :regime :generalist))
         (observers (map (lambda (lens index)
                           (new-observer lens dims recalib
                                        (+ dims (* index OBSERVER_SEED_PRIME))
                                        '("Buy" "Sell")))
                         lenses
                         (range (len lenses))))
         (manager-journal (journal "manager" dims recalib))
         (manager-labels (register-direction manager-journal))
         (manager-buy (first manager-labels))
         (manager-sell (second manager-labels))
         (exit-journal (journal "exit-expert" dims recalib))
         (exit-labels (register-exit exit-journal))
         (exit-hold (first exit-labels))
         (exit-exit (second exit-labels)))
    (desk
      :config config
      :observers observers
      :manager-journal manager-journal
      :manager-buy manager-buy :manager-sell manager-sell
      :manager-resolved (deque) :manager-curve-valid false
      :manager-proven-band '(0.0 0.0) :prev-manager-thought? #none
      :exit-journal exit-journal
      :exit-hold exit-hold :exit-exit exit-exit
      :exit-pending '()
      :risk-branches (map (lambda (name) (online-subspace dims 8))
                          '("drawdown" "accuracy" "volatility" "correlation" "panel"))
      :cached-risk-mult 0.5
      :positions '() :pending (deque)
      :conviction-history (deque) :conviction-threshold 0.0
      :resolved-preds (deque) :kelly-curve-valid false
      :cached-curve-a 0.0 :cached-curve-b 0.0
      :panel-engram (online-subspace (len lenses) 4)
      :panel-recalib-wins 0 :panel-recalib-total 0
      :adaptive-decay (:decay config) :in-adaptation false
      :highconv-wins (deque)
      :encode-count 0 :position-swaps 0 :position-wins 0
      :last-exit-price 0.0 :last-exit-atr 0.0
      :peak-treasury-equity 0.0 :next-position-id 0
      :log-step 0 :pending-logs '())))

;; ── The desk fold step ─────────────────────────────────────────────
;; This is the heartbeat for ONE pair. The enterprise calls it per desk.
;; The desk reads the candle and produces signals. The treasury is passed
;; in for position management but owned by the enterprise.
;;
;; (desk, candle, treasury, ctx) → (desk, treasury)
;;
;; The desk mutates its own state (observers, journals, positions).
;; The treasury mutates when positions open/close (swap, claim, release).

;; The full fold step is enterprise.wat's on-candle, parameterized by desk.
;; Each step in enterprise.wat (1-13) operates on one desk's state.

;; ── What desks do NOT do ────────────────────────────────────────────
;; - Do NOT own the treasury (shared across desks)
;; - Do NOT own the portfolio (shared phase/equity tracking)
;; - Do NOT know about other desks (signal independence)
;; - Do NOT route capital (treasury decides)
;; - The desk recommends. The treasury executes.
