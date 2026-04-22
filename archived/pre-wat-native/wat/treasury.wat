;; ── treasury.wat ────────────────────────────────────────────────────
;;
;; Pure accounting. Holds capital — available vs reserved. Funds
;; proposals, settles trades, routes outcomes. The treasury counts.
;; It decides based on capital availability and proof curves.
;; Depends on: enums, newtypes, distances, proposal, trade,
;;   trade-origin, settlement, log-entry.

(require enums)
(require newtypes)
(require distances)
(require proposal)
(require trade)
(require trade-origin)
(require settlement)
(require log-entry)

;; ── Struct ──────────────────────────────────────────────────────

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

  ;; Venue costs — configuration applied at settlement
  [swap-fee : f64]                     ; per-swap venue cost as fraction
  [slippage : f64]                     ; per-swap slippage estimate

  ;; Counter
  [next-trade-id : usize])             ; monotonic

;; ── Constructor ─────────────────────────────────────────────────

(define (make-treasury [denomination : Asset]
                       [initial-balances : Map<Asset, f64>]
                       [swap-fee : f64]
                       [slippage : f64])
  : Treasury
  (make-treasury denomination initial-balances (map-of)
    (list) (map-of) (map-of)
    swap-fee slippage
    0))

;; ── submit-proposal ─────────────────────────────────────────────
;; A post submits a proposal for the treasury to evaluate.

(define (submit-proposal [treasury : Treasury] [proposal : Proposal])
  : ()
  (push! (:proposals treasury) proposal))

;; ── fund-proposals ──────────────────────────────────────────────
;; Evaluate all proposals, sorted by edge. Fund the top N that fit
;; in available capital. Reject the rest. Drain proposals.

(define (fund-proposals [treasury : Treasury])
  : Vec<LogEntry>
  (let* ((venue-cost-rate (* 2.0 (+ (:swap-fee treasury) (:slippage treasury))))
         ;; Sort proposals by edge, descending
         (sorted (sort-by (lambda (p) (- (:edge p))) (:proposals treasury)))
         ;; Fund or reject each proposal
         (logs
           (fold-left
             (lambda (logs proposal)
               (let ((source (:source-asset proposal))
                     (amount (available-capital treasury source)))
                 (cond
                   ;; Edge does not exceed venue cost rate — negative expected value
                   ((< (:edge proposal) venue-cost-rate)
                     (append logs
                       (list (ProposalRejected (:broker-slot-idx proposal)
                               "edge below venue cost"))))
                   ;; No capital available
                   ((<= amount 0.0)
                     (append logs
                       (list (ProposalRejected (:broker-slot-idx proposal)
                               "insufficient capital"))))
                   ;; Fund the proposal
                   (else
                     (let* ((reserve-amount (+ amount (* amount venue-cost-rate)))
                            ;; Clamp to available
                            (actual-reserve (min reserve-amount
                                              (available-capital treasury source)))
                            (trade-amount (/ actual-reserve (+ 1.0 venue-cost-rate)))
                            ;; Create trade
                            (trade-id (TradeId (:next-trade-id treasury)))
                            (_ (inc! (:next-trade-id treasury)))
                            (entry-price 0.0) ; set by the enterprise from current price
                            (initial-levels (distances-to-levels
                                              (:distances proposal)
                                              entry-price
                                              (:side proposal)))
                            (new-trade (make-trade trade-id
                                         (:post-idx proposal) (:broker-slot-idx proposal)
                                         (:side proposal)
                                         (:source-asset proposal) (:target-asset proposal)
                                         entry-price trade-amount initial-levels
                                         :active 0 (list)))
                            ;; Stash origin for propagation
                            (origin (make-trade-origin
                                      (:post-idx proposal)
                                      (:broker-slot-idx proposal)
                                      (:composed-thought proposal)
                                      (:prediction proposal)))
                            ;; Move capital: available → reserved
                            (_ (set! (:available treasury) source
                                 (- (get (:available treasury) source) trade-amount)))
                            (_ (set! (:reserved treasury) source
                                 (+ (or (get (:reserved treasury) source) 0.0) trade-amount)))
                            ;; Register trade and origin
                            (_ (set! (:trades treasury) trade-id new-trade))
                            (_ (set! (:trade-origins treasury) trade-id origin)))
                       (append logs
                         (list (ProposalFunded trade-id (:broker-slot-idx proposal)
                                 trade-amount))))))))
             (list)
             sorted)))
    ;; Drain proposals
    (set! (:proposals treasury) (list))
    logs))

;; ── settle-triggered ────────────────────────────────────────────
;; Check all active trades against their stop-levels. Settle what
;; triggered. Two paths: safety-stop fires, trailing-stop fires.

