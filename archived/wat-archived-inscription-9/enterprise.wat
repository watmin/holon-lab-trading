;; enterprise.wat — Enterprise struct + interface + four-step loop
;; Depends on: post, treasury, ctx, enums, distances, simulation

(require primitives)
(require enums)
(require distances)
(require raw-candle)
(require post)
(require treasury)
(require settlement)
(require log-entry)
(require ctx)
(require simulation)
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
    (map (lambda (_) '()) posts)))

;; ── Step 1: RESOLVE + PROPAGATE ────────────────────────────────────
;; Settlement and propagation use pre-existing vectors. No encoding.
(define (step-resolve-and-propagate [ent : Enterprise])
  : (Enterprise Vec<LogEntry>)
  (let (;; Collect current prices from each post
        (current-prices
          (fold (lambda (m p)
                  (assoc m (list (:source-asset p) (:target-asset p))
                    (current-price p)))
                (map-of)
                (:posts ent)))
        ;; Settle triggered trades
        ((new-treasury settlements settle-logs)
          (settle-triggered (:treasury ent) current-prices))
        ;; For each settlement, compute direction + optimal and propagate
        ((final-ent prop-logs)
          (fold (lambda (state stl)
                  (let (((e logs) state)
                        (t (:trade stl))
                        (post-idx (:post-idx t))
                        (slot (:broker-slot-idx t))
                        (thought (:composed-thought stl))
                        (outcome (:outcome stl))
                        (weight (:amount stl))
                        ;; Derive direction from price movement
                        (direction (if (> (:exit-price stl) (:entry-rate t))
                                     :up :down))
                        ;; Compute optimal distances from trade's price history
                        (optimal (compute-optimal-distances
                                   (:price-history t) direction))
                        ;; Propagate to the post
                        (post-ref (nth (:posts e) post-idx))
                        ((updated-post prop-log)
                          (post-propagate post-ref slot thought outcome
                            weight direction optimal))
                        ;; Update the post in the enterprise
                        (new-posts (map (lambda (pair)
                                     (let (((i p) pair))
                                       (if (= i post-idx) updated-post p)))
                                   (map (lambda (i) (list i (nth (:posts e) i)))
                                        (range 0 (length (:posts e)))))))
                    (list (update e :posts new-posts)
                          (append logs prop-log))))
                (list (update ent :treasury new-treasury) '())
                settlements)))
    (list final-ent (append settle-logs prop-logs))))

;; ── Step 2: COMPUTE + DISPATCH ─────────────────────────────────────
(define (step-compute-dispatch [ent : Enterprise]
                                [post-idx : usize]
                                [rc : RawCandle]
                                [c : Ctx])
  : (Enterprise Vec<Proposal> Vec<Vector> Vec<(ThoughtAST, Vector)>)
  (let ((post-ref (nth (:posts ent) post-idx))
        ((updated-post proposals market-thoughts misses)
          (post-on-candle post-ref rc c))
        ;; Update post and cache market thoughts
        (new-posts (map (lambda (pair)
                     (let (((i p) pair))
                       (if (= i post-idx) updated-post p)))
                   (map (lambda (i) (list i (nth (:posts ent) i)))
                        (range 0 (length (:posts ent))))))
        (new-cache (map (lambda (pair)
                     (let (((i cached) pair))
                       (if (= i post-idx) market-thoughts cached)))
                   (map (lambda (i) (list i (nth (:market-thoughts-cache ent) i)))
                        (range 0 (length (:market-thoughts-cache ent)))))))
    (list (update ent :posts new-posts :market-thoughts-cache new-cache)
          proposals market-thoughts misses)))

;; ── Step 3a: TICK ──────────────────────────────────────────────────
;; Parallel tick of all brokers' papers.
(define (step-tick [ent : Enterprise] [post-idx : usize])
  : (Enterprise Vec<Resolution> Vec<LogEntry>)
  (let ((post-ref (nth (:posts ent) post-idx))
        (price (current-price post-ref))
        ;; par-tick all brokers
        (broker-results
          (pmap (lambda (b) (tick-papers b price))
                (:registry post-ref)))
        (updated-brokers (map first broker-results))
        (all-resolutions (apply append (map second broker-results)))
        (all-logs (apply append (map (lambda (r) (nth r 2)) broker-results)))
        ;; Update post registry
        (updated-post (update post-ref :registry updated-brokers))
        (new-posts (map (lambda (pair)
                     (let (((i p) pair))
                       (if (= i post-idx) updated-post p)))
                   (map (lambda (i) (list i (nth (:posts ent) i)))
                        (range 0 (length (:posts ent)))))))
    (list (update ent :posts new-posts) all-resolutions all-logs)))

;; ── Step 3b: PROPAGATE (paper resolutions) ─────────────────────────
(define (step-propagate [ent : Enterprise]
                         [post-idx : usize]
                         [resolutions : Vec<Resolution>])
  : (Enterprise Vec<LogEntry>)
  (fold (lambda (state res)
          (let (((e logs) state)
                (post-ref (nth (:posts e) post-idx))
                ((updated-post prop-logs)
                  (post-propagate post-ref
                    (:broker-slot-idx res)
                    (:composed-thought res)
                    (:outcome res)
                    (:amount res)
                    (:direction res)
                    (:optimal-distances res)))
                (new-posts (map (lambda (pair)
                             (let (((i p) pair))
                               (if (= i post-idx) updated-post p)))
                           (map (lambda (i) (list i (nth (:posts e) i)))
                                (range 0 (length (:posts e)))))))
            (list (update e :posts new-posts)
                  (append logs prop-logs))))
        (list ent '())
        resolutions))

;; ── Step 3c: UPDATE TRIGGERS ───────────────────────────────────────
(define (step-update-triggers [ent : Enterprise]
                               [post-idx : usize]
                               [market-thoughts : Vec<Vector>]
                               [c : Ctx])
  : (Enterprise Vec<(ThoughtAST, Vector)>)
  (let ((trades (trades-for-post (:treasury ent) post-idx))
        (post-ref (nth (:posts ent) post-idx))
        ((level-updates misses)
          (post-update-triggers post-ref trades market-thoughts c))
        ;; Apply level updates to treasury
        (new-treasury
          (fold (lambda (t update-pair)
                  (let (((tid lvls) update-pair))
                    (update-trade-stops t tid lvls)))
                (:treasury ent)
                level-updates)))
    (list (update ent :treasury new-treasury) misses)))

;; ── Step 4: COLLECT + FUND ─────────────────────────────────────────
(define (step-collect-fund [ent : Enterprise])
  : (Enterprise Vec<LogEntry>)
  (let (((new-treasury logs) (fund-proposals (:treasury ent))))
    (list (update ent :treasury new-treasury) logs)))

;; ── on-candle — the four-step loop ─────────────────────────────────
;; Route to the right post, then four steps.
(define (on-candle [ent : Enterprise] [rc : RawCandle] [c : Ctx])
  : (Enterprise Vec<LogEntry> Vec<(ThoughtAST, Vector)>)
  (let (;; Find the right post
        (post-idx (fold (lambda (found pair)
                     (let (((i p) pair))
                       (if (and (= (:name (:source-asset p))
                                   (:name (:source-asset rc)))
                                (= (:name (:target-asset p))
                                   (:name (:target-asset rc))))
                         i found)))
                   0
                   (map (lambda (i) (list i (nth (:posts ent) i)))
                        (range 0 (length (:posts ent)))))))

    ;; Step 1: RESOLVE + PROPAGATE
    (let (((ent1 logs1) (step-resolve-and-propagate ent)))

    ;; Step 2: COMPUTE + DISPATCH
    (let (((ent2 proposals market-thoughts misses2)
            (step-compute-dispatch ent1 post-idx rc c)))

    ;; Submit proposals to treasury
    (let ((ent2b (fold (lambda (e prop)
                     (update e :treasury (submit-proposal (:treasury e) prop)))
                   ent2 proposals)))

    ;; Step 3a: TICK (parallel)
    (let (((ent3a resolutions tick-logs) (step-tick ent2b post-idx)))

    ;; Step 3b: PROPAGATE (sequential)
    (let (((ent3b prop-logs) (step-propagate ent3a post-idx resolutions)))

    ;; Step 3c: UPDATE TRIGGERS
    (let (((ent3c trigger-misses)
            (step-update-triggers ent3b post-idx
              (nth (:market-thoughts-cache ent3b) post-idx) c)))

    ;; Step 4: COLLECT + FUND
    (let (((ent4 fund-logs) (step-collect-fund ent3c)))

    ;; Collect all logs and misses
    (let ((all-logs (append logs1 tick-logs prop-logs fund-logs))
          (all-misses (append misses2 trigger-misses))
          ;; Clear market-thoughts-cache for this post
          (final-ent (update ent4
                       :market-thoughts-cache
                       (map (lambda (pair)
                              (let (((i cached) pair))
                                (if (= i post-idx) '() cached)))
                            (map (lambda (i) (list i (nth (:market-thoughts-cache ent4) i)))
                                 (range 0 (length (:market-thoughts-cache ent4))))))))
      (list final-ent all-logs all-misses)))))))))))
