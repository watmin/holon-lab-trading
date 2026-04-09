;; treasury.wat — pure accounting, capital management
;;
;; Depends on: enums (Outcome, Side), newtypes (TradeId),
;;             distances (Levels), proposal, trade, trade-origin,
;;             settlement, log-entry
;;
;; Holds capital. Available or reserved. Receives proposals from posts.
;; Settles trades. Three trigger paths:
;;   :active + safety-stop   -> :settled-violence
;;   :active + take-profit   -> :runner (principal returns, residue rides)
;;   :runner + runner-trail   -> :settled-grace (residue is permanent gain)

(require primitives)
(require enums)
(require newtypes)
(require distances)
(require proposal)
(require trade)
(require trade-origin)
(require settlement)
(require log-entry)

(struct treasury
  ;; Capital — the ledger
  [denomination : Asset]                  ; what "value" means
  [available : Map<Asset, f64>]           ; capital free to deploy
  [reserved : Map<Asset, f64>]            ; capital locked by active trades
  ;; The barrage — proposals received each candle
  [proposals : Vec<Proposal>]             ; cleared every candle
  ;; Active trades
  [trades : Map<TradeId, Trade>]
  [trade-origins : Map<TradeId, TradeOrigin>]
  ;; Counter
  [next-trade-id : usize])               ; monotonic

;; ── Constructor ────────────────────────────────────────────────────

(define (make-treasury [denomination : Asset]
                       [initial-balances : Map<Asset, f64>])
  : Treasury
  (treasury
    denomination
    initial-balances                       ; available
    (map-of)                               ; reserved — empty
    '()                                    ; proposals — empty
    (map-of)                               ; trades — empty
    (map-of)                               ; trade-origins — empty
    0))                                    ; next-trade-id

;; ── submit-proposal ────────────────────────────────────────────────

(define (submit-proposal [tsy : Treasury] [prop : Proposal])
  (push! (:proposals tsy) prop))

;; ── fund-proposals ─────────────────────────────────────────────────
;; Evaluate all proposals, sorted by edge (descending).
;; Fund the top N that fit in available capital. Reject the rest.
;; Returns ProposalFunded and ProposalRejected log entries.
;; Drains proposals.

