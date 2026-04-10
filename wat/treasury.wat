;; treasury.wat — Treasury struct + interface
;; Depends on: proposal, trade, settlement, enums, distances, newtypes, log-entry, trade-origin, raw-candle

(require primitives)
(require enums)
(require distances)
(require newtypes)
(require raw-candle)
(require proposal)
(require trade)
(require settlement)
(require log-entry)
(require trade-origin)

(struct treasury
  ;; Capital
  [denomination : Asset]
  [available : Map<Asset, f64>]
  [reserved : Map<Asset, f64>]
  ;; Proposals
  [proposals : Vec<Proposal>]
  ;; Active trades
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]
  ;; Venue costs
  [swap-fee : f64]
  [slippage : f64]
  ;; Counter
  [next-trade-id : usize])

(define (make-treasury [denomination : Asset]
                       [initial-balances : Map<Asset, f64>]
                       [swap-fee : f64]
                       [slippage : f64])
  : Treasury
  (treasury denomination initial-balances (map-of) '()
    (map-of) (map-of) swap-fee slippage 0))

;; Available capital for a given asset
(define (available-capital [t : Treasury] [asset : Asset])
  : f64
  (let ((bal (get (:available t) asset)))
    (if (= bal None) 0.0 bal)))

;; Deposit: add to available
(define (deposit [t : Treasury] [asset : Asset] [amount : f64])
  : Treasury
  (let ((current (available-capital t asset)))
    (update t :available (assoc (:available t) asset (+ current amount)))))

;; Total equity: available + reserved, all converted to denomination
;; Simplified: sum all values (assumes denomination-based accounting)
(define (total-equity [t : Treasury])
  : f64
  (let ((avail-sum (fold (lambda (s pair) (+ s (second pair))) 0.0
                     (map (lambda (k) (list k (get (:available t) k)))
                          (keys (:available t)))))
        (reserved-sum (fold (lambda (s pair) (+ s (second pair))) 0.0
                        (map (lambda (k) (list k (get (:reserved t) k)))
                             (keys (:reserved t))))))
    (+ avail-sum reserved-sum)))

;; Submit a proposal for evaluation
(define (submit-proposal [t : Treasury] [prop : Proposal])
  : Treasury
  (update t :proposals (append (:proposals t) (list prop))))

;; Venue cost per swap
(define (venue-cost-rate [t : Treasury])
  : f64
  (+ (:swap-fee t) (:slippage t)))

