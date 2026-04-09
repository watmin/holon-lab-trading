;; enterprise.wat — the coordination plane
;;
;; Depends on: everything above — post, treasury, settlement,
;;             simulation, enums, distances, log-entry, ctx
;;
;; THREE fields: posts, treasury, market-thoughts-cache.
;; on-candle returns (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>).
;; Six step functions. Four-step loop.

(require primitives)
(require enums)
(require newtypes)
(require distances)
(require post)
(require treasury)
(require settlement)
(require simulation)
(require log-entry)
(require ctx)

(struct enterprise
  [posts : Vec<Post>]                             ; each watches one market
  [treasury : Treasury]                           ; shared across all posts
  [market-thoughts-cache : Vec<Vec<Vector>>])     ; one Vec<Vector> per post, cleared each candle

;; ── Constructor ────────────────────────────────────────────────────

(define (make-enterprise [posts : Vec<Post>]
                         [treasury : Treasury])
  : Enterprise
  (enterprise
    posts
    treasury
    (map (lambda (_) '()) posts)))                ; empty cache per post

;; ── on-candle ──────────────────────────────────────────────────────
;; Route to the right post, then four steps.
;; Returns: (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)

(define (on-candle [ent : Enterprise]
                   [raw-candle : RawCandle]
                   [ctx : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let* (;; Find the post for this candle's asset pair
         (post-idx (find-post-idx ent raw-candle))
         ;; Step 1: RESOLVE + PROPAGATE (real trades)
         (step1-logs (step-resolve-and-propagate ent))
         ;; Step 2: COMPUTE + DISPATCH
         ((proposals market-thoughts step2-misses)
           (step-compute-dispatch ent post-idx raw-candle ctx))
         ;; Cache market thoughts for step 3c
         (_ (set! (nth (:market-thoughts-cache ent) post-idx) market-thoughts))
         ;; Submit proposals to treasury
         (_ (for-each (lambda (prop) (submit-proposal (:treasury ent) prop))
                      proposals))
         ;; Step 3a: TICK (parallel)
         ((resolutions step3a-logs) (step-tick ent post-idx))
         ;; Step 3b: PROPAGATE (papers — sequential)
         (step3b-logs (step-propagate ent post-idx resolutions))
         ;; Step 3c: UPDATE TRIGGERS
         (step3c-misses (step-update-triggers ent post-idx market-thoughts ctx))
         ;; Step 4: COLLECT + FUND
         (step4-logs (step-collect-fund ent))
         ;; Collect all logs
         (all-logs (append step1-logs step3a-logs step3b-logs step4-logs))
         ;; Collect all misses
         (all-misses (append step2-misses step3c-misses)))
    (list all-logs all-misses)))

;; ── find-post-idx (internal) ───────────────────────────────────────
;; Find which post handles this raw candle's asset pair.

(define (find-post-idx [ent : Enterprise] [raw-candle : RawCandle])
  : usize
  (let ((idx 0)
        (found None))
    (for-each
      (lambda (post)
        (when (and (= (:source-asset post) (:source-asset raw-candle))
                   (= (:target-asset post) (:target-asset raw-candle)))
          (set! found (Some idx)))
        (set! idx (+ idx 1)))
      (:posts ent))
    (match found
      ((Some i) i)
      (None 0))))

;; ── Step 1: RESOLVE + PROPAGATE ────────────────────────────────────
;; Settle triggered trades, propagate outcomes to brokers -> observers.
;; No ctx needed — uses pre-existing vectors.

(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  (let* (;; Collect current prices from each post
         (current-prices
           (fold-left
             (lambda (acc post)
               (assoc acc
                      (list (:source-asset post) (:target-asset post))
                      (current-price post)))
             (map-of)
             (:posts ent)))
         ;; Treasury settles triggered trades
         ((treasury-settlements settle-logs)
           (settle-triggered (:treasury ent) current-prices))
         ;; Enrich each TreasurySettlement into a Settlement and propagate
         (propagate-logs
           (fold-left
             (lambda (acc ts)
               (let* ((trd (:trade ts))
                      (exit-price (:exit-price ts))
                      (entry-rate (:entry-rate trd))
                      ;; Derive direction from price movement
                      (direction (if (> exit-price entry-rate) :up :down))
                      ;; Replay trade's price-history for optimal distances
                      (optimal (compute-optimal-distances
                                 (:price-history trd) direction))
                      ;; Route to the right post
                      (post (nth (:posts ent) (:post-idx trd)))
                      (prop-logs (post-propagate post
                                                 (:broker-slot-idx trd)
                                                 (:composed-thought ts)
                                                 (:outcome ts)
                                                 (:amount ts)
                                                 direction
                                                 optimal)))
                 (append acc prop-logs)))
             '()
             treasury-settlements)))
    (append settle-logs propagate-logs)))

;; ── Step 2: COMPUTE + DISPATCH ─────────────────────────────────────
;; Post encodes, composes, proposes.
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)

(define (step-compute-dispatch [ent : Enterprise]
                               [post-idx : usize]
                               [raw-candle : RawCandle]
                               [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let ((post (nth (:posts ent) post-idx)))
    (post-on-candle post raw-candle ctx)))

;; ── Step 3a: TICK ──────────────────────────────────────────────────
;; Parallel tick of all brokers' papers.
;; Returns: (Vec<Resolution>, Vec<LogEntry>)

(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let* ((post (nth (:posts ent) post-idx))
         (price (current-price post))
         ;; Parallel tick each broker — disjoint slots, lock-free
         (broker-results
           (pmap (lambda (brkr)
                   (tick-papers brkr price))
                 (:registry post)))
         ;; Collect all resolutions and logs
         (all-resolutions (apply append (map first broker-results)))
         (all-logs (apply append (map second broker-results))))
    (list all-resolutions all-logs)))

;; ── Step 3b: PROPAGATE (papers) ────────────────────────────────────
;; Sequential: apply resolutions to observers.

(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let ((post (nth (:posts ent) post-idx)))
    (fold-left
      (lambda (acc res)
        (let ((prop-logs (post-propagate post
                                         (:broker-slot-idx res)
                                         (:composed-thought res)
                                         (:outcome res)
                                         (:amount res)
                                         (:direction res)
                                         (:optimal-distances res))))
          (append acc prop-logs)))
      '()
      resolutions)))

;; ── Step 3c: UPDATE TRIGGERS ───────────────────────────────────────
;; Enterprise queries treasury for active trades, post computes new levels.
;; Returns: Vec<(ThoughtAST, Vector)> — cache misses

(define (step-update-triggers [ent : Enterprise]
                              [post-idx : usize]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let* ((post (nth (:posts ent) post-idx))
         (trades (trades-for-post (:treasury ent) post-idx))
         ((level-updates misses)
           (post-update-triggers post trades market-thoughts ctx))
         ;; Write level updates back to treasury
         (_ (for-each
              (lambda (update)
                (let ((trade-id (first update))
                      (new-levels (second update)))
                  (update-trade-stops (:treasury ent) trade-id new-levels)))
              level-updates)))
    misses))

;; ── Step 4: COLLECT + FUND ─────────────────────────────────────────
;; Treasury funds or rejects all proposals, drains proposals.

(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))
