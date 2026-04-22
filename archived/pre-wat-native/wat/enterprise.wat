;; ── enterprise.wat ──────────────────────────────────────────────────
;;
;; The coordination plane. The CSP sync point. Routes raw candles to
;; the right post, coordinates the four-step loop, collects log entries
;; and cache misses as values.
;; Depends on: post, treasury, settlement, simulation, distances,
;;   enums, newtypes, log-entry, ctx, broker, indicator-bank.

(require post)
(require treasury)
(require settlement)
(require simulation)
(require distances)
(require enums)
(require newtypes)
(require log-entry)
(require ctx)
(require broker)
(require indicator-bank)

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

;; ── on-candle-batch ─────────────────────────────────────────────
;; Process a batch of candles within one recalibration window.
;; The indicator bank ticks sequentially (streaming state).
;; The encoding + composition + paper registration runs in parallel
;; across all candles in the batch — the discriminant is frozen.
;; Sync at the end: apply all accumulated observations, recalibrate.

(define (on-candle-batch [ent : Enterprise]
                         [candles : &[RawCandle]]
                         [ctx : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let* ((post-idx 0) ; single post for now

         ;; ── Phase 1: Tick indicators sequentially ──────────────
         ;; Streaming state requires order. Produces enriched candles.
         (enriched-candles
           (fold-left
             (lambda (acc rc)
               (let* ((enriched (indicator-bank-tick
                                  (:indicator-bank (nth (:posts ent) post-idx)) rc))
                      (_ (push-back! (:candle-window (nth (:posts ent) post-idx)) enriched))
                      (_ (while (> (len (:candle-window (nth (:posts ent) post-idx)))
                                   (:max-window-size (nth (:posts ent) post-idx)))
                           (pop-front! (:candle-window (nth (:posts ent) post-idx)))))
                      (_ (incr! (:encode-count (nth (:posts ent) post-idx)))))
                 (append acc (list enriched))))
             (list)
             candles))

         ;; ── Phase 2: Parallel across candles ───────────────────
         ;; Each candle's encoding is independent. The discriminant
         ;; is frozen within this window — predictions are stable.
         ;; Within each candle: the N×M grid is also parallel.
         (post (nth (:posts ent) post-idx))
         (n (len (:market-observers post)))
         (m (len (:exit-observers post)))

         (batch-results
           (par-map
             (lambda (enriched)
               (let* (;; Window snapshot
                      (window (vec-from (:candle-window post)))

                      ;; Market observer encoding — per observer
                      (market-results
                        (map (lambda (obs)
                               (let* ((facts (market-lens-facts (:lens obs) enriched window))
                                      (bundle-ast (ThoughtAST::Bundle facts))
                                      ((thought misses) (thought-encoder-encode
                                                          (:thought-encoder ctx) bundle-ast)))
                                 (list thought misses)))
                             (:market-observers post)))

                      (market-thoughts (map first market-results))
                      (candle-misses (flat-map second market-results))

                      ;; N×M grid — exit encoding + composition
                      (grid-results
                        (map (lambda (slot-idx)
                               (let* ((mi (/ slot-idx m))
                                      (ei (% slot-idx m))
                                      (market-thought (nth market-thoughts mi))
                                      (exit-facts (exit-lens-facts
                                                    (:lens (nth (:exit-observers post) ei))
                                                    enriched))
                                      (exit-bundle (ThoughtAST::Bundle exit-facts))
                                      ((exit-vec exit-misses)
                                        (thought-encoder-encode
                                          (:thought-encoder ctx) exit-bundle))
                                      (composed (bundle market-thought exit-vec))
                                      ((dists _)
                                        (recommended-distances
                                          (nth (:exit-observers post) ei)
                                          composed
                                          (:scalar-accums (nth (:registry post) slot-idx))
                                          (scalar-encoder (:thought-encoder ctx)))))
                                 (list slot-idx composed dists exit-misses)))
                             (range (* n m))))

                      (grid-misses (flat-map (lambda (r) (nth r 3)) grid-results)))

                 (list market-thoughts candle-misses grid-misses grid-results)))
             enriched-candles))

         ;; ── Phase 3: Sequential — apply all mutations ──────────
         ;; The discriminant hasn't changed. Apply all deferred updates.
         ((all-logs all-misses)
           (fold-left
             (lambda ((logs misses) batch-item)
               (let* (((market-thoughts candle-misses grid-misses grid-results) batch-item)

                      ;; Cache market thoughts
                      (_ (set! (:market-thoughts-cache ent) post-idx market-thoughts))

                      ;; Apply broker mutations sequentially (propose + register paper)
                      (price (current-price (nth (:posts ent) post-idx)))
                      (_ (for-each
                           (lambda (result)
                             (let (((slot-idx composed dists _) result))
                               (broker-propose (nth (:registry (nth (:posts ent) post-idx)) slot-idx) composed)
                               (broker-register-paper
                                 (nth (:registry (nth (:posts ent) post-idx)) slot-idx)
                                 composed price dists)))
                           grid-results))

                      ;; Tick papers
                      ((resolutions tick-logs) (step-tick ent post-idx))

                      ;; Propagate
                      (prop-logs (step-propagate ent post-idx resolutions)))

                 (list (append logs candle-misses grid-misses tick-logs prop-logs)
                       (append misses candle-misses grid-misses))))
             (list (list) (list))
             batch-results))

         ;; ── Phase 4: Treasury operations for the full batch ────
         (fund-logs (step-collect-fund ent)))

    (list (append all-logs fund-logs) all-misses)))

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

         (recalib 500) ; default recalibration interval

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
                                  optimal
                                  recalib)))
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
;; pmap: each broker touches ONLY its own papers. Disjoint. Lock-free.
;; Logs created at enterprise level, not inside broker tick-papers.

