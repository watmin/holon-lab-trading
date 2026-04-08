; trade.wat — an active position the treasury holds.
;
; Depends on: TradeId, TradePhase, Side, Asset, Levels.
;
; Created when the treasury funds a Proposal. Lives until settlement.
; The phase is a state machine — FOUR variants:
;   active -> settled-violence (stop-loss fired)
;   active -> runner (take-profit hit: principal returns AND residue rides)
;   runner -> settled-grace (runner trail fired, residue is permanent gain)
; No :principal-recovered phase — Active + tp -> Runner directly.
; price-history records every close from entry to now.

(require primitives)
(require enums)         ; TradePhase, Side
(require newtypes)      ; TradeId
(require raw-candle)    ; Asset
(require distances)     ; Levels

;; ---- Struct ----------------------------------------------------------------

(struct trade
  [id : TradeId]               ; assigned by treasury at funding time
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker (for trigger routing)
  [phase : TradePhase]         ; :active -> :runner -> :settled-*
  [source-asset : Asset]       ; what was deployed (e.g. USDC)
  [target-asset : Asset]       ; what was acquired (e.g. WBTC)
  [side : Side]                ; copied from the funding Proposal
  [entry-rate : f64]
  [entry-atr : f64]            ; from candle.atr at funding time
  [source-amount : f64]        ; how much was deployed
  [stop-levels : Levels]       ; current trailing stop, safety stop, take-profit
                               ; absolute price levels, updated by step 3c
  [candles-held : usize]       ; how long open
  [price-history : Vec<f64>])  ; close prices from entry to now

;; ---- check-triggers --------------------------------------------------------
;; Given the current price, determine whether any stop has been hit.
;; Returns the new phase. The treasury uses this to settle.
;; FOUR phases: :active, :runner, :settled-violence, :settled-grace.
;; Active + tp -> Runner directly (principal recovery implied).

(define (check-triggers [t : Trade]
                        [current-price : f64])
  : TradePhase
  (match (:phase t)
    ;; Active: check safety-stop, trailing stop, take-profit
    (:active
      (cond
        ;; Safety stop hit -> violence
        ((match (:side t)
           (:buy  (<= current-price (:safety-stop (:stop-levels t))))
           (:sell (>= current-price (:safety-stop (:stop-levels t)))))
         :settled-violence)
        ;; Trailing stop hit -> violence
        ((match (:side t)
           (:buy  (<= current-price (:trail-stop (:stop-levels t))))
           (:sell (>= current-price (:trail-stop (:stop-levels t)))))
         :settled-violence)
        ;; Take profit hit -> runner (principal returns AND residue rides)
        ((match (:side t)
           (:buy  (>= current-price (:take-profit (:stop-levels t))))
           (:sell (<= current-price (:take-profit (:stop-levels t)))))
         :runner)
        ;; Nothing triggered
        (else :active)))

    ;; Runner: only the runner trailing stop applies
    (:runner
      (if (match (:side t)
            (:buy  (<= current-price (:runner-trail-stop (:stop-levels t))))
            (:sell (>= current-price (:runner-trail-stop (:stop-levels t)))))
          :settled-grace
          :runner))

    ;; Already settled — no change
    (:settled-violence :settled-violence)
    (:settled-grace :settled-grace)))

;; ---- append-price ----------------------------------------------------------

(define (append-price [t : Trade]
                      [price : f64])
  (push! (:price-history t) price)
  (inc! (:candles-held t)))
