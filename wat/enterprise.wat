;; enterprise.wat — Enterprise struct + interface + four-step loop
;; Depends on: post, treasury, ctx, simulation, settlement, all enums

(require primitives)
(require enums)
(require distances)
(require raw-candle)
(require post)
(require treasury)
(require settlement)
(require log-entry)
(require thought-encoder)
(require ctx)
(require simulation)

;; ── Enterprise — the coordination plane ───────────────────────────────
;; The CSP sync point. Routes raw candles to the right post.
;; Coordinates the four-step loop across all posts and the treasury.
(struct enterprise
  [posts : Vec<Post>]
  [treasury : Treasury]
  [market-thoughts-cache : Vec<Vec<Vector>>])

(define (make-enterprise [posts : Vec<Post>]
                         [treasury : Treasury])
  : Enterprise
  (let ((cache (map (lambda (_) '()) posts)))
    (enterprise posts treasury cache)))

;; ── find-post — which post handles this asset pair? ───────────────────
(define (find-post [ent : Enterprise]
                   [raw : RawCandle])
  : (Option<usize>)
  (fold-left (lambda (found i)
    (match found
      ((Some _) found)
      (None
        (let ((p (nth (:posts ent) i)))
          (if (and (= (:name (:source-asset p)) (:name (:source-asset raw)))
                   (= (:name (:target-asset p)) (:name (:target-asset raw))))
            (Some i)
            None)))))
    None (range 0 (length (:posts ent)))))

;; ── step-resolve-and-propagate — Step 1 ──────────────────────────────
;; Settle triggered trades, route outcomes to posts for propagation.
;; Returns: Vec<LogEntry>
(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  ;; Collect current prices from each post
  (let ((current-prices (map-of)))
    (for-each (lambda (p)
      (let ((pair-key (list (:source-asset p) (:target-asset p)))
            (price (current-price p)))
        (set! current-prices (assoc current-prices pair-key price))))
      (:posts ent))
    ;; Treasury settles triggered trades
    (let (((settlements settle-logs) (settle-triggered (:treasury ent) current-prices))
          (prop-logs '()))
      ;; For each settlement: compute direction + optimal, route to post
      (for-each (lambda (s)
        (let ((trade (:trade s))
              (exit-price (:exit-price s))
              (entry-rate (:entry-rate trade))
              ;; Derive direction from price movement
              (direction (if (> exit-price entry-rate) :up :down))
              ;; Compute optimal distances from price history
              (optimal (compute-optimal-distances (:price-history trade) direction))
              ;; Route to the right post
              (post-idx (:post-idx trade))
              (p (nth (:posts ent) post-idx))
              (logs (post-propagate p
                      (:broker-slot-idx trade)
                      (:composed-thought s)
                      (:outcome s)
                      (:amount s)
                      direction
                      optimal)))
          (set! prop-logs (append prop-logs logs))))
        settlements)
      (append settle-logs prop-logs))))

;; ── step-compute-dispatch — Step 2 ───────────────────────────────────
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
(define (step-compute-dispatch [ent : Enterprise]
                               [post-idx : usize]
                               [raw : RawCandle]
                               [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let ((p (nth (:posts ent) post-idx))
        ((proposals market-thoughts misses) (post-on-candle p raw ctx)))
    ;; Cache market thoughts for step 3c
    (set! (:market-thoughts-cache ent) post-idx market-thoughts)
    ;; Submit proposals to treasury
    (for-each (lambda (prop) (submit-proposal (:treasury ent) prop))
      proposals)
    (list proposals market-thoughts misses)))

;; ── step-tick — Step 3a: parallel tick of papers ─────────────────────
;; Returns: (Vec<Resolution>, Vec<LogEntry>)
(define (step-tick [ent : Enterprise]
                   [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((p (nth (:posts ent) post-idx))
        (price (current-price p))
        (all-resolutions '())
        (all-logs '()))
    ;; Parallel: each broker ticks its own papers (disjoint slots)
    (pfor-each (lambda (brk)
      (let (((resolutions logs) (tick-papers brk price)))
        (set! all-resolutions (append all-resolutions resolutions))
        (set! all-logs (append all-logs logs))))
      (:registry p))
    (list all-resolutions all-logs)))

;; ── step-propagate — Step 3b: apply paper resolutions ────────────────
;; Sequential: observers are shared.
;; Returns: Vec<LogEntry>
(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let ((p (nth (:posts ent) post-idx))
        (all-logs '()))
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

;; ── step-update-triggers — Step 3c: update trade stop levels ─────────
;; Returns: Vec<(ThoughtAST, Vector)> — cache misses
(define (step-update-triggers [ent : Enterprise]
                              [post-idx : usize]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let ((p (nth (:posts ent) post-idx))
        ;; Query active trades for this post
        (trades (trades-for-post (:treasury ent) post-idx))
        ;; Post computes new levels
        ((updates misses) (post-update-triggers p trades market-thoughts ctx)))
    ;; Write level updates back to treasury
    (for-each (lambda (upd)
      (let (((trade-id new-levels) upd))
        (update-trade-stops (:treasury ent) trade-id new-levels)))
      updates)
    misses))

;; ── step-collect-fund — Step 4: treasury funds or rejects ────────────
;; Returns: Vec<LogEntry>
(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))

;; ── on-candle — the four-step loop ───────────────────────────────────
;; Route to the right post, then four steps.
;; Returns: (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
(define (on-candle [ent : Enterprise]
                   [raw : RawCandle]
                   [ctx : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
  (let ((all-logs '())
        (all-misses '()))
    ;; Find the right post
    (match (find-post ent raw)
      ((Some post-idx)
        ;; Step 1: RESOLVE + PROPAGATE
        (let ((resolve-logs (step-resolve-and-propagate ent)))
          (set! all-logs (append all-logs resolve-logs)))
        ;; Step 2: COMPUTE + DISPATCH
        (let (((proposals market-thoughts misses)
                (step-compute-dispatch ent post-idx raw ctx)))
          (set! all-misses (append all-misses misses)))
        ;; Step 3a: TICK (parallel papers)
        (let (((resolutions tick-logs) (step-tick ent post-idx)))
          (set! all-logs (append all-logs tick-logs))
          ;; Step 3b: PROPAGATE (sequential — paper resolutions)
          (let ((prop-logs (step-propagate ent post-idx resolutions)))
            (set! all-logs (append all-logs prop-logs))))
        ;; Step 3c: UPDATE TRIGGERS
        (let ((cached-thoughts (nth (:market-thoughts-cache ent) post-idx))
              (trigger-misses (step-update-triggers ent post-idx cached-thoughts ctx)))
          (set! all-misses (append all-misses trigger-misses)))
        ;; Step 4: COLLECT + FUND
        (let ((fund-logs (step-collect-fund ent)))
          (set! all-logs (append all-logs fund-logs))))
      (None
        ;; No post for this asset pair — ignore
        (begin)))
    (list all-logs all-misses)))
