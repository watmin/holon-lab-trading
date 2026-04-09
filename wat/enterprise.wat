;; enterprise.wat — Enterprise struct + interface + four-step loop
;; Depends on: post, treasury, ctx, enums, distances, simulation, settlement, log-entry

(require primitives)
(require post)
(require treasury)
(require ctx)
(require enums)
(require distances)
(require simulation)
(require settlement)
(require log-entry)

(struct enterprise
  [posts : Vec<Post>]
  [treasury : Treasury]
  ;; Per-candle cache — produced in step 2, consumed in step 3c
  [market-thoughts-cache : Vec<Vec<Vector>>])

(define (make-enterprise [posts : Vec<Post>] [treasury : Treasury])
  : Enterprise
  (enterprise posts treasury
              (map (lambda (p) '()) posts)))  ; empty cache per post

;; Step 1: RESOLVE + PROPAGATE (real trades)
;; Settle triggered trades, propagate outcomes to brokers → observers.
(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  (let (;; Collect current prices from each post
        (current-prices
          (fold (lambda (acc post)
            (assoc acc
              (list (:source-asset post) (:target-asset post))
              (current-price post)))
            (map-of)
            (:posts ent)))
        ;; Treasury settles triggered trades
        ((treasury-settlements settle-logs) (settle-triggered (:treasury ent) current-prices))
        (prop-logs '()))

    ;; For each settlement: enrich and propagate
    (for-each (lambda (ts)
      (let ((trade (:trade ts))
            (exit-price (:exit-price ts))
            (entry (:entry-rate trade))
            ;; Derive direction from price movement
            (direction (if (> exit-price entry) :up :down))
            ;; Compute optimal distances from trade's price history
            (optimal (compute-optimal-distances (:price-history trade) direction))
            ;; Route to the right post
            (post-idx (:post-idx trade))
            (post (nth (:posts ent) post-idx))
            (logs (post-propagate post (:broker-slot-idx trade)
                    (:composed-thought ts) (:outcome ts)
                    (:amount ts) direction optimal)))
        (set! prop-logs (append prop-logs logs))))
      treasury-settlements)

    (append settle-logs prop-logs)))

;; Step 2: COMPUTE + DISPATCH
;; Post encodes, composes, proposes.
(define (step-compute-dispatch [ent : Enterprise] [post-idx : usize]
                               [raw : RawCandle] [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let ((post (nth (:posts ent) post-idx)))
    (post-on-candle post raw ctx)))

;; Step 3a: TICK (parallel)
;; Tick all brokers' papers for a given post.
(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((post (nth (:posts ent) post-idx))
        ;; Parallel tick of all brokers
        (results (pmap (lambda (broker) (tick-papers broker (current-price post)))
                       (:registry post)))
        (all-resolutions (apply append (map first results)))
        (all-logs (apply append (map second results))))
    (list all-resolutions all-logs)))

;; Step 3b: PROPAGATE (paper resolutions, sequential)
;; Apply resolutions to observers via brokers.
(define (step-propagate [ent : Enterprise] [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let ((post (nth (:posts ent) post-idx))
        (all-logs '()))
    (for-each (lambda (res)
      (let ((logs (post-propagate post (:broker-slot-idx res)
                    (:composed-thought res) (:outcome res)
                    (:amount res) (:direction res)
                    (:optimal-distances res))))
        (set! all-logs (append all-logs logs))))
      resolutions)
    all-logs))

;; Step 3c: UPDATE TRIGGERS
;; Update stop levels for active trades.
(define (step-update-triggers [ent : Enterprise] [post-idx : usize]
                              [market-thoughts : Vec<Vector>] [ctx : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let ((post (nth (:posts ent) post-idx))
        (trades (trades-for-post (:treasury ent) post-idx))
        ((updates misses) (post-update-triggers post trades market-thoughts ctx)))
    ;; Write level updates back to treasury
    (for-each (lambda (update-pair)
      (let (((trade-id new-levels) update-pair))
        (update-trade-stops (:treasury ent) trade-id new-levels)))
      updates)
    misses))

;; Step 4: COLLECT + FUND
;; Treasury funds or rejects all proposals.
(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))

;; on-candle — the main entry point. Route to the right post, four steps.
;; Returns (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>) — logs and cache misses.
(define (on-candle [ent : Enterprise] [raw : RawCandle] [ctx : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let ((all-logs '())
        (all-misses '())
        ;; Find the right post for this candle's asset pair
        (post-idx (fold (lambda (found i)
                    (if (some? found) found
                      (let ((post (nth (:posts ent) i)))
                        (if (and (= (:name (:source-asset post))
                                    (:name (:source-asset raw)))
                                 (= (:name (:target-asset post))
                                    (:name (:target-asset raw))))
                          (Some i)
                          None))))
                    None
                    (range 0 (length (:posts ent))))))

    (match post-idx
      ((Some idx)
        ;; Step 1: RESOLVE + PROPAGATE
        (let ((resolve-logs (step-resolve-and-propagate ent)))
          (set! all-logs (append all-logs resolve-logs)))

        ;; Step 2: COMPUTE + DISPATCH
        (let (((proposals market-thoughts compute-misses)
                (step-compute-dispatch ent idx raw ctx)))
          (set! all-misses (append all-misses compute-misses))
          ;; Cache market thoughts for step 3c
          (set! (:market-thoughts-cache ent) idx market-thoughts)
          ;; Submit proposals to treasury
          (for-each (lambda (proposal)
            (submit-proposal (:treasury ent) proposal))
            proposals))

        ;; Step 3a: TICK (parallel)
        (let (((resolutions tick-logs) (step-tick ent idx)))
          (set! all-logs (append all-logs tick-logs))

          ;; Step 3b: PROPAGATE (sequential)
          (let ((prop-logs (step-propagate ent idx resolutions)))
            (set! all-logs (append all-logs prop-logs))))

        ;; Step 3c: UPDATE TRIGGERS
        (let ((trigger-misses
                (step-update-triggers ent idx
                  (nth (:market-thoughts-cache ent) idx) ctx)))
          (set! all-misses (append all-misses trigger-misses)))

        ;; Step 4: COLLECT + FUND
        (let ((fund-logs (step-collect-fund ent)))
          (set! all-logs (append all-logs fund-logs))))

      (None (begin)))  ; no post for this asset pair — skip

    (list all-logs all-misses)))
