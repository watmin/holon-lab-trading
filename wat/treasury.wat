;; treasury.wat — Treasury struct + interface
;; Depends on: enums, distances, newtypes, raw-candle (Asset),
;;             proposal, trade, settlement, trade-origin, log-entry

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

;; ── Treasury — pure accounting ────────────────────────────────────────
;; Holds capital. Capital is either available or reserved.
(struct treasury
  [denomination : Asset]
  [available : Map<Asset, f64>]
  [reserved : Map<Asset, f64>]
  [proposals : Vec<Proposal>]
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]
  [next-trade-id : usize])

(define (make-treasury [denomination : Asset]
                       [initial-balances : Map<Asset, f64>])
  : Treasury
  (treasury
    denomination
    initial-balances
    (map-of)           ; reserved — empty
    '()                ; proposals — empty
    (map-of)           ; trades — empty
    (map-of)           ; trade-origins — empty
    0))                ; next-trade-id

;; ── available-capital ─────────────────────────────────────────────────
(define (available-capital [t : Treasury]
                          [asset : Asset])
  : f64
  (match (get (:available t) asset)
    ((Some val) val)
    (None 0.0)))

;; ── deposit ───────────────────────────────────────────────────────────
(define (deposit [t : Treasury]
                 [asset : Asset]
                 [amount : f64])
  (let ((current (available-capital t asset)))
    (set! t :available (assoc (:available t) asset (+ current amount)))))

;; ── total-equity — available + reserved, all converted to denomination
(define (total-equity [t : Treasury])
  : f64
  (let ((avail-sum (fold + 0.0 (map second (keys (:available t)))))
        (reserved-sum (fold + 0.0 (map second (keys (:reserved t))))))
    ;; Simplified: assume all values in denomination already.
    ;; Full version would convert via exchange rates.
    (+ avail-sum reserved-sum)))

;; ── submit-proposal ───────────────────────────────────────────────────
(define (submit-proposal [t : Treasury]
                         [prop : Proposal])
  (push! t :proposals prop))

