; trade.wat — an active position the treasury holds.
;
; Depends on: TradeId, TradePhase, Side, Asset, Levels.
;
; Created when the treasury funds a Proposal. Lives until settlement.
; The phase is a state machine: active -> settled-violence,
; active -> principal-recovered -> runner -> settled-grace.
; price-history records every close from entry to now — the trade
; closes over its own history. Pure replay data for optimal-distances.

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
  [phase : TradePhase]         ; :active, :principal-recovered, :runner, or :settled-*
  [source-asset : Asset]       ; what was deployed (e.g. USDC)
  [target-asset : Asset]       ; what was acquired (e.g. WBTC)
  [side : Side]                ; copied from the funding Proposal
  [entry-rate : f64]
  [entry-atr : f64]            ; from candle.atr at funding time
  [source-amount : f64]        ; how much was deployed
  [stop-levels : Levels]       ; current trailing stop, safety stop, take-profit
                               ; absolute price levels, updated by step 3c
  [candles-held : usize]       ; how long open
  [price-history : Vec<f64>])  ; close prices from entry to now. Appended each candle.

;; ---- check-triggers --------------------------------------------------------
;; Given the current price, determine whether any stop has been hit.
;; Returns the new phase. The treasury uses this to settle.

(define (check-triggers [t : Trade]
                        [current-price : f64])
  : TradePhase
  (match (:phase t)
    ;; Active: check safety-stop, take-profit, and trailing stop
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
        ;; Take profit hit -> principal recovered
        ((match (:side t)
           (:buy  (>= current-price (:take-profit (:stop-levels t))))
           (:sell (<= current-price (:take-profit (:stop-levels t)))))
         :principal-recovered)
        ;; Nothing triggered
        (true :active)))

    ;; Principal recovered transitions to runner
    (:principal-recovered :runner)

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
;; Record the current close in the trade's price history.

(define (append-price [t : Trade]
                      [price : f64])
  (push! (:price-history t) price)
  (inc! (:candles-held t)))