;; Fund proposals: evaluate, sort by edge, fund what fits
(define (fund-proposals [t : Treasury])
  : (Treasury Vec<LogEntry>)
  (let ((sorted (sort-by (lambda (p) (- 0.0 (:edge p))) (:proposals t)))
        (cost-rate (venue-cost-rate t)))
    (let ((result
            (fold (lambda (state prop)
                    (let (((treas logs) state)
                          (source (:source-asset prop))
                          (avail (available-capital treas source))
                          ;; Compute amount to deploy — fraction of available
                          ;; based on edge. More edge, more capital.
                          (edge-fraction (max 0.01 (:edge prop)))
                          (amount (* avail edge-fraction 0.1))  ; conservative
                          ;; Total venue cost for round trip (2 swaps)
                          (total-cost (* cost-rate amount 2.0))
                          ;; Minimum viable trade
                          (min-trade 1.0))
                      (cond
                        ;; Not enough edge to cover venue costs
                        ((< (:edge prop) (* cost-rate 2.0))
                          (list treas
                            (append logs (list (ProposalRejected
                              (:broker-slot-idx prop) "edge below venue cost")))))
                        ;; Not enough capital
                        ((< avail min-trade)
                          (list treas
                            (append logs (list (ProposalRejected
                              (:broker-slot-idx prop) "insufficient capital")))))
                        ;; Fund the trade
                        (else
                          (let ((trade-id (TradeId (:next-trade-id treas)))
                                ;; Convert distances to levels
                                ;; Need a reference price — use the proposal's entry context
                                ;; The treasury doesn't have the price directly, so it
                                ;; stores the levels computed at funding time
                                (reserve-amount (+ amount total-cost))
                                ;; Move capital: available → reserved
                                (new-avail (assoc (:available treas) source
                                             (- avail reserve-amount)))
                                (new-reserved (assoc (:reserved treas) source
                                                (+ (let ((r (get (:reserved treas) source)))
                                                     (if (= r None) 0.0 r))
                                                   reserve-amount)))
                                ;; Create trade (levels will be set by the post)
                                (new-trade (make-trade trade-id
                                             (:post-idx prop) (:broker-slot-idx prop)
                                             (:side prop) (:source-asset prop)
                                             (:target-asset prop)
                                             0.0   ; entry-rate set by the enterprise
                                             amount
                                             (make-levels 0.0 0.0 0.0 0.0)))
                                ;; Stash origin
                                (origin (make-trade-origin (:post-idx prop)
                                          (:broker-slot-idx prop)
                                          (:composed-thought prop)
                                          (Discrete '() 0.0)))  ; placeholder prediction
                                ;; Log
                                (log (ProposalFunded trade-id (:broker-slot-idx prop) reserve-amount)))
                            (list (update treas
                                    :available new-avail
                                    :reserved new-reserved
                                    :trades (assoc (:trades treas) trade-id new-trade)
                                    :trade-origins (assoc (:trade-origins treas) trade-id origin)
                                    :next-trade-id (+ (:next-trade-id treas) 1))
                                  (append logs (list log))))))))
                  (list t '())
                  sorted)))
      ;; Drain proposals
      (let (((final-treas final-logs) result))
        (list (update final-treas :proposals '()) final-logs)))))

;; Settle triggered trades against current prices
(define (settle-triggered [t : Treasury]
                          [current-prices : Map<(Asset, Asset), f64>])
  : (Treasury Vec<TreasurySettlement> Vec<LogEntry>)
  (let ((cost-rate (venue-cost-rate t)))
    (fold (lambda (state trade-pair)
            (let (((treas settlements logs) state)
                  ((tid trade) trade-pair)
                  (price (get current-prices
                           (list (:source-asset trade) (:target-asset trade))))
                  (lvls (:stop-levels trade))
                  (s (:side trade)))
              ;; Check if any stop fired
              (let ((trail-fired (match s
                                   (:buy (<= price (:trail-stop lvls)))
                                   (:sell (>= price (:trail-stop lvls)))))
                    (safety-fired (match s
                                    (:buy (<= price (:safety-stop lvls)))
                                    (:sell (>= price (:safety-stop lvls)))))
                    (tp-fired (match s
                                (:buy (>= price (:take-profit lvls)))
                                (:sell (<= price (:take-profit lvls)))))
                    (runner-trail-fired
                      (and (= (:phase trade) :runner)
                           (match s
                             (:buy (<= price (:runner-trail-stop lvls)))
                             (:sell (>= price (:runner-trail-stop lvls)))))))
                (cond
                  ;; Safety stop fires — violence
                  (safety-fired
                    (let ((exit-value (* (:source-amount trade)
                                        (- 1.0 cost-rate)))  ; one swap back
                          (loss (- (:source-amount trade) exit-value))
                          (origin (get (:trade-origins treas) tid))
                          (settled-trade (update trade :phase :settled-violence))
                          (stl (treasury-settlement settled-trade price :violence
                                 loss (:composed-thought origin) (:prediction origin)))
                          (log (TradeSettled tid :violence loss (:candles-held trade)
                                 (:prediction origin)))
                          ;; Return remaining to available
                          (src (:source-asset trade))
                          (reserved-amt (let ((r (get (:reserved treas) src)))
                                          (if (= r None) 0.0 r)))
                          (new-reserved (assoc (:reserved treas) src
                                          (- reserved-amt (:source-amount trade))))
                          (avail-amt (available-capital treas src))
                          (new-avail (assoc (:available treas) src
                                      (+ avail-amt exit-value))))
                      (list (update treas
                              :available new-avail :reserved new-reserved
                              :trades (dissoc (:trades treas) tid))
                            (append settlements (list stl))
                            (append logs (list log)))))

                  ;; Trail or TP or runner-trail fires — check grace vs violence
                  ((or trail-fired tp-fired runner-trail-fired)
                    (let ((entry (:entry-rate trade))
                          ;; Compute exit value ratio
                          (exit-ratio (match s
                                        (:buy (/ price entry))
                                        (:sell (/ entry price))))
                          (exit-value (* (:source-amount trade) exit-ratio
                                        (- 1.0 cost-rate)))
                          (principal (:source-amount trade))
                          (is-grace (> exit-value principal))
                          (outcome-val (if is-grace :grace :violence))
                          (residue (if is-grace (- exit-value principal) 0.0))
                          (loss-val (if is-grace 0.0 (- principal exit-value)))
                          (amount-val (if is-grace residue loss-val))
                          (origin (get (:trade-origins treas) tid))
                          (settled-trade (update trade :phase
                                          (if is-grace :settled-grace :settled-violence)))
                          (stl (treasury-settlement settled-trade price outcome-val
                                 amount-val (:composed-thought origin)
                                 (:prediction origin)))
                          (log (TradeSettled tid outcome-val amount-val
                                 (:candles-held trade) (:prediction origin)))
                          ;; Return principal to available, residue stays as target
                          (src (:source-asset trade))
                          (reserved-amt (let ((r (get (:reserved treas) src)))
                                          (if (= r None) 0.0 r)))
                          (new-reserved (assoc (:reserved treas) src
                                          (- reserved-amt (:source-amount trade))))
                          (avail-amt (available-capital treas src))
                          (new-avail (assoc (:available treas) src
                                      (+ avail-amt principal))))
                      (list (update treas
                              :available new-avail :reserved new-reserved
                              :trades (dissoc (:trades treas) tid))
                            (append settlements (list stl))
                            (append logs (list log)))))

                  ;; Check runner transition: has the stop moved past break-even?
                  ((and (= (:phase trade) :active)
                        (match s
                          (:buy (> (:trail-stop lvls) (:entry-rate trade)))
                          (:sell (< (:trail-stop lvls) (:entry-rate trade)))))
                    ;; Transition to runner — widen the trailing stop
                    (let ((runner-trade (update trade :phase :runner)))
                      (list (update treas
                              :trades (assoc (:trades treas) tid runner-trade))
                            settlements logs)))

                  ;; No trigger — tick the trade
                  (else
                    (let ((ticked (trade-tick trade price)))
                      (list (update treas
                              :trades (assoc (:trades treas) tid ticked))
                            settlements logs)))))))
          (list t '() '())
          (map (lambda (k) (list k (get (:trades t) k))) (keys (:trades t))))))

;; Update stop levels on a trade
(define (update-trade-stops [t : Treasury] [tid : TradeId] [new-levels : Levels])
  : Treasury
  (let ((trade (get (:trades t) tid)))
    (if (= trade None) t
      (update t :trades (assoc (:trades t) tid
                          (update trade :stop-levels new-levels))))))

;; Get active trades for a given post
(define (trades-for-post [t : Treasury] [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (pair)
            (let (((tid trade) pair))
              (and (= (:post-idx trade) post-idx)
                   (or (= (:phase trade) :active)
                       (= (:phase trade) :runner)))))
          (map (lambda (k) (list k (get (:trades t) k))) (keys (:trades t)))))
