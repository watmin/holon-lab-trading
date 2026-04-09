;; treasury.wat — Treasury struct + interface
;; Depends on: enums.wat, distances.wat, newtypes.wat, raw-candle.wat,
;;             proposal.wat, trade.wat, settlement.wat, log-entry.wat, trade-origin.wat

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

;; ── Treasury ───────────────────────────────────────────────────────
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
  (treasury denomination initial-balances (map-of)
    '() (map-of) (map-of) 0))

;; ── submit-proposal ────────────────────────────────────────────────

(define (submit-proposal [t : Treasury] [p : Proposal])
  (push! (:proposals t) p))

;; ── available-capital ──────────────────────────────────────────────

(define (available-capital [t : Treasury] [asset : Asset])
  : f64
  (or (get (:available t) asset) 0.0))

;; ── deposit ────────────────────────────────────────────────────────

(define (deposit [t : Treasury] [asset : Asset] [amount : f64])
  (let ((current (available-capital t asset)))
    (set! (:available t) asset (+ current amount))))

;; ── total-equity ───────────────────────────────────────────────────

(define (total-equity [t : Treasury])
  : f64
  (let ((avail-sum (fold (lambda (acc pair) (+ acc (second pair)))
                     0.0 (:available t)))
        (reserved-sum (fold (lambda (acc pair) (+ acc (second pair)))
                        0.0 (:reserved t))))
    (+ avail-sum reserved-sum)))

;; ── fund-proposals ─────────────────────────────────────────────────
;; Sort by edge, fund top N that fit. Reject the rest.

(define (fund-proposals [t : Treasury])
  : Vec<LogEntry>
  (let ((sorted (sort-by (lambda (p) (- (:edge p))) (:proposals t)))
        (logs '()))
    (for-each (lambda (prop)
      (let ((source (:source-asset prop))
            (avail (available-capital t source))
            ;; Size proportional to edge — higher edge, more capital
            (base-fraction 0.05)
            (edge-mult (max (:edge prop) 0.01))
            (alloc-fraction (* base-fraction edge-mult))
            (amount (* avail alloc-fraction)))
        (if (and (> amount 0.01) (> (:edge prop) 0.0))
          ;; Fund
          (let ((trade-id (TradeId (:next-trade-id t)))
                (entry-rate (:close (first '())))  ; price from proposal context
                ;; Use distances to compute initial levels
                (price 0.0)  ; The enterprise provides this
                (stop-levels (distances-to-levels (:distances prop) price (:side prop)))
                (new-trade (make-trade trade-id
                             (:post-idx prop) (:broker-slot-idx prop)
                             (:source-asset prop) (:target-asset prop)
                             (:side prop) price 0.0 amount stop-levels))
                (origin (make-trade-origin (:post-idx prop)
                          (:broker-slot-idx prop)
                          (:composed-thought prop))))
            ;; Move capital: available → reserved
            (set! (:available t) source (- avail amount))
            (let ((res-current (or (get (:reserved t) source) 0.0)))
              (set! (:reserved t) source (+ res-current amount)))
            ;; Register trade
            (set! (:trades t) trade-id new-trade)
            (set! (:trade-origins t) trade-id origin)
            (set! t :next-trade-id (+ (:next-trade-id t) 1))
            (set! logs (append logs
              (list (ProposalFunded trade-id (:broker-slot-idx prop) amount)))))
          ;; Reject
          (let ((reason (if (<= (:edge prop) 0.0) "no-edge" "insufficient-capital")))
            (set! logs (append logs
              (list (ProposalRejected (:broker-slot-idx prop) reason))))))))
      sorted)
    ;; Drain proposals
    (set! t :proposals '())
    logs))

;; ── settle-triggered ───────────────────────────────────────────────
;; Check all active trades against their stop-levels.

(define (settle-triggered [t : Treasury] [current-prices : Map<(Asset, Asset), f64>])
  : (Vec<TreasurySettlement>, Vec<LogEntry>)
  (let ((settlements '())
        (logs '())
        (to-remove '()))
    (for-each (lambda (trade-pair)
      (let (((trade-id trd) trade-pair)
            (price (or (get current-prices
                         (list (:source-asset trd) (:target-asset trd))) 0.0))
            (levels (:stop-levels trd))
            (phase (:phase trd)))
        ;; Append current price to trade history
        (push! (:price-history trd) price)
        (set! trd :candles-held (+ (:candles-held trd) 1))

        (match phase
          (:active
            (cond
              ;; Safety stop hit → settled-violence
              ((match (:side trd)
                 (:buy (<= price (:safety-stop levels)))
                 (:sell (>= price (:safety-stop levels))))
                (set! trd :phase :settled-violence)
                (let ((loss (abs (* (:source-amount trd)
                                   (/ (- price (:entry-rate trd)) (:entry-rate trd)))))
                      (origin (get (:trade-origins t) trade-id)))
                  ;; Return capital minus loss
                  (let ((source (:source-asset trd))
                        (res-current (or (get (:reserved t) source) 0.0))
                        (return-amt (- (:source-amount trd) loss)))
                    (set! (:reserved t) source (- res-current (:source-amount trd)))
                    (deposit t source (max return-amt 0.0)))
                  (set! settlements (append settlements
                    (list (treasury-settlement trd price :violence loss
                            (:composed-thought origin)))))
                  (set! logs (append logs
                    (list (TradeSettled trade-id :violence loss (:candles-held trd)))))
                  (set! to-remove (append to-remove (list trade-id)))))

              ;; Take-profit hit → runner
              ((match (:side trd)
                 (:buy (>= price (:take-profit levels)))
                 (:sell (<= price (:take-profit levels))))
                (set! trd :phase :runner)
                ;; Principal returns to available
                (let ((source (:source-asset trd))
                      (res-current (or (get (:reserved t) source) 0.0)))
                  (set! (:reserved t) source (- res-current (:source-amount trd)))
                  (deposit t source (:source-amount trd))))

              (else nil)))

          (:runner
            ;; Runner trail hit → settled-grace
            (when (match (:side trd)
                    (:buy (<= price (:runner-trail-stop levels)))
                    (:sell (>= price (:runner-trail-stop levels))))
              (set! trd :phase :settled-grace)
              (let ((residue (abs (* (:source-amount trd)
                                    (/ (- price (:entry-rate trd)) (:entry-rate trd)))))
                    (origin (get (:trade-origins t) trade-id)))
                (deposit t (:source-asset trd) residue)
                (set! settlements (append settlements
                  (list (treasury-settlement trd price :grace residue
                          (:composed-thought origin)))))
                (set! logs (append logs
                  (list (TradeSettled trade-id :grace residue (:candles-held trd)))))
                (set! to-remove (append to-remove (list trade-id))))))

          ;; Already settled — skip
          (else nil))))
      (:trades t))

    ;; Remove settled trades
    (for-each (lambda (tid)
      (set! (:trades t) (dissoc (:trades t) tid))
      (set! (:trade-origins t) (dissoc (:trade-origins t) tid)))
      to-remove)

    (list settlements logs)))

;; ── update-trade-stops ─────────────────────────────────────────────

(define (update-trade-stops [t : Treasury] [trade-id : TradeId] [new-levels : Levels])
  (when-let ((trd (get (:trades t) trade-id)))
    (set! trd :stop-levels new-levels)))

;; ── trades-for-post ────────────────────────────────────────────────

(define (trades-for-post [t : Treasury] [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (pair)
    (let (((tid trd) pair))
      (and (= (:post-idx trd) post-idx)
           (or (= (:phase trd) :active)
               (= (:phase trd) :runner)))))
    (:trades t)))