(define (settle-triggered [treasury : Treasury]
                          [current-prices : Map<(Asset, Asset), f64>])
  : (Vec<TreasurySettlement>, Vec<LogEntry>)
  (let* ((venue-cost-per-swap (+ (:swap-fee treasury) (:slippage treasury)))
         (results
           (filter-map
             (lambda (entry)
               (let* (((trade-id trade) entry)
                      (price (get current-prices
                               (list (:source-asset trade) (:target-asset trade))))
                      (origin (get (:trade-origins treasury) trade-id)))
                 (cond
                   ;; Safety stop fired — :settled-violence
                   ((and (= (:phase trade) :active)
                         (match (:side trade)
                           (:buy  (<= price (:safety-stop (:stop-levels trade))))
                           (:sell (>= price (:safety-stop (:stop-levels trade))))))
                     (let* ((exit-value (* (:amount trade)
                                           (- 1.0 venue-cost-per-swap)))
                            (loss (- (:amount trade) exit-value))
                            ;; Return remaining to available
                            (_ (set! (:available treasury) (:source-asset trade)
                                 (+ (available-capital treasury (:source-asset trade))
                                    exit-value)))
                            (_ (set! (:reserved treasury) (:source-asset trade)
                                 (- (get (:reserved treasury) (:source-asset trade))
                                    (:amount trade))))
                            (_ (dissoc (:trades treasury) trade-id))
                            (_ (dissoc (:trade-origins treasury) trade-id))
                            (settlement (make-treasury-settlement
                                          (update trade :phase :settled-violence)
                                          price :violence loss
                                          (:composed-thought origin)
                                          (:prediction origin))))
                       (Some (list settlement
                               (TradeSettled trade-id :violence loss
                                 (:candles-held trade) (:prediction origin))))))

                   ;; Trailing stop fired — outcome depends on exit vs principal
                   ((and (member? (:phase trade) (list :active :runner))
                         (match (:side trade)
                           (:buy  (<= price (:trail-stop (:stop-levels trade))))
                           (:sell (>= price (:trail-stop (:stop-levels trade))))))
                     (let* ((exit-value (* (:amount trade)
                                           (/ price (:entry-price trade))
                                           (- 1.0 venue-cost-per-swap)))
                            (outcome (if (> exit-value (:amount trade)) :grace :violence))
                            (residue (- exit-value (:amount trade)))
                            ;; Principal returns to available
                            (_ (set! (:available treasury) (:source-asset trade)
                                 (+ (available-capital treasury (:source-asset trade))
                                    (min exit-value (:amount trade)))))
                            (_ (set! (:reserved treasury) (:source-asset trade)
                                 (- (get (:reserved treasury) (:source-asset trade))
                                    (:amount trade))))
                            (_ (dissoc (:trades treasury) trade-id))
                            (_ (dissoc (:trade-origins treasury) trade-id))
                            (settlement (make-treasury-settlement
                                          (update trade :phase
                                            (if (= outcome :grace) :settled-grace :settled-violence))
                                          price outcome (abs residue)
                                          (:composed-thought origin)
                                          (:prediction origin))))
                       (Some (list settlement
                               (TradeSettled trade-id outcome (abs residue)
                                 (:candles-held trade) (:prediction origin))))))

                   ;; No trigger
                   (else None))))
             (:trades treasury)))
         (settlements (map first results))
         (logs (map second results)))
    (list settlements logs)))

;; ── update-trade-stops ──────────────────────────────────────────
;; Step 3c: update stop levels on an active trade. Also handles the
;; runner transition — when the trailing stop has moved past break-even,
;; the trade transitions from :active to :runner.

(define (update-trade-stops [treasury : Treasury]
                            [trade-id : TradeId]
                            [new-levels : Levels])
  : ()
  (when-let ((trade (get (:trades treasury) trade-id)))
    (let* ((updated (update trade :stop-levels new-levels))
           ;; Check runner transition: would the trail-stop recover principal?
           (would-recover
             (match (:side trade)
               (:buy  (> (:trail-stop new-levels) (:entry-price trade)))
               (:sell (< (:trail-stop new-levels) (:entry-price trade)))))
           (final (if (and (= (:phase updated) :active) would-recover)
                    (update updated :phase :runner)
                    updated)))
      (set! (:trades treasury) trade-id final))))

;; ── available-capital ───────────────────────────────────────────

(define (available-capital [treasury : Treasury] [asset : Asset])
  : f64
  (or (get (:available treasury) asset) 0.0))

;; ── deposit ─────────────────────────────────────────────────────

(define (deposit [treasury : Treasury] [asset : Asset] [amount : f64])
  : ()
  (set! (:available treasury) asset
    (+ (available-capital treasury asset) amount)))

;; ── total-equity ────────────────────────────────────────────────
;; Available + reserved, all converted to denomination.

(define (total-equity [treasury : Treasury])
  : f64
  (+ (fold-left + 0.0 (map second (keys (:available treasury))))
     (fold-left + 0.0 (map second (keys (:reserved treasury))))))

;; ── trades-for-post ─────────────────────────────────────────────
;; Step 3c: active trades belonging to a given post.

(define (trades-for-post [treasury : Treasury] [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (entry)
            (let (((trade-id trade) entry))
              (and (= (:post-idx trade) post-idx)
                   (member? (:phase trade) (list :active :runner)))))
          (:trades treasury)))
