;; ── enterprise.wat ──────────────────────────────────────────────────
;;
;; The coordination plane. The CSP sync point. Routes raw candles to
;; the right post, coordinates the four-step loop, collects log entries
;; and cache misses as values.
;; Depends on: post, treasury, settlement, simulation, distances,
;;   enums, newtypes, log-entry, ctx.

(require post)
(require treasury)
(require settlement)
(require simulation)
(require distances)
(require enums)
(require newtypes)
(require log-entry)
(require ctx)

;; ── Struct ──────────────────────────────────────────────────────

(struct enterprise
  ;; The posts — one per asset pair
  [posts : Vec<Post>]                  ; each watches one market

  ;; The treasury — shared across all posts
  [treasury : Treasury]                ; holds capital, funds trades, settles

  ;; Per-candle cache — produced in step 2, consumed in step 3c
  [market-thoughts-cache : Vec<Vec<Vector>>]) ; one Vec<Vector> per post, cleared each candle

;; ── Constructor ─────────────────────────────────────────────────

(define (make-enterprise [posts : Vec<Post>] [treasury : Treasury])
  : Enterprise
  (make-enterprise posts treasury
    (map (lambda (_) (list)) posts)))   ; empty cache per post

;; ── on-candle ───────────────────────────────────────────────────
;; Route to the right post, then four steps. ctx flows in from the
;; binary. Returns log entries and cache misses as values.

(define (on-candle [ent : Enterprise] [raw-candle : RawCandle] [ctx : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let* (;; Find the post for this candle's asset pair
         (post-idx
           (first (filter-map
                    (lambda (i)
                      (let ((p (nth (:posts ent) i)))
                        (if (and (= (:source-asset p) (:source-asset raw-candle))
                                 (= (:target-asset p) (:target-asset raw-candle)))
                          (Some i)
                          None)))
                    (range (len (:posts ent))))))

         ;; ── Step 1: RESOLVE + PROPAGATE ────────────────────────
         (step1-logs (step-resolve-and-propagate ent))

         ;; ── Step 2: COMPUTE + DISPATCH ─────────────────────────
         ((proposals market-thoughts step2-misses)
           (step-compute-dispatch ent post-idx raw-candle ctx))

         ;; Cache market thoughts for step 3c
         (_ (set! (:market-thoughts-cache ent) post-idx market-thoughts))

         ;; Submit proposals to treasury
         (_ (for-each (lambda (p) (submit-proposal (:treasury ent) p))
                      proposals))

         ;; ── Step 3a: TICK ──────────────────────────────────────
         ((resolutions tick-logs) (step-tick ent post-idx))

         ;; ── Step 3b: PROPAGATE (papers) ────────────────────────
         (prop-logs (step-propagate ent post-idx resolutions))

         ;; ── Step 3c: UPDATE TRIGGERS ───────────────────────────
         (step3c-misses (step-update-triggers ent post-idx market-thoughts ctx))

         ;; ── Step 4: COLLECT + FUND ─────────────────────────────
         (fund-logs (step-collect-fund ent))

         ;; Collect all logs and misses
         (all-logs (append step1-logs tick-logs prop-logs fund-logs))
         (all-misses (append step2-misses step3c-misses)))

    (list all-logs all-misses)))

;; ── step-resolve-and-propagate ──────────────────────────────────
;; Step 1. Settle triggered trades, propagate outcomes to observers.
;; No ctx needed — settlement and propagation use pre-existing vectors.

(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  (let* (;; Collect current prices from each post
         (current-prices
           (fold-left
             (lambda (prices post)
               (assoc prices
                 (list (:source-asset post) (:target-asset post))
                 (current-price post)))
             (map-of)
             (:posts ent)))

         ;; Treasury settles triggered trades
         ((settlements settle-logs)
           (settle-triggered (:treasury ent) current-prices))

         ;; For each settlement: compute direction + optimal-distances,
         ;; route to the post for propagation
         (prop-logs
           (fold-left
             (lambda (logs settlement)
               (let* ((trade (:trade settlement))
                      ;; Derive direction from price movement
                      (direction (if (> (:exit-price settlement) (:entry-price trade))
                                   :up :down))
                      ;; Compute optimal distances from price history
                      (optimal (compute-optimal-distances
                                 (:price-history trade) direction))
                      ;; Route to post for propagation
                      (post (nth (:posts ent) (:post-idx trade)))
                      (new-logs (post-propagate post
                                  (:broker-slot-idx trade)
                                  (:composed-thought settlement)
                                  (:outcome settlement)
                                  (:amount settlement)
                                  direction
                                  optimal)))
                 (append logs new-logs)))
             (list)
             settlements)))

    (append settle-logs prop-logs)))

;; ── step-compute-dispatch ───────────────────────────────────────
;; Step 2. Post encodes, composes, proposes.

(define (step-compute-dispatch [ent : Enterprise]
                               [post-idx : usize]
                               [raw-candle : RawCandle]
                               [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (post-on-candle (nth (:posts ent) post-idx) raw-candle ctx))

;; ── step-tick ───────────────────────────────────────────────────
;; Step 3a. Parallel tick all brokers' papers.

(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (post-tick (nth (:posts ent) post-idx)))

;; ── step-propagate ──────────────────────────────────────────────
;; Step 3b. Sequential: apply paper resolutions to observers.

(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let ((post (nth (:posts ent) post-idx)))
    (fold-left
      (lambda (logs resolution)
        (let ((new-logs (post-propagate post
                          (:broker-slot-idx resolution)
                          (:composed-thought resolution)
                          (:outcome resolution)
                          (:amount resolution)
                          (:direction resolution)
                          (:optimal-distances resolution))))
          (append logs new-logs)))
      (list)
      resolutions)))

;; ── step-update-triggers ────────────────────────────────────────
;; Step 3c. Query exit observers for fresh distances on active trades.
;; Apply level updates to treasury. Return cache misses.

(define (step-update-triggers [ent : Enterprise]
                              [post-idx : usize]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let* ((trades (trades-for-post (:treasury ent) post-idx))
         (post (nth (:posts ent) post-idx))
         ((level-updates misses)
           (post-update-triggers post trades market-thoughts ctx))
         ;; Apply level updates to treasury
         (_ (for-each
              (lambda (update-pair)
                (let (((trade-id new-levels) update-pair))
                  (update-trade-stops (:treasury ent) trade-id new-levels)))
              level-updates)))
    misses))

;; ── step-collect-fund ───────────────────────────────────────────
;; Step 4. Treasury funds or rejects all proposals.

(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))
