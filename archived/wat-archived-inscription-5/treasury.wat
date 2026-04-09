;; treasury.wat — Treasury struct + interface
;; Depends on: enums (Outcome, TradePhase, Side), distances (Levels, Distances),
;;             proposal (Proposal), trade (Trade), settlement (TreasurySettlement),
;;             trade-origin (TradeOrigin), log-entry (LogEntry), newtypes (TradeId),
;;             raw-candle (Asset)
;; Holds capital. Capital is either available or reserved.

(require primitives)
(require enums)
(require distances)
(require newtypes)
(require raw-candle)
(require proposal)
(require trade)
(require settlement)
(require trade-origin)
(require log-entry)

(struct treasury
  ;; Capital — the ledger
  [denomination : Asset]               ; what "value" means (e.g. USD)
  [available : Map<Asset, f64>]        ; capital free to deploy
  [reserved : Map<Asset, f64>]         ; capital locked by active trades
  ;; The barrage
  [proposals : Vec<Proposal>]          ; cleared every candle
  ;; Active trades
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]
  ;; Counter
  [next-trade-id : usize])             ; monotonic

(define (make-treasury [denomination : Asset] [initial-balances : Map<Asset, f64>])
  : Treasury
  (treasury denomination initial-balances (map-of) '()
           (map-of) (map-of) 0))

;; Available capital for a given asset.
(define (available-capital [t : Treasury] [asset : Asset])
  : f64
  (get (:available t) asset 0.0))

;; Deposit capital.
(define (deposit [t : Treasury] [asset : Asset] [amount : f64])
  (set! (:available t) asset
    (+ (get (:available t) asset 0.0) amount)))

;; Total equity — available + reserved, in denomination.
;; Simplified: sum all available and reserved values.
(define (total-equity [t : Treasury])
  : f64
  (+ (fold + 0.0 (map (lambda (k) (get (:available t) k 0.0)) (keys (:available t))))
     (fold + 0.0 (map (lambda (k) (get (:reserved t) k 0.0)) (keys (:reserved t))))))

;; Submit a proposal for evaluation.
(define (submit-proposal [t : Treasury] [prop : Proposal])
  (push! (:proposals t) prop))