;; ── fund-proposals — evaluate, sort by edge, fund top N ───────────────
;; Returns: Vec<LogEntry>
(define (fund-proposals [t : Treasury])
  : Vec<LogEntry>
  (let ((sorted (sort-by (lambda (p) (- 0.0 (:edge p))) (:proposals t)))
        (log-entries '()))
    (for-each (lambda (prop)
      (let ((source (:source-asset prop))
            (avail (available-capital t source))
            ;; Position sizing: fraction of available based on edge
            ;; More edge → more capital. Minimum 1% of available.
            (edge-frac (max 0.01 (:edge prop)))
            (position-size (* avail edge-frac))
            (min-position 10.0))  ; minimum trade size
        (if (and (> position-size min-position) (> avail position-size))
          ;; Fund it
          (let ((trade-id (TradeId (:next-trade-id t)))
                (entry-price 0.0) ; will be set from current price
                (side (:side prop))
                (init-levels (distances-to-levels (:distances prop) entry-price side))
                (new-trade (trade
                             trade-id
                             (:post-idx prop)
                             (:broker-slot-idx prop)
                             :active
                             source
                             (:target-asset prop)
                             side
                             entry-price
                             position-size
                             init-levels
                             0      ; candles-held
                             '()))  ; price-history — empty
                ;; Stash origin for propagation at settlement time
                ;; prediction from the broker at funding time
                (origin (trade-origin
                          (:post-idx prop)
                          (:broker-slot-idx prop)
                          (:composed-thought prop)
                          ;; The broker's prediction — reconstruct from propose
                          ;; In practice the enterprise threads this through
                          (Discrete '() 0.0))))
            ;; Move capital: available → reserved
            (set! t :available (assoc (:available t) source (- avail position-size)))
            (let ((curr-reserved (match (get (:reserved t) source)
                                   ((Some v) v) (None 0.0))))
              (set! t :reserved (assoc (:reserved t) source (+ curr-reserved position-size))))
            ;; Store trade and origin
            (set! t :trades (assoc (:trades t) trade-id new-trade))
            (set! t :trade-origins (assoc (:trade-origins t) trade-id origin))
            (inc! t :next-trade-id)
            (push! log-entries (ProposalFunded trade-id (:broker-slot-idx prop) position-size)))
          ;; Reject it
          (push! log-entries (ProposalRejected (:broker-slot-idx prop) "insufficient capital")))))
      sorted)
    ;; Drain proposals
    (set! t :proposals '())
    log-entries))

;; ── check-trigger — does the current price trigger any stop? ──────────
(define (check-trade-triggers [trade : Trade]
                              [current-price : f64])
  : (Option<TradePhase>, f64)
  ;; Returns new phase and exit price if triggered, None otherwise
  (let ((levels (:stop-levels trade))
        (side (:side trade))
        (phase (:phase trade)))
    (match phase
      (:active
        (match side
          (:buy
            (cond
              ;; Safety stop — price dropped below
              ((<= current-price (:safety-stop levels))
                (list (Some :settled-violence) current-price))
              ;; Take profit — price rose above
              ((>= current-price (:take-profit levels))
                (list (Some :runner) current-price))
              ;; Trail stop — price dropped below trailing
              ((<= current-price (:trail-stop levels))
                (list (Some :settled-violence) current-price))
              (else (list None 0.0))))
          (:sell
            (cond
              ;; Safety stop — price rose above
              ((>= current-price (:safety-stop levels))
                (list (Some :settled-violence) current-price))
              ;; Take profit — price dropped below
              ((<= current-price (:take-profit levels))
                (list (Some :runner) current-price))
              ;; Trail stop — price rose above trailing
              ((>= current-price (:trail-stop levels))
                (list (Some :settled-violence) current-price))
              (else (list None 0.0))))))
      (:runner
        (match side
          (:buy
            (if (<= current-price (:runner-trail-stop levels))
              (list (Some :settled-grace) current-price)
              (list None 0.0)))
          (:sell
            (if (>= current-price (:runner-trail-stop levels))
              (list (Some :settled-grace) current-price)
              (list None 0.0)))))
      ;; Already settled
      (_ (list None 0.0)))))

;; ── settle-triggered — settle trades that hit their stops ─────────────
;; Returns: (Vec<TreasurySettlement>, Vec<LogEntry>)
(define (settle-triggered [t : Treasury]
                          [current-prices : Map<(Asset, Asset), f64>])
  : (Vec<TreasurySettlement>, Vec<LogEntry>)
  (let ((settlements '())
        (log-entries '())
        (trades-to-remove '()))
    (for-each (lambda (trade-pair)
      (let (((trade-id trade) trade-pair)
            (pair-key (list (:source-asset trade) (:target-asset trade)))
            (current-price (match (get current-prices pair-key)
                             ((Some p) p) (None 0.0))))
        ;; Append price to history
        (push! trade :price-history current-price)
        (inc! trade :candles-held)
        ;; Check triggers
        (let (((maybe-phase exit-price) (check-trade-triggers trade current-price)))
          (match maybe-phase
            ((Some new-phase)
              (match new-phase
                (:settled-violence
                  ;; Stop-loss fired. Principal minus loss returns to available.
                  (let ((loss (abs (- exit-price (:entry-rate trade))))
                        (loss-frac (if (= (:entry-rate trade) 0.0) 0.0
                                     (/ loss (:entry-rate trade))))
                        (loss-amount (* (:source-amount trade) loss-frac))
                        (return-amount (- (:source-amount trade) loss-amount))
                        (source (:source-asset trade))
                        ;; Get composed thought from origin
                        (origin (match (get (:trade-origins t) trade-id)
                                  ((Some o) o)
                                  (None (trade-origin 0 0 (zeros) (Discrete '() 0.0)))))
                        (composed (:composed-thought origin)))
                    ;; Return capital
                    (let ((curr-avail (available-capital t source))
                          (curr-reserved (match (get (:reserved t) source)
                                           ((Some v) v) (None 0.0))))
                      (set! t :available (assoc (:available t) source (+ curr-avail return-amount)))
                      (set! t :reserved (assoc (:reserved t) source (- curr-reserved (:source-amount trade)))))
                    (set! trade :phase :settled-violence)
                    (push! settlements (treasury-settlement trade exit-price :violence loss-amount composed))
                    (push! log-entries (TradeSettled trade-id :violence loss-amount (:candles-held trade)))
                    (push! trades-to-remove trade-id)))
                (:runner
                  ;; Take-profit hit. Principal returns. Residue rides.
                  (let ((source (:source-asset trade))
                        (principal (:source-amount trade)))
                    ;; Return principal to available
                    (let ((curr-avail (available-capital t source))
                          (curr-reserved (match (get (:reserved t) source)
                                           ((Some v) v) (None 0.0))))
                      (set! t :available (assoc (:available t) source (+ curr-avail principal)))
                      (set! t :reserved (assoc (:reserved t) source (- curr-reserved principal))))
                    ;; Trade transitions to runner phase
                    (set! trade :phase :runner)))
                (:settled-grace
                  ;; Runner trail fired. Residue is permanent gain.
                  (let ((residue (abs (- exit-price (:entry-rate trade))))
                        (residue-frac (if (= (:entry-rate trade) 0.0) 0.0
                                        (/ residue (:entry-rate trade))))
                        (residue-amount (* (:source-amount trade) residue-frac))
                        (source (:source-asset trade))
                        (origin (match (get (:trade-origins t) trade-id)
                                  ((Some o) o)
                                  (None (trade-origin 0 0 (zeros) (Discrete '() 0.0)))))
                        (composed (:composed-thought origin)))
                    ;; Residue returns to available
                    (deposit t source residue-amount)
                    (set! trade :phase :settled-grace)
                    (push! settlements (treasury-settlement trade exit-price :grace residue-amount composed))
                    (push! log-entries (TradeSettled trade-id :grace residue-amount (:candles-held trade)))
                    (push! trades-to-remove trade-id)))
                (_ (begin))))
            (None (begin))))))
      (:trades t))
    ;; Remove settled trades
    (for-each (lambda (tid)
      (set! t :trades (dissoc (:trades t) tid)))
      trades-to-remove)
    (list settlements log-entries)))

;; ── update-trade-stops — write new levels to a trade ──────────────────
(define (update-trade-stops [t : Treasury]
                            [trade-id : TradeId]
                            [new-levels : Levels])
  (match (get (:trades t) trade-id)
    ((Some trade)
      (set! trade :stop-levels new-levels))
    (None (begin))))

;; ── trades-for-post — active trades belonging to a given post ─────────
(define (trades-for-post [t : Treasury]
                         [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (pair) (= (:post-idx (second pair)) post-idx))
          (:trades t)))
