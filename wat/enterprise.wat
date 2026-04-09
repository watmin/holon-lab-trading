;; enterprise.wat — Enterprise struct + interface + four-step loop
;; Depends on: post, treasury, enums, distances, settlement, simulation,
;;             log-entry, ctx, raw-candle
;; The coordination plane. The CSP sync point.

(require primitives)
(require enums)
(require distances)
(require raw-candle)
(require post)
(require treasury)
(require settlement)
(require simulation)
(require log-entry)
(require ctx)
(require newtypes)
(require broker)

(struct enterprise
  ;; The posts — one per asset pair
  [posts : Vec<Post>]
  ;; The treasury — shared across all posts
  [treasury : Treasury]
  ;; Per-candle cache — produced in step 2, consumed in step 3c
  [market-thoughts-cache : Vec<Vec<Vector>>])

(define (make-enterprise [posts : Vec<Post>] [treasury : Treasury])
  : Enterprise
  (enterprise posts treasury
    (map (lambda (_) '()) posts)))  ; one empty vec per post

;; ── Step 1: RESOLVE + PROPAGATE ────────────────────────────────────
;; Settle triggered trades, propagate outcomes to brokers → observers.
;; Returns: Vec<LogEntry>
(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  ;; Collect current prices from each post
  (let ((prices (fold (lambda (acc p)
                   (assoc acc
                     (list (:source-asset p) (:target-asset p))
                     (current-price p)))
                 (map-of) (:posts ent)))
        ;; Treasury settles triggered trades
        ((ts-settlements ts-logs) (settle-triggered (:treasury ent) prices))
        ;; Enrich settlements and propagate
        (prop-logs
          (apply append
            (map (lambda (ts)
              (let ((tr (:trade ts))
                    ;; Derive direction from exit vs entry price
                    (dir (derive-direction (:entry-rate tr) (:exit-price ts)))
                    ;; Compute optimal distances from price history
                    (optimal (compute-optimal-distances (:price-history tr) dir))
                    ;; Build complete settlement
                    (s (make-settlement ts dir optimal))
                    ;; Route to the post for propagation
                    (p (nth (:posts ent) (:post-idx tr))))
                (post-propagate p (:broker-slot-idx tr)
                  (:composed-thought ts) (:outcome ts)
                  (:amount ts) dir optimal)))
              ts-settlements))))
    (append ts-logs prop-logs)))

;; ── Step 2: COMPUTE + DISPATCH ─────────────────────────────────────
;; Post encodes, composes, proposes.
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<misses>)
(define (step-compute-dispatch [ent : Enterprise] [post-idx : usize]
                               [raw : RawCandle] [c : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let ((p (nth (:posts ent) post-idx)))
    (post-on-candle p raw c)))

;; ── Step 3a: TICK ──────────────────────────────────────────────────
;; Parallel tick of all brokers' papers.
;; Returns: (Vec<Resolution>, Vec<LogEntry>)
(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((p (nth (:posts ent) post-idx))
        (price (current-price p))
        ;; Tick all brokers in parallel — each touches only its own papers
        (results (pmap (lambda (brok) (tick-papers brok price))
                       (:registry p)))
        (all-resolutions (apply append (map first results)))
        (all-logs        (apply append (map second results))))
    (list all-resolutions all-logs)))

;; ── Step 3b: PROPAGATE (papers) ────────────────────────────────────
;; Sequential: apply paper resolutions to shared observers.
(define (step-propagate [ent : Enterprise] [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let ((p (nth (:posts ent) post-idx)))
    (apply append
      (map (lambda (res)
        (post-propagate p (:broker-slot-idx res)
          (:composed-thought res) (:outcome res)
          (:amount res) (:direction res)
          (:optimal-distances res)))
        resolutions))))

;; ── Step 3c: UPDATE TRIGGERS ───────────────────────────────────────
;; Post composes fresh thoughts, queries exit observers for distances.
;; Returns: Vec<misses>
(define (step-update-triggers [ent : Enterprise] [post-idx : usize]
                              [market-thoughts : Vec<Vector>] [c : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let ((p (nth (:posts ent) post-idx))
        (trades (trades-for-post (:treasury ent) post-idx))
        ((level-updates misses)
          (post-update-triggers p trades market-thoughts c)))
    ;; Write level updates back to treasury
    (for-each (lambda (upd)
      (let (((trade-id new-levels) upd))
        (update-trade-stops (:treasury ent) trade-id new-levels)))
      level-updates)
    misses))

;; ── Step 4: COLLECT + FUND ─────────────────────────────────────────
;; Treasury funds or rejects all proposals, returns log entries.
(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))

;; ── on-candle — the main entry point ───────────────────────────────
;; Route to the right post, then four steps.
;; Returns: (Vec<LogEntry>, Vec<misses>)
(define (on-candle [ent : Enterprise] [raw : RawCandle] [c : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let ((all-logs '())
        (all-misses '()))

    ;; Step 1: RESOLVE + PROPAGATE
    (let ((resolve-logs (step-resolve-and-propagate ent)))
      (set! all-logs (append all-logs resolve-logs)))

    ;; Find the post for this raw candle's asset pair
    (let ((post-idx (fold (lambda (found i)
                      (let ((p (nth (:posts ent) i)))
                        (if (and (= (:name (:source-asset p))
                                    (:name (:source-asset raw)))
                                 (= (:name (:target-asset p))
                                    (:name (:target-asset raw))))
                          i found)))
                      0 (range 0 (len (:posts ent))))))

      ;; Step 2: COMPUTE + DISPATCH
      (let (((proposals market-thoughts step2-misses)
              (step-compute-dispatch ent post-idx raw c)))
        ;; Cache market thoughts for step 3c
        (set! (:market-thoughts-cache ent) post-idx market-thoughts)
        (set! all-misses (append all-misses step2-misses))
        ;; Submit proposals to treasury
        (for-each (lambda (prop) (submit-proposal (:treasury ent) prop))
                  proposals)

        ;; Step 3a: TICK (parallel)
        (let (((resolutions tick-logs) (step-tick ent post-idx)))
          (set! all-logs (append all-logs tick-logs))

          ;; Step 3b: PROPAGATE (sequential)
          (let ((prop-logs (step-propagate ent post-idx resolutions)))
            (set! all-logs (append all-logs prop-logs)))

          ;; Step 3c: UPDATE TRIGGERS
          (let ((trigger-misses
                  (step-update-triggers ent post-idx market-thoughts c)))
            (set! all-misses (append all-misses trigger-misses))))))

    ;; Step 4: COLLECT + FUND
    (let ((fund-logs (step-collect-fund ent)))
      (set! all-logs (append all-logs fund-logs)))

    (list all-logs all-misses)))
