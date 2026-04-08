; treasury.wat — pure accounting. Capital management.
;
; Depends on: Proposal, Trade, TradePhase, TradeId, TradeOrigin,
;             TreasurySettlement, Asset, Side, Outcome, Levels.
;
; Holds capital. Capital is either available or reserved.
; Receives proposals from posts — the barrage. Accepts or rejects
; based on available capital and the broker's edge.
; Settles trades. Routes outcomes back for accountability.
; The treasury is where the money happens. It does not think. It counts.

(require primitives)
(require enums)             ; TradePhase, Side, Outcome
(require newtypes)          ; TradeId
(require raw-candle)        ; Asset
(require distances)         ; Levels
(require proposal)          ; Proposal
(require trade)             ; Trade, check-triggers, append-price
(require trade-origin)      ; TradeOrigin
(require settlement)        ; TreasurySettlement

;; ---- Struct ----------------------------------------------------------------

(struct treasury
  ;; Capital — the ledger
  [denomination : Asset]               ; what "value" means (e.g. USD)
  [available : Map<Asset, f64>]        ; capital free to deploy
  [reserved : Map<Asset, f64>]         ; capital locked by active trades
  ;; The barrage — proposals received each candle, drained after funding
  [proposals : Vec<Proposal>]          ; cleared every candle
  ;; Active trades — funded proposals become trades
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]
  ;; Counter
  [next-trade-id : usize])             ; monotonic

;; ---- Constructor -----------------------------------------------------------

(define (make-treasury [denomination : Asset]
                       [initial-balances : Map<Asset, f64>])
  : Treasury
  (make-treasury
    denomination
    initial-balances                   ; available
    (map-of)                           ; reserved — empty
    (list)                             ; proposals — empty
    (map-of)                           ; trades — empty
    (map-of)                           ; trade-origins — empty
    0))                                ; next-trade-id

;; ---- submit-proposal -------------------------------------------------------
;; A post submits a proposal for the treasury to evaluate.

(define (submit-proposal [t : Treasury]
                         [proposal : Proposal])
  (push! (:proposals t) proposal))

