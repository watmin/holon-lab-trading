;; -- state.wat -- immutable context and pure accounting structs --------------
;;
;; CandleContext: the immutable world the heartbeat reads.
;; TradePnl: pure accounting result for a resolved trade.
;; ExitAtoms: immutable atom vectors for the exit expert encoding.
;;
;; EnterpriseState is already specified in enterprise.wat.

(require core/structural)
(require core/primitives)

;; -- TradePnl ---------------------------------------------------------------

;; Pure accounting result. No side effects.
;; Computed once, consumed by treasury settlement and ledger logging.

(struct trade-pnl
  gross-ret              ; f64 -- directional return before costs
  net-ret                ; f64 -- return after both entry and exit costs
  entry-cost-frac        ; f64 -- per-swap cost (swap-fee + slippage)
  exit-cost-frac         ; f64 -- gross-value * per-swap cost
  pos-usd                ; f64 -- deployed USD (0.0 if not live)
  trade-pnl)             ; f64 -- pos-usd * net-ret

(define (compute-trade-pnl trade-pct is-buy swap-fee slippage is-live deployed-usd treasury-equity frac)
  "Compute P&L for a resolved entry. Pure arithmetic."
  (let ((gross-ret (if is-buy trade-pct (- trade-pct)))
        (per-swap (+ swap-fee slippage))
        (after-entry (- 1.0 per-swap))
        (gross-value (* after-entry (+ 1.0 gross-ret)))
        (after-exit (* gross-value (- 1.0 per-swap)))
        (net-ret (- after-exit 1.0))
        (pos-usd (if is-live
                     (if (> deployed-usd 0.0) deployed-usd (* treasury-equity frac))
                     0.0)))
    (trade-pnl
      :gross-ret gross-ret :net-ret net-ret
      :entry-cost-frac per-swap :exit-cost-frac (* gross-value per-swap)
      :pos-usd pos-usd :trade-pnl (* pos-usd net-ret))))

;; Two-sided fee model:
;;   Entry: deploy * (1 - entry_cost) = actual position
;;   Exit:  position * (1 + return) * (1 - exit_cost) = received

;; -- ExitAtoms --------------------------------------------------------------

;; rune:scry(aspirational) -- exit.wat specifies the exit expert modulates
;; k_trail per position per candle. Code only buffers ExitObservation and
;; learns labels but never reads the exit expert's prediction to adjust
;; trailing stops. The exit expert learns but does not yet act.

(struct exit-atoms
  pnl                    ; Vector -- atom for current P&L
  hold                   ; Vector -- atom for hold duration
  mfe                    ; Vector -- atom for max favorable excursion
  atr-entry              ; Vector -- atom for ATR at entry
  atr-now                ; Vector -- atom for current ATR
  stop-dist              ; Vector -- atom for distance to trailing stop
  phase                  ; Vector -- atom for position phase
  direction              ; Vector -- atom for trade direction
  ;; Filler atoms (pre-warmed, not created in hot path)
  runner active          ; position phase fillers
  buy sell)              ; direction fillers

;; -- CandleContext ----------------------------------------------------------

;; Immutable references needed by on_candle but owned by main().
;; Bundles config, atoms, encoders, and the ledger.
;; 40+ fields — every function takes this but reads 2-5.
;; The Rust will split into EncodingConfig × TradingConfig × DisplayConfig
;; when the fold is refactored. The wat specifies the target shape.

(enum conviction-mode :quantile :auto)
(enum sizing-mode :legacy :kelly)
(enum asset-mode :round-trip :hold)

(struct candle-context
  ;; CLI args
  dims window horizon move-threshold atr-multiplier decay
  observe-period recalib-interval min-conviction conviction-quantile
  conviction-mode min-edge sizing-mode max-drawdown
  swap-fee slippage asset-mode base-asset quote-asset initial-equity
  diagnostics

  ;; Exit parameters
  k-stop k-trail k-tp exit-horizon exit-observe-interval rolling-cap

  ;; Config constants
  decay-stable decay-adapting highconv-rolling-cap
  max-single-position conviction-warmup conviction-window

  ;; Immutable encoding infrastructure
  vm mgr-atoms mgr-scalar exit-scalar exit-atoms risk-scalar

  ;; Observer/manager atoms
  observer-atoms observer-names generalist-atom min-opinion-magnitude

  ;; Codebook for discriminant decode
  codebook-labels codebook-vecs

  ;; Progress display
  bnh-entry loop-count progress-every t-start)

;; -- What state does NOT do -------------------------------------------------
;; - Does NOT mutate (CandleContext is immutable, TradePnl is a value)
;; - Does NOT decide anything (pure data and pure arithmetic)
;; - Does NOT own the fold (that's EnterpriseState in enterprise.wat)
;; - Context is the world. TradePnl is a receipt. ExitAtoms are vocabulary.
