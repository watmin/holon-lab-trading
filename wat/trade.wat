;; trade.wat — an active position the treasury holds
;;
;; Depends on: newtypes (TradeId), enums (Side, trade-phase),
;;             distances (Levels)
;;
;; Four-phase lifecycle: :active -> :runner -> :settled-*.
;; No :principal-recovered — the transition to :runner implies it.

(require primitives)
(require newtypes)
(require enums)
(require distances)

(struct trade
  [id : TradeId]                  ; assigned by treasury at funding time
  [post-idx : usize]             ; which post
  [broker-slot-idx : usize]      ; which broker (for trigger routing)
  [phase : TradePhase]           ; :active -> :runner -> :settled-*
  [source-asset : Asset]         ; what was deployed
  [target-asset : Asset]         ; what was acquired
  [side : Side]                  ; copied from the funding Proposal
  [entry-rate : f64]
  [entry-atr : f64]              ; from candle.atr at funding time
  [source-amount : f64]          ; how much was deployed
  [stop-levels : Levels]         ; current trailing stop, safety stop, take-profit
                                 ; absolute price levels, updated by step 3c
  [candles-held : usize]         ; how long open
  [price-history : Vec<f64>])    ; close prices from entry to now

;; ── check-triggers ─────────────────────────────────────────────────
;; Check a trade's stop levels against the current price.
;; Returns the new phase if a trigger fired, or None if no trigger.
;; Does NOT mutate — returns the verdict. The treasury applies it.
;;
;; Three trigger paths:
;;   :active + safety-stop hit   -> :settled-violence
;;   :active + take-profit hit   -> :runner (principal returns, residue rides)
;;   :runner + runner-trail hit  -> :settled-grace (residue is permanent gain)

(define (check-triggers [trade : Trade] [current-price : f64])
  : Option<TradePhase>
  (let ((levels (:stop-levels trade))
        (side (:side trade))
        (phase (:phase trade)))
    (match phase
      (:active
        (let ((safety-hit (match side
                            (:buy  (<= current-price (:safety-stop levels)))
                            (:sell (>= current-price (:safety-stop levels)))))
              (tp-hit (match side
                        (:buy  (>= current-price (:take-profit levels)))
                        (:sell (<= current-price (:take-profit levels))))))
          (cond
            (safety-hit (Some :settled-violence))
            (tp-hit     (Some :runner))
            (else       None))))
      (:runner
        (let ((runner-hit (match side
                            (:buy  (<= current-price (:runner-trail-stop levels)))
                            (:sell (>= current-price (:runner-trail-stop levels))))))
          (if runner-hit
            (Some :settled-grace)
            None)))
      ;; settled phases don't trigger
      (:settled-violence None)
      (:settled-grace    None))))

;; ── append-price ───────────────────────────────────────────────────
;; Append the current close price to the trade's price history and
;; increment candles-held. Called each candle for active/runner trades.

(define (append-price [trade : Trade] [close : f64])
  (push! (:price-history trade) close)
  (inc! (:candles-held trade)))