(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let* ((price (current-price (nth (:posts ent) post-idx)))

         ;; par_iter_mut: each broker is disjoint. collect() is the sync.
         (results
           (par-map
             (lambda (broker)
               (broker-tick-papers broker price))
             (:registry (nth (:posts ent) post-idx))))

         ;; Sequential: flatten and produce logs at this level
         ((all-resolutions all-logs)
           (fold-left
             (lambda ((resolutions logs) broker-resolutions)
               (let ((new-logs
                       (map (lambda (res)
                              (make-log-entry :paper-resolved
                                (:broker-slot-idx res)
                                (:outcome res)
                                (:optimal-distances res)))
                            broker-resolutions)))
                 (list (append resolutions broker-resolutions)
                       (append logs new-logs))))
             (list (list) (list))
             results)))

    (list all-resolutions all-logs)))

;; ── step-propagate ──────────────────────────────────────────────
;; Step 3b. Three phases: compute update messages (parallel), group
;; by recipient, apply (parallel per scope). Not a simple sequential
;; fold — the Rust uses par_iter for both fact computation and
;; application, with a sequential grouping phase between.

(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let* ((recalib 500) ; default
         (post (nth (:posts ent) post-idx))
         (m (len (:exit-observers post)))

         ;; ── Phase 1: parallel — compute update messages as values.
         ;; Each resolution produces PropagationFacts. No observer mutation.
         (facts-list
           (par-map
             (lambda (res)
               (let* ((mi (/ (:broker-slot-idx res) m))
                      (ei (% (:broker-slot-idx res) m)))
                 (list (:broker-slot-idx res)
                       mi ei
                       (:composed-thought res)
                       (:outcome res)
                       (:amount res)
                       (:direction res)
                       (:optimal-distances res))))
             resolutions))

         ;; ── Phase 2: sequential — group by recipient.
         ;; broker-updates[slot] = Vec of (thought, outcome, weight, direction, optimal)
         ;; market-updates[mi]  = Vec of (thought, direction, weight)
         ;; exit-updates[ei]    = Vec of (composed, optimal, weight)
         (n-brokers (len (:registry post)))
         (n-market  (len (:market-observers post)))
         (n-exit    (len (:exit-observers post)))

         ((broker-updates market-updates exit-updates)
           (fold-left
             (lambda ((b-upd m-upd e-upd) fact)
               (let* (((slot mi ei thought outcome weight direction optimal) fact))
                 (list
                   (assoc-append b-upd slot
                     (list thought outcome weight direction optimal))
                   (assoc-append m-upd mi
                     (list thought direction weight))
                   (assoc-append e-upd ei
                     (list thought optimal weight)))))
             (list (vec-of-empty n-brokers)
                   (vec-of-empty n-market)
                   (vec-of-empty n-exit))
             facts-list))

         ;; ── Phase 3a: parallel — apply broker updates.
         ;; Each broker is its own scope.
         (_ (par-for-each-indexed
              (lambda (slot-idx broker)
                (for-each
                  (lambda (upd)
                    (let (((thought outcome weight direction optimal) upd))
                      (broker-propagate broker thought outcome weight
                                        direction optimal recalib
                                        (ctx-scalar-encoder-placeholder))))
                  (nth broker-updates slot-idx)))
              (:registry post)))

         ;; ── Phase 3b: parallel — apply market observer updates.
         (_ (par-for-each-indexed
              (lambda (mi obs)
                (for-each
                  (lambda (upd)
                    (let (((thought direction weight) upd))
                      (observer-resolve obs thought direction weight recalib)))
                  (nth market-updates mi)))
              (:market-observers post)))

         ;; ── Phase 3c: parallel — apply exit observer updates.
         (_ (par-for-each-indexed
              (lambda (ei obs)
                (for-each
                  (lambda (upd)
                    (let (((thought optimal weight) upd))
                      (observer-observe-distances obs thought optimal weight)))
                  (nth exit-updates ei)))
              (:exit-observers post))))

    ;; Logs — one per resolution
    (map (lambda (fact)
           (let (((slot _ _ _ _ _ _ _) fact))
             (make-log-entry :propagated slot 2)))
         facts-list)))

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