(define (fund-proposals [tsy : Treasury])
  : Vec<LogEntry>
  (let* ((sorted (sort-by (lambda (p) (- (:edge p)))
                          (:proposals tsy)))
         (logs
           (fold-left
             (lambda (acc prop)
               (let ((source (:source-asset (nth (:posts-ref tsy) (:post-idx prop))))
                     (avail (available-capital tsy source)))
                 ;; Fund if there is available capital and edge > 0.5
                 (if (and (> avail 0.0) (> (:edge prop) 0.5))
                   ;; Fund this proposal
                   (let* ((amount (min avail (* avail (:edge prop))))
                          (trade-id (TradeId (:next-trade-id tsy)))
                          (_ (inc! (:next-trade-id tsy)))
                          ;; Move capital: available -> reserved
                          (_ (set! (:available tsy)
                                   (assoc (:available tsy) source
                                          (- (get (:available tsy) source) amount))))
                          (_ (set! (:reserved tsy)
                                   (assoc (:reserved tsy) source
                                          (+ (get (:reserved tsy) source 0.0) amount))))
                          ;; Create the trade
                          (candle-price 0.0)  ; the post's current price will be set by enterprise
                          (new-trade (trade
                                       trade-id
                                       (:post-idx prop)
                                       (:broker-slot-idx prop)
                                       :active
                                       source
                                       source         ; target-asset placeholder
                                       (:side prop)
                                       0.0            ; entry-rate set by enterprise
                                       0.0            ; entry-atr set by enterprise
                                       amount
                                       (levels 0.0 0.0 0.0 0.0)  ; initial levels set by enterprise
                                       0              ; candles-held
                                       '()))          ; price-history
                          (_ (set! (:trades tsy)
                                   (assoc (:trades tsy) trade-id new-trade)))
                          ;; Stash trade origin
                          (_ (set! (:trade-origins tsy)
                                   (assoc (:trade-origins tsy) trade-id
                                          (trade-origin (:post-idx prop)
                                                        (:broker-slot-idx prop)
                                                        (:composed-thought prop))))))
                     (cons (ProposalFunded trade-id (:broker-slot-idx prop) amount)
                           acc))
                   ;; Reject
                   (cons (ProposalRejected (:broker-slot-idx prop) "insufficient capital or edge")
                         acc))))
             '()
             sorted)))
    ;; Drain proposals
    (set! (:proposals tsy) '())
    (reverse logs)))

;; ── settle-triggered ───────────────────────────────────────────────
;; Check all active trades against their stop-levels, settle what triggered.
;; Returns: (Vec<TreasurySettlement>, Vec<LogEntry>)
;; Three trigger paths:
;;   :active + safety-stop hit   -> :settled-violence
;;   :active + take-profit hit   -> :runner
;;   :runner + runner-trail hit  -> :settled-grace

(define (settle-triggered [tsy : Treasury] [current-prices : Map<(Asset, Asset), f64>])
  : (Vec<TreasurySettlement>, Vec<LogEntry>)
  (let ((settlements '())
        (logs '()))
    (for-each
      (lambda (entry)
        (let* ((trade-id (first entry))
               (trd (second entry))
               (pair-key (list (:source-asset trd) (:target-asset trd)))
               (price (get current-prices pair-key))
               (trigger (check-triggers trd price)))
          (match trigger
            (None
              ;; No trigger — append price and tick
              (append-price trd price))
            ((Some new-phase)
              (match new-phase
                ;; Active -> settled-violence: stop-loss fired
                (:settled-violence
                  (let* ((loss (abs (- price (:entry-rate trd))))
                         (amount (* (:source-amount trd)
                                    (/ loss (:entry-rate trd))))
                         (origin (get (:trade-origins tsy) trade-id))
                         (ts (treasury-settlement trd price :violence amount
                                                  (:composed-thought origin))))
                    (set! (:phase trd) :settled-violence)
                    ;; Return capital minus loss
                    (let ((source (:source-asset trd)))
                      (set! (:reserved tsy)
                            (assoc (:reserved tsy) source
                                   (- (get (:reserved tsy) source) (:source-amount trd))))
                      (set! (:available tsy)
                            (assoc (:available tsy) source
                                   (+ (get (:available tsy) source)
                                      (- (:source-amount trd) amount)))))
                    (push! settlements ts)
                    (push! logs (TradeSettled trade-id :violence amount
                                             (:candles-held trd)))))

                ;; Active -> runner: take-profit hit, principal returns
                (:runner
                  (let ((source (:source-asset trd)))
                    (set! (:phase trd) :runner)
                    ;; Principal returns to available
                    (set! (:reserved tsy)
                          (assoc (:reserved tsy) source
                                 (- (get (:reserved tsy) source) (:source-amount trd))))
                    (set! (:available tsy)
                          (assoc (:available tsy) source
                                 (+ (get (:available tsy) source)
                                    (:source-amount trd))))))

                ;; Runner -> settled-grace: runner trail fired
                (:settled-grace
                  (let* ((gain (abs (- price (:entry-rate trd))))
                         (amount (* (:source-amount trd)
                                    (/ gain (:entry-rate trd))))
                         (origin (get (:trade-origins tsy) trade-id))
                         (ts (treasury-settlement trd price :grace amount
                                                  (:composed-thought origin))))
                    (set! (:phase trd) :settled-grace)
                    ;; Residue returns to available
                    (let ((source (:source-asset trd)))
                      (set! (:available tsy)
                            (assoc (:available tsy) source
                                   (+ (get (:available tsy) source) amount))))
                    (push! settlements ts)
                    (push! logs (TradeSettled trade-id :grace amount
                                             (:candles-held trd)))))

                ;; Other phases don't trigger
                (else None))))))
      (:trades tsy))
    ;; Remove settled trades
    (for-each
      (lambda (s)
        (let ((tid (:id (:trade s))))
          (set! (:trades tsy) (dissoc (:trades tsy) tid))
          (set! (:trade-origins tsy) (dissoc (:trade-origins tsy) tid))))
      settlements)
    (list settlements logs)))

;; ── available-capital ──────────────────────────────────────────────

(define (available-capital [tsy : Treasury] [asset : Asset])
  : f64
  (get (:available tsy) asset 0.0))

;; ── deposit ────────────────────────────────────────────────────────

(define (deposit [tsy : Treasury] [asset : Asset] [amount : f64])
  (set! (:available tsy)
        (assoc (:available tsy) asset
               (+ (get (:available tsy) asset 0.0) amount))))

;; ── total-equity ───────────────────────────────────────────────────

(define (total-equity [tsy : Treasury])
  : f64
  (+ (fold-left (lambda (acc entry) (+ acc (second entry)))
                0.0
                (:available tsy))
     (fold-left (lambda (acc entry) (+ acc (second entry)))
                0.0
                (:reserved tsy))))

;; ── update-trade-stops ─────────────────────────────────────────────

(define (update-trade-stops [tsy : Treasury]
                            [trade-id : TradeId]
                            [new-levels : Levels])
  (when-let ((trd (get (:trades tsy) trade-id)))
    (set! (:stop-levels trd) new-levels)))

;; ── trades-for-post ────────────────────────────────────────────────
;; Active trades for a given post.

(define (trades-for-post [tsy : Treasury] [post-idx : usize])
  : Vec<(TradeId, Trade)>
  (filter (lambda (entry)
            (let ((trd (second entry)))
              (and (= (:post-idx trd) post-idx)
                   (or (= (:phase trd) :active)
                       (= (:phase trd) :runner)))))
          (:trades tsy)))