;; Fund proposals — sort by edge, fund top N that fit.
;; Returns: Vec<LogEntry>
(define (fund-proposals [t : Treasury])
  : Vec<LogEntry>
  (let ((logs '())
        ;; Sort proposals by edge, descending
        (sorted (sort-by (lambda (p) (- (:edge p))) (:proposals t))))
    (for-each (lambda (prop)
      (let ((source (:source-asset prop))
            (avail  (available-capital t source))
            ;; Position sizing: proportional to edge.
            ;; Base size = 10% of available. Scale by edge.
            (base-size (* avail 0.10))
            (sized    (* base-size (max 0.01 (:edge prop)))))
        (if (and (> sized 0.01) (> avail sized))
          ;; Fund
          (let ((trade-id (TradeId (:next-trade-id t)))
                (entry-rate (match (:prediction prop)
                              ;; Use a placeholder — actual rate comes from market
                              ((Discrete _ _) 0.0)
                              ((Continuous v _) v)))
                ;; Create the trade
                (new-trade (make-trade
                  trade-id
                  (:post-idx prop) (:broker-slot-idx prop)
                  (:source-asset prop) (:target-asset prop)
                  (:side prop)
                  0.0    ; entry-rate — set by the market
                  0.0    ; entry-atr — set by the market
                  sized
                  (distances-to-levels (:distances prop) 0.0 (:side prop)))))
            ;; Move capital: available → reserved
            (set! (:available t) source (- avail sized))
            (set! (:reserved t) source
              (+ (get (:reserved t) source 0.0) sized))
            ;; Store trade and origin
            (set! (:trades t) trade-id new-trade)
            (set! (:trade-origins t) trade-id
              (make-trade-origin (:post-idx prop) (:broker-slot-idx prop)
                                 (:composed-thought prop)))
            (inc! (:next-trade-id t))
            (push! logs (ProposalFunded trade-id (:broker-slot-idx prop) sized)))
          ;; Reject
          (push! logs (ProposalRejected (:broker-slot-idx prop)
                        (if (<= avail 0.01) "insufficient capital" "size too small"))))))
      sorted)
    ;; Drain proposals
    (set! (:proposals t) '())
    logs))

;; Settle triggered trades against current prices.
;; Returns: (Vec<TreasurySettlement>, Vec<LogEntry>)
(define (settle-triggered [t : Treasury] [current-prices : Map<(Asset, Asset), f64>])
  : (Vec<TreasurySettlement>, Vec<LogEntry>)
  (let ((settlements '())
        (logs '())
        (to-remove '()))
    (for-each (lambda (trade-id)
      (let ((tr (get (:trades t) trade-id))
            (price (get current-prices
                     (list (:source-asset tr) (:target-asset tr)) 0.0))
            (lvls (:stop-levels tr)))
        ;; Tick the trade
        (trade-tick tr price)
        ;; Check triggers based on phase
        (match (:phase tr)
          (:active
            (cond
              ;; Safety stop hit — violence
              ((match (:side tr)
                 (:buy  (<= price (:safety-stop lvls)))
                 (:sell (>= price (:safety-stop lvls))))
                (set! (:phase tr) :settled-violence)
                (let ((loss (abs (- (:source-amount tr)
                                    (* (:source-amount tr)
                                       (if (match (:side tr) (:buy true) (:sell false))
                                         (/ price (:entry-rate tr))
                                         (/ (:entry-rate tr) price))))))
                      (origin (get (:trade-origins t) trade-id)))
                  ;; Return capital minus loss
                  (let ((return-amount (max 0.0 (- (:source-amount tr) loss))))
                    (deposit t (:source-asset tr) return-amount)
                    (set! (:reserved t) (:source-asset tr)
                      (max 0.0 (- (get (:reserved t) (:source-asset tr) 0.0)
                                  (:source-amount tr)))))
                  (push! settlements
                    (make-treasury-settlement tr price :violence loss
                      (:composed-thought origin)))
                  (push! logs (TradeSettled trade-id :violence loss (:candles-held tr)))
                  (push! to-remove trade-id)))

              ;; Take-profit hit — transition to runner
              ((match (:side tr)
                 (:buy  (>= price (:take-profit lvls)))
                 (:sell (<= price (:take-profit lvls))))
                ;; Principal returns to available. Residue continues.
                (set! (:phase tr) :runner)
                (let ((source (:source-asset tr)))
                  (deposit t source (:source-amount tr))
                  (set! (:reserved t) source
                    (max 0.0 (- (get (:reserved t) source 0.0)
                                (:source-amount tr))))))

              (else 'noop)))

          (:runner
            ;; Runner trail hit — grace
            (when (match (:side tr)
                    (:buy  (<= price (:runner-trail-stop lvls)))
                    (:sell (>= price (:runner-trail-stop lvls))))
              (set! (:phase tr) :settled-grace)
              (let ((residue (abs (* (:source-amount tr)
                                     (- (if (match (:side tr) (:buy true) (:sell false))
                                           (/ price (:entry-rate tr))
                                           (/ (:entry-rate tr) price))
                                        1.0))))
                    (origin (get (:trade-origins t) trade-id)))
                ;; Residue is permanent gain
                (deposit t (:source-asset tr) residue)
                (push! settlements
                  (make-treasury-settlement tr price :grace residue
                    (:composed-thought origin)))
                (push! logs (TradeSettled trade-id :grace residue (:candles-held tr)))
                (push! to-remove trade-id))))

          ;; Settled phases — already done
          (:settled-violence 'noop)
          (:settled-grace 'noop))))
      (keys (:trades t)))

    ;; Remove settled trades
    (for-each (lambda (tid)
      (set! (:trades t) (dissoc (:trades t) tid))
      (set! (:trade-origins t) (dissoc (:trade-origins t) tid)))
      to-remove)

    (list settlements logs)))

;; Update trade stop levels.
(define (update-trade-stops [t : Treasury] [trade-id : TradeId] [new-levels : Levels])
  (when-let ((tr (get (:trades t) trade-id)))
    (set! (:stop-levels tr) new-levels)))

;; Active trades for a given post.
(define (trades-for-post [t : Treasury] [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter-map (lambda (tid)
    (let ((tr (get (:trades t) tid)))
      (if (and (= (:post-idx tr) post-idx)
               (or (match (:phase tr) (:active true) (else false))
                   (match (:phase tr) (:runner true) (else false))))
        (Some (list tid tr))
        None)))
    (keys (:trades t))))