;; ---- fund-proposals --------------------------------------------------------
;; Evaluate all proposals, sorted by broker funding (the curve's edge measure).
;; Fund the top N that fit in available capital. Reject the rest.
;; For each funded: move capital available -> reserved, create a Trade,
;; stash a TradeOrigin for propagation at settlement time. Drain proposals.

(define (fund-proposals [t : Treasury])
  ;; Sort proposals by funding (edge) descending — best first
  (let* ((sorted (sort-by (lambda (p) (:funding p)) > (:proposals t))))

    (for-each
      (lambda (prop)
        (let* ((asset (:denomination t))
               (avail (get (:available t) asset 0.0))
               ;; Position sizing: funding * available * fraction (capped)
               (max-per-trade (* avail 0.10))          ; cap at 10% of available per trade
               (size (* (:funding prop) max-per-trade)))

          (if (and (> size 0.0)
                   (> (:funding prop) 0.0)
                   (> avail size))
              ;; Fund this proposal
              (let* ((trade-id (TradeId (:next-trade-id t)))
                     ;; Compute initial stop levels from distances + entry rate
                     ;; Entry rate: the current price is implicit from the proposal context.
                     ;; The treasury creates the trade; the post will supply the current price
                     ;; via step 3c on the next candle. Initial levels use proposal distances.
                     ;; The entry rate is communicated via the candle context.
                     (trade (make-trade
                              trade-id
                              (:post-idx prop)
                              (:broker-slot-idx prop)
                              :active
                              (:denomination t)           ; source-asset
                              (:denomination t)           ; target-asset (placeholder)
                              (:side prop)
                              0.0                         ; entry-rate — set by enterprise
                              0.0                         ; entry-atr — set by enterprise
                              size                        ; source-amount
                              (make-levels 0.0 0.0 0.0 0.0)  ; initial levels — set by step 3c
                              0                           ; candles-held
                              (list)))                    ; price-history — empty
                     (origin (make-trade-origin
                               (:post-idx prop)
                               (:broker-slot-idx prop)
                               (:composed-thought prop))))

                ;; Move capital: available -> reserved
                (set! (:available t)
                      (assoc (:available t) asset (- avail size)))
                (set! (:reserved t)
                      (assoc (:reserved t) asset
                             (+ (get (:reserved t) asset 0.0) size)))

                ;; Record the trade
                (set! (:trades t)
                      (assoc (:trades t) trade-id trade))
                (set! (:trade-origins t)
                      (assoc (:trade-origins t) trade-id origin))

                ;; Advance the counter
                (inc! (:next-trade-id t)))

              ;; Reject — insufficient capital or no edge
              (begin))))
      sorted)

    ;; Drain proposals
    (set! (:proposals t) (list))))

;; ---- settle-triggered ------------------------------------------------------
;; Check all active trades, settle what triggered, return treasury-settlements.
;; Move capital from reserved back to available. Add residue.

(define (settle-triggered [t : Treasury]
                          [current-prices : Map<(Asset, Asset), f64>])
  : Vec<TreasurySettlement>
  (let* ((settlements (list))
         (to-remove (list)))

    (for-each
      (lambda (kv)
        (let* ((trade-id (first kv))
               (trade (second kv))
               ;; Get current price for this trade's asset pair
               (price (get current-prices
                           (list (:source-asset trade) (:target-asset trade))
                           0.0))
               ;; Record price in history
               (_ (append-price trade price))
               ;; Check triggers
               (new-phase (check-triggers trade price)))

          ;; Phase transition?
          (when (!= new-phase (:phase trade))
            (set! (:phase trade) new-phase)

            ;; Settle on terminal phases
            (when (or (= new-phase :settled-violence)
                      (= new-phase :settled-grace))
              (let* ((outcome (if (= new-phase :settled-grace)
                                  :grace :violence))
                     (amount (match outcome
                               (:grace
                                 ;; Residue: profit above principal
                                 (let ((exit-val (match (:side trade)
                                                   (:buy  (* (:source-amount trade)
                                                             (/ price (:entry-rate trade))))
                                                   (:sell (* (:source-amount trade)
                                                             (/ (:entry-rate trade) price))))))
                                   (- exit-val (:source-amount trade))))
                               (:violence
                                 ;; Loss: principal minus exit value
                                 (let ((exit-val (match (:side trade)
                                                   (:buy  (* (:source-amount trade)
                                                             (/ price (:entry-rate trade))))
                                                   (:sell (* (:source-amount trade)
                                                             (/ (:entry-rate trade) price))))))
                                   (- (:source-amount trade) exit-val)))))
                     ;; Retrieve the origin
                     (origin (get (:trade-origins t) trade-id))
                     (composed (:composed-thought origin))
                     ;; Build the settlement
                     (ts (make-treasury-settlement trade price outcome amount composed)))

                ;; Move capital back: reserved -> available
                (let* ((asset (:denomination t))
                       (return-amount (match outcome
                                       (:grace  (+ (:source-amount trade) amount))
                                       (:violence (- (:source-amount trade) amount)))))
                  (set! (:reserved t)
                        (assoc (:reserved t) asset
                               (- (get (:reserved t) asset 0.0)
                                  (:source-amount trade))))
                  (set! (:available t)
                        (assoc (:available t) asset
                               (+ (get (:available t) asset 0.0)
                                  return-amount))))

                (push! settlements ts)
                (push! to-remove trade-id))))))
      (:trades t))

    ;; Remove settled trades
    (for-each (lambda (id)
                (set! (:trades t) (dissoc (:trades t) id))
                (set! (:trade-origins t) (dissoc (:trade-origins t) id)))
              to-remove)

    settlements))

;; ---- update-trade-stops ----------------------------------------------------
;; Step 3c: the post computes new levels, the enterprise writes them back.

(define (update-trade-stops [t : Treasury]
                            [trade-id : TradeId]
                            [new-levels : Levels])
  (when-let ((trade (Some (get (:trades t) trade-id))))
    (set! (:stop-levels trade) new-levels)))

;; ---- trades-for-post -------------------------------------------------------
;; Step 3c: the enterprise queries active trades for a given post.

(define (trades-for-post [t : Treasury]
                         [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (kv) (= (:post-idx (second kv)) post-idx))
          (:trades t)))

;; ---- available-capital -----------------------------------------------------

(define (available-capital [t : Treasury]
                           [asset : Asset])
  : f64
  (get (:available t) asset 0.0))

;; ---- deposit ---------------------------------------------------------------

(define (deposit [t : Treasury]
                 [asset : Asset]
                 [amount : f64])
  (set! (:available t)
        (assoc (:available t) asset
               (+ (get (:available t) asset 0.0) amount))))

;; ---- total-equity ----------------------------------------------------------
;; available + reserved, all converted to denomination.

(define (total-equity [t : Treasury])
  : f64
  (+ (fold (lambda (sum kv) (+ sum (second kv))) 0.0 (:available t))
     (fold (lambda (sum kv) (+ sum (second kv))) 0.0 (:reserved t))))

;; ---- drain-logs ------------------------------------------------------------
;; The treasury produces log entries during fund and settle.
;; The enterprise drains them at the candle boundary.
;; (Currently, log-entry production is inline in fund-proposals and
;; settle-triggered. The drain is part of the enterprise's drain-logs.)
