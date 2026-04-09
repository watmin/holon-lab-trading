;; treasury.wat — Treasury struct + interface
;; Depends on: enums, distances, newtypes, raw-candle (Asset), proposal, trade, settlement, log-entry, trade-origin

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
  ;; Proposals — cleared every candle
  [proposals : Vec<Proposal>]
  ;; Active trades
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]
  ;; Counter
  [next-trade-id : usize])

(define (make-treasury [denomination : Asset] [initial-balances : Map<Asset, f64>])
  : Treasury
  (treasury denomination initial-balances (map-of)
           '() (map-of) (map-of) 0))

;; Submit a proposal for the treasury to evaluate.
(define (submit-proposal [t : Treasury] [proposal : Proposal])
  (push! (:proposals t) proposal))

;; Available capital for a given asset.
(define (available-capital [t : Treasury] [asset : Asset])
  : f64
  (match (get (:available t) (:name asset))
    ((Some v) v)
    (None 0.0)))

;; Deposit into available capital.
(define (deposit [t : Treasury] [asset : Asset] [amount : f64])
  (let ((current (available-capital t asset)))
    (set! (:available t) (:name asset) (+ current amount))))

;; Total equity: available + reserved, all in denomination.
(define (total-equity [t : Treasury])
  : f64
  (let ((avail-sum (fold (lambda (acc pair) (+ acc (second pair))) 0.0 (keys (:available t))))
        (resv-sum (fold (lambda (acc pair) (+ acc (second pair))) 0.0 (keys (:reserved t)))))
    (+ avail-sum resv-sum)))

;; Fund proposals. Sort by edge, fund top N that fit. Reject the rest.
(define (fund-proposals [t : Treasury])
  : Vec<LogEntry>
  (let ((sorted (sort-by (lambda (p) (- 0.0 (:edge p))) (:proposals t)))
        (logs '()))
    (for-each (lambda (proposal)
      (let ((source (:source-asset proposal))
            (avail (available-capital t source))
            ;; Fund a fraction proportional to edge (minimum 1% of available)
            (fraction (max (:edge proposal) 0.01))
            (amount (* avail fraction)))
        (if (and (> amount 0.0) (> avail 0.0) (> (:edge proposal) 0.0))
          ;; Fund
          (let ((trade-id (TradeId (:next-trade-id t)))
                (entry-rate (/ amount 1.0))  ; placeholder — actual rate from market
                (entry-atr 0.0)              ; from the candle at funding time
                (levels (distances-to-levels (:distances proposal)
                          entry-rate (:side proposal)))
                (new-trade (make-trade trade-id
                             (:post-idx proposal) (:broker-slot-idx proposal)
                             (:source-asset proposal) (:target-asset proposal)
                             (:side proposal) entry-rate entry-atr amount levels)))
            ;; Move capital: available → reserved
            (set! (:available t) (:name source) (- avail amount))
            (let ((res-current (match (get (:reserved t) (:name source))
                                 ((Some v) v) (None 0.0))))
              (set! (:reserved t) (:name source) (+ res-current amount)))
            ;; Store trade and origin
            (set! (:trades t) trade-id new-trade)
            (set! (:trade-origins t) trade-id
                  (make-trade-origin (:post-idx proposal)
                                     (:broker-slot-idx proposal)
                                     (:composed-thought proposal)))
            (inc! t :next-trade-id)
            (push! logs (ProposalFunded trade-id (:broker-slot-idx proposal) amount)))
          ;; Reject
          (push! logs (ProposalRejected (:broker-slot-idx proposal)
                        (if (<= (:edge proposal) 0.0) "no-edge" "no-capital"))))))
      sorted)
    ;; Drain proposals
    (set! t :proposals '())
    logs))

;; Settle triggered trades. Check stops against current prices.
;; Returns (Vec<TreasurySettlement>, Vec<LogEntry>).
(define (settle-triggered [t : Treasury] [current-prices : Map<(Asset, Asset), f64>])
  : (Vec<TreasurySettlement>, Vec<LogEntry>)
  (let ((settlements '())
        (logs '())
        (to-remove '()))
    (for-each (lambda (trade-pair)
      (let (((trade-id trade) trade-pair)
            (price (match (get current-prices
                           (list (:source-asset trade) (:target-asset trade)))
                     ((Some p) p)
                     (None (:entry-rate trade))))
            (levels (:stop-levels trade))
            (origin (get (:trade-origins t) trade-id)))

        ;; Append price to trade history
        (push! (:price-history trade) price)
        (inc! trade :candles-held)

        (match (:phase trade)
          (:active
            (cond
              ;; Safety stop hit
              ((or (and (= (:side trade) :buy) (<= price (:safety-stop levels)))
                   (and (= (:side trade) :sell) (>= price (:safety-stop levels))))
                (set! trade :phase :settled-violence)
                (let ((loss (abs (- price (:entry-rate trade))))
                      (amount (* (:source-amount trade)
                                (/ loss (max (:entry-rate trade) 0.01)))))
                  ;; Return principal minus loss to available
                  (let ((return-amount (- (:source-amount trade) amount)))
                    (deposit t (:source-asset trade) (max return-amount 0.0)))
                  ;; Release reserved
                  (let ((res-key (:name (:source-asset trade)))
                        (res-current (match (get (:reserved t) res-key)
                                       ((Some v) v) (None 0.0))))
                    (set! (:reserved t) res-key
                          (max 0.0 (- res-current (:source-amount trade)))))
                  ;; Settlement
                  (let ((composed (match origin
                                    ((Some o) (:composed-thought o))
                                    (None (zeros)))))
                    (push! settlements
                      (treasury-settlement trade price :violence amount composed))
                    (push! logs
                      (TradeSettled trade-id :violence amount (:candles-held trade))))
                  (push! to-remove trade-id)))

              ;; Take-profit hit → transition to runner
              ((or (and (= (:side trade) :buy) (>= price (:take-profit levels)))
                   (and (= (:side trade) :sell) (<= price (:take-profit levels))))
                (set! trade :phase :runner)
                ;; Principal returns to available
                (deposit t (:source-asset trade) (:source-amount trade))
                ;; Release reserved
                (let ((res-key (:name (:source-asset trade)))
                      (res-current (match (get (:reserved t) res-key)
                                     ((Some v) v) (None 0.0))))
                  (set! (:reserved t) res-key
                        (max 0.0 (- res-current (:source-amount trade))))))

              ;; Trailing stop hit
              ((or (and (= (:side trade) :buy) (<= price (:trail-stop levels)))
                   (and (= (:side trade) :sell) (>= price (:trail-stop levels))))
                (set! trade :phase :settled-violence)
                (let ((loss (abs (- price (:entry-rate trade))))
                      (amount (* (:source-amount trade)
                                (/ loss (max (:entry-rate trade) 0.01)))))
                  (let ((return-amount (- (:source-amount trade) amount)))
                    (deposit t (:source-asset trade) (max return-amount 0.0)))
                  (let ((res-key (:name (:source-asset trade)))
                        (res-current (match (get (:reserved t) res-key)
                                       ((Some v) v) (None 0.0))))
                    (set! (:reserved t) res-key
                          (max 0.0 (- res-current (:source-amount trade)))))
                  (let ((composed (match origin
                                    ((Some o) (:composed-thought o))
                                    (None (zeros)))))
                    (push! settlements
                      (treasury-settlement trade price :violence amount composed))
                    (push! logs
                      (TradeSettled trade-id :violence amount (:candles-held trade))))
                  (push! to-remove trade-id)))

              (else (begin))))  ; no trigger

          (:runner
            ;; Runner trailing stop hit → settled grace
            (when (or (and (= (:side trade) :buy) (<= price (:runner-trail-stop levels)))
                      (and (= (:side trade) :sell) (>= price (:runner-trail-stop levels))))
              (set! trade :phase :settled-grace)
              (let ((residue (abs (- price (:entry-rate trade))))
                    (amount (* (:source-amount trade)
                              (/ residue (max (:entry-rate trade) 0.01)))))
                ;; Residue returns to available — permanent gain
                (deposit t (:source-asset trade) amount)
                (let ((composed (match origin
                                  ((Some o) (:composed-thought o))
                                  (None (zeros)))))
                  (push! settlements
                    (treasury-settlement trade price :grace amount composed))
                  (push! logs
                    (TradeSettled trade-id :grace amount (:candles-held trade))))
                (push! to-remove trade-id))))

          (:settled-violence (begin))
          (:settled-grace (begin)))))
      (:trades t))

    ;; Remove settled trades
    (for-each (lambda (id) (dissoc (:trades t) id) (dissoc (:trade-origins t) id))
              to-remove)

    (list settlements logs)))

;; Update stop levels for an active trade.
(define (update-trade-stops [t : Treasury] [trade-id : TradeId] [new-levels : Levels])
  (when-let ((trade (get (:trades t) trade-id)))
    (set! trade :stop-levels new-levels)))

;; Get active trades for a given post.
(define (trades-for-post [t : Treasury] [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (pair)
    (= (:post-idx (second pair)) post-idx))
    (:trades t)))
