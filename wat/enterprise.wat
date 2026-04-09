;; enterprise.wat — Enterprise struct + interface + four-step loop
;; Depends on: post, treasury, simulation, settlement, ctx

(require primitives)
(require enums)
(require raw-candle)
(require distances)
(require post)
(require treasury)
(require simulation)
(require settlement)
(require log-entry)
(require ctx)

;; ── Enterprise ─────────────────────────────────────────────────────
;; The coordination plane. The CSP sync point.

(struct enterprise
  [posts : Vec<Post>]
  [treasury : Treasury]
  [market-thoughts-cache : Vec<Vec<Vector>>])

(define (make-enterprise [posts : Vec<Post>] [treasury : Treasury])
  : Enterprise
  (let ((cache (map (lambda (p) '()) posts)))
    (enterprise posts treasury cache)))

;; ── Step 1: RESOLVE + PROPAGATE ────────────────────────────────────
;; Settle triggered trades, propagate outcomes to observers.

(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  ;; Collect current prices from each post
  (let ((current-prices (map-of)))
    (for-each (lambda (p)
      (let ((price (current-price p))
            (key (list (:source-asset p) (:target-asset p))))
        (set! current-prices key price)))
      (:posts ent))

    ;; Treasury settles triggered trades
    (let (((treasury-settlements settle-logs)
           (settle-triggered (:treasury ent) current-prices))
          (propagate-logs '()))

      ;; For each settlement, enrich and propagate
      (for-each (lambda (ts)
        (let ((trd (:trade ts))
              (price-history (:price-history trd))
              (direction (derive-direction (:exit-price ts) (:entry-rate trd)))
              ;; Compute optimal distances via simulation
              (optimal (compute-optimal-distances price-history direction))
              ;; Build full settlement
              (sett (make-settlement ts optimal))
              ;; Route to the right post
              (post-idx (:post-idx trd))
              (p (nth (:posts ent) post-idx))
              ;; Propagate
              (plogs (post-propagate p
                       (:broker-slot-idx trd)
                       (:composed-thought ts)
                       (:outcome ts)
                       (:amount ts)
                       direction
                       optimal)))
          (set! propagate-logs (append propagate-logs plogs))))
        treasury-settlements)

      (append settle-logs propagate-logs))))

;; ── Step 2: COMPUTE + DISPATCH ─────────────────────────────────────

(define (step-compute-dispatch [ent : Enterprise]
                               [post-idx : usize]
                               [raw-candle : RawCandle]
                               [c : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let ((p (nth (:posts ent) post-idx)))
    (post-on-candle p raw-candle c)))

;; ── Step 3a: TICK ──────────────────────────────────────────────────

(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((p (nth (:posts ent) post-idx))
        (price (current-price p))
        ;; Parallel tick all brokers' papers
        (results (pmap (lambda (broker)
                   (tick-papers broker price))
                   (:registry p)))
        ;; Collect
        (all-resolutions (apply append (map first results)))
        (all-logs (apply append (map second results))))
    (list all-resolutions all-logs)))

;; ── Step 3b: PROPAGATE (papers) ────────────────────────────────────

(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let ((p (nth (:posts ent) post-idx))
        (all-logs '()))
    ;; Sequential: apply resolutions to observers
    (for-each (lambda (res)
      (let ((logs (post-propagate p
                    (:broker-slot-idx res)
                    (:composed-thought res)
                    (:outcome res)
                    (:amount res)
                    (:direction res)
                    (:optimal-distances res))))
        (set! all-logs (append all-logs logs))))
      resolutions)
    all-logs))

;; ── Step 3c: UPDATE TRIGGERS ───────────────────────────────────────

(define (step-update-triggers [ent : Enterprise]
                              [post-idx : usize]
                              [market-thoughts : Vec<Vector>]
                              [c : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let ((p (nth (:posts ent) post-idx))
        (trades (trades-for-post (:treasury ent) post-idx))
        ((updates misses) (post-update-triggers p trades market-thoughts c)))
    ;; Write level updates back to the treasury
    (for-each (lambda (upd)
      (let (((trade-id new-levels) upd))
        (update-trade-stops (:treasury ent) trade-id new-levels)))
      updates)
    misses))

;; ── Step 4: COLLECT + FUND ─────────────────────────────────────────

(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))

;; ── on-candle — the main entry point ───────────────────────────────
;; Route to the right post, then four steps.
;; Returns: (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)

(define (on-candle [ent : Enterprise]
                   [raw-candle : RawCandle]
                   [c : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let ((all-logs '())
        (all-misses '()))

    ;; Step 1: RESOLVE + PROPAGATE
    (let ((resolve-logs (step-resolve-and-propagate ent)))
      (set! all-logs (append all-logs resolve-logs)))

    ;; Find the right post for this candle's asset pair
    (let ((post-idx (fold (lambda (found i)
                      (let ((p (nth (:posts ent) i)))
                        (if (and (= (:name (:source-asset p))
                                    (:name (:source-asset raw-candle)))
                                 (= (:name (:target-asset p))
                                    (:name (:target-asset raw-candle))))
                          i found)))
                    0 (range 0 (length (:posts ent))))))

    ;; Step 2: COMPUTE + DISPATCH
    (let (((proposals market-thoughts compute-misses)
           (step-compute-dispatch ent post-idx raw-candle c)))
      (set! all-misses (append all-misses compute-misses))

      ;; Cache market thoughts for step 3c
      (set! (:market-thoughts-cache ent) post-idx market-thoughts)

      ;; Submit proposals to treasury
      (for-each (lambda (prop)
        (submit-proposal (:treasury ent) prop))
        proposals)

      ;; Step 3a: TICK (parallel)
      (let (((resolutions tick-logs) (step-tick ent post-idx)))
        (set! all-logs (append all-logs tick-logs))

        ;; Step 3b: PROPAGATE (sequential)
        (let ((prop-logs (step-propagate ent post-idx resolutions)))
          (set! all-logs (append all-logs prop-logs)))

        ;; Step 3c: UPDATE TRIGGERS
        (let ((trigger-misses (step-update-triggers ent post-idx market-thoughts c)))
          (set! all-misses (append all-misses trigger-misses)))))

    ;; Step 4: COLLECT + FUND
    (let ((fund-logs (step-collect-fund ent)))
      (set! all-logs (append all-logs fund-logs)))

    (list all-logs all-misses))))
