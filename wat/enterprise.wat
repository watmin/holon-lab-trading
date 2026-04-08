; enterprise.wat — the coordination plane. The CSP sync point.
;
; Depends on: Post, Treasury, TreasurySettlement, Settlement,
;             Direction, Outcome, Distances, LogEntry, TradeOrigin,
;             ThoughtAST, ThoughtEncoder.
;
; The enterprise is the only entity that sees the whole picture.
; Every other entity is an independent process. The enterprise
; holds posts and a treasury. It routes raw candles to the right
; post. It coordinates the four-step loop.
;
; The four steps per candle:
;   1. RESOLVE + PROPAGATE — settle triggered trades, teach observers
;   2. COMPUTE + DISPATCH  — encode, compose, propose
;   3a. TICK               — parallel paper ticks
;   3b. PROPAGATE          — sequential paper resolution fan-out
;   3c. UPDATE TRIGGERS    — fresh stop levels for active trades
;   4. COLLECT + FUND      — treasury evaluates and funds proposals

(require primitives)
(require enums)               ; Direction, Outcome
(require distances)           ; Distances
(require raw-candle)          ; RawCandle, Asset
(require log-entry)           ; LogEntry
(require settlement)          ; TreasurySettlement, Settlement
(require trade)               ; Trade
(require trade-origin)        ; TradeOrigin
(require post)                ; Post, post-on-candle, post-update-triggers,
                              ;   current-price, compute-optimal-distances,
                              ;   post-propagate
(require treasury)            ; Treasury, submit-proposal, fund-proposals,
                              ;   settle-triggered, update-trade-stops,
                              ;   trades-for-post
(require thought-encoder)     ; ThoughtAST, ThoughtEncoder
(require broker)              ; Resolution

;; ---- Struct ----------------------------------------------------------------

(struct enterprise
  ;; The posts — one per asset pair
  [posts : Vec<Post>]                  ; each watches one market
  ;; The treasury — shared across all posts
  [treasury : Treasury]                ; holds capital, funds trades, settles
  ;; Per-candle cache — produced in step 2, consumed in step 3c
  [market-thoughts-cache : Vec<Vec<Vector>>] ; one Vec<Vector> per post, cleared each candle
  ;; Cache miss-queues — observers queue (ThoughtAST, Vector) during parallel encoding
  ;; The enterprise drains between steps and inserts into ThoughtEncoder's LRU cache.
  [cache-miss-queues : Vec<Vec<(ThoughtAST, Vector)>>]
  ;; Logging — one queue per producer, drained each candle
  [log-queues : Vec<Vec<LogEntry>>])

;; ---- Constructor -----------------------------------------------------------

(define (make-enterprise [posts : Vec<Post>]
                         [treasury : Treasury])
  : Enterprise
  ;; Allocate per-post market-thoughts-cache, plus miss-queues for all observers
  (let* ((num-posts (len posts))
         (cache (map (lambda (_) (list)) (range num-posts)))
         ;; One miss-queue per observer across all posts: (N + M) per post
         (num-queues (fold (lambda (sum p)
                             (+ sum (len (:market-observers p))
                                    (len (:exit-observers p))))
                           0 posts))
         (miss-queues (map (lambda (_) (list)) (range num-queues)))
         ;; One log-queue per producer — brokers + treasury + posts
         (num-log-queues (fold (lambda (sum p)
                                 (+ sum (len (:registry p))))
                               0 posts))
         (log-qs (map (lambda (_) (list)) (range (+ num-log-queues 1)))))
    (make-enterprise
      posts
      treasury
      cache
      miss-queues
      log-qs)))

;; ---- on-candle — the four-step loop ----------------------------------------
;; Route to the right post, then four steps.
;; ctx flows in from the binary.

(define (on-candle [ent : Enterprise]
                   [raw : RawCandle]
                   [ctx : Ctx])
  ;; Find the post for this raw candle's asset pair
  (let* ((target-post-idx
           (fold (lambda (found idx)
                   (if (some? found) found
                       (let ((p (nth (:posts ent) idx)))
                         (if (and (= (:name (:source-asset raw))
                                     (:name (:source-asset p)))
                                  (= (:name (:target-asset raw))
                                     (:name (:target-asset p))))
                             (Some idx)
                             None))))
                 None
                 (range (len (:posts ent))))))

    (when-let ((post-idx (Some target-post-idx)))

      ;; ── Step 1: RESOLVE + PROPAGATE ──────────────────────────────
      (step-resolve-and-propagate ent)

      ;; ── Step 2: COMPUTE + DISPATCH ───────────────────────────────
      (let* ((result (step-compute-dispatch ent post-idx raw ctx))
             (proposals (first result))
             (market-thoughts (second result)))

        ;; Cache market thoughts for step 3c
        (set! (nth (:market-thoughts-cache ent) post-idx) market-thoughts)

        ;; ── Step 3a: TICK (parallel) ───────────────────────────────
        (let ((resolutions (step-tick ent post-idx)))

          ;; ── Step 3b: PROPAGATE (sequential — paper resolutions) ──
          (step-propagate ent post-idx resolutions)

          ;; ── Step 3c: UPDATE TRIGGERS ─────────────────────────────
          (step-update-triggers ent post-idx market-thoughts ctx))

        ;; ── Step 4: COLLECT + FUND ─────────────────────────────────
        ;; Submit proposals to treasury
        (for-each (lambda (prop) (submit-proposal (:treasury ent) prop))
                  proposals)
        (step-collect-fund ent))

      ;; Drain cache miss-queues into ThoughtEncoder
      (drain-miss-queues ent ctx))))

;; ---- step-resolve-and-propagate --------------------------------------------
;; Step 1: settle triggered trades, enrich into Settlements, propagate.
;; No ctx needed — uses pre-existing vectors, no encoding.

(define (step-resolve-and-propagate [ent : Enterprise])
  ;; Collect current prices from all posts
  (let* ((current-prices
           (fold (lambda (m p)
                   (assoc m
                          (list (:source-asset p) (:target-asset p))
                          (current-price p)))
                 (map-of)
                 (:posts ent)))

         ;; Treasury settles triggered trades
         (treasury-settlements
           (settle-triggered (:treasury ent) current-prices)))

    ;; Enrich each TreasurySettlement into a Settlement and propagate
    (for-each
      (lambda (ts)
        (let* ((trade (:trade ts))
               ;; Derive direction from exit-price vs entry-rate
               (direction (if (> (:exit-price ts) (:entry-rate trade))
                              :up :down))
               ;; Replay trade's price-history for optimal-distances
               (optimal (compute-optimal-distances
                          (:price-history trade)
                          direction))
               ;; Build the full settlement
               (settlement (make-settlement ts direction optimal))
               ;; Route to the right post for propagation
               (p (nth (:posts ent) (:post-idx trade)))
               (slot-idx (:broker-slot-idx trade)))

          ;; Propagate through the post -> broker -> observers
          (post-propagate p
                          slot-idx
                          (:composed-thought ts)
                          (:outcome ts)
                          (:amount ts)
                          direction
                          optimal)))
      treasury-settlements)))

;; ---- step-compute-dispatch -------------------------------------------------
;; Step 2: the post encodes, composes, proposes.
;; Returns (Vec<Proposal>, Vec<Vector>).

(define (step-compute-dispatch [ent : Enterprise]
                                [post-idx : usize]
                                [raw : RawCandle]
                                [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>)
  ;; Delegate to the post's on-candle — encodes the candle,
  ;; composes market + exit thoughts, and collects broker proposals.
  (let* ((p (nth (:posts ent) post-idx))
         (miss-queues (slice-miss-queues ent post-idx)))
    (post-on-candle p raw miss-queues ctx)))

;; ---- step-tick -------------------------------------------------------------
;; Step 3a: parallel tick of all brokers' papers.

(define (step-tick [ent : Enterprise]
                   [post-idx : usize])
  : Vec<Resolution>
  (let* ((p (nth (:posts ent) post-idx))
         (price (current-price p)))
    ;; Parallel tick — each broker touches only its own papers
    (flatten
      (pmap (lambda (brkr) (tick-papers brkr price))
            (:registry p)))))

;; ---- step-propagate --------------------------------------------------------
;; Step 3b: sequential — apply paper resolutions to shared observers.

(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  (let ((p (nth (:posts ent) post-idx)))
    ;; Sequential — observers are shared, mutations must not race
    (for-each
      (lambda (res)
        (post-propagate p
                        (:broker-slot-idx res)
                        (:composed-thought res)
                        (:outcome res)
                        (:amount res)
                        (:direction res)
                        (:optimal-distances res)))
      resolutions)))

;; ---- step-update-triggers --------------------------------------------------
;; Step 3c: fresh stop levels for active trades.
;; Query treasury for trades belonging to this post. The post composes
;; fresh thoughts, queries exit observers, computes new levels.
;; The enterprise writes the new values back to the treasury.

(define (step-update-triggers [ent : Enterprise]
                               [post-idx : usize]
                               [market-thoughts : Vec<Vector>]
                               [ctx : Ctx])
  (let* ((p (nth (:posts ent) post-idx))
         (miss-queues (slice-miss-queues ent post-idx))
         (trade-pairs (trades-for-post (:treasury ent) post-idx))
         ;; Post computes new levels — returns Vec<(TradeId, Levels)>
         (updates (post-update-triggers p trade-pairs market-thoughts miss-queues ctx)))

    ;; Write new levels back to treasury
    (for-each
      (lambda (update)
        (update-trade-stops (:treasury ent) (first update) (second update)))
      updates)))

;; ---- step-collect-fund -----------------------------------------------------
;; Step 4: treasury evaluates proposals and funds proven ones.

(define (step-collect-fund [ent : Enterprise])
  (fund-proposals (:treasury ent)))

;; ---- slice-miss-queues -----------------------------------------------------
;; Return the slice of cache-miss-queues belonging to a given post.
;; Layout: (N market + M exit) per post, contiguous.

(define (slice-miss-queues [ent : Enterprise]
                           [post-idx : usize])
  : Vec<&Vec<(ThoughtAST, Vector)>>
  (let* ((offset (fold (lambda (sum idx)
                          (let ((p (nth (:posts ent) idx)))
                            (+ sum (len (:market-observers p))
                                   (len (:exit-observers p)))))
                        0
                        (range post-idx)))
         (p (nth (:posts ent) post-idx))
         (count (+ (len (:market-observers p))
                   (len (:exit-observers p)))))
    (subvec (:cache-miss-queues ent) offset (+ offset count))))

;; ---- drain-miss-queues -----------------------------------------------------
;; Drain all cache miss-queues into the ThoughtEncoder's LRU cache.
;; Called between steps — the sequential phase.

(define (drain-miss-queues [ent : Enterprise]
                           [ctx : Ctx])
  (for-each
    (lambda (queue)
      (for-each
        (lambda (entry)
          ;; entry is (ThoughtAST, Vector) — insert into cache
          ;; The ThoughtEncoder's cache uses interior mutability for this.
          (cache-insert (:thought-encoder ctx) (first entry) (second entry)))
        queue)
      ;; Clear the queue
      (set! queue (list)))
    (:cache-miss-queues ent)))

;; ---- drain-logs ------------------------------------------------------------
;; Drain all log-queues. Each producer's queue is emptied.
;; Returns the concatenated entries. Called at the candle boundary
;; by the binary — the enterprise produces logs, the binary decides
;; what to do with them (write to DB, print, discard).

(define (drain-logs [ent : Enterprise])
  : Vec<LogEntry>
  (let ((all-logs (flatten (:log-queues ent))))
    ;; Clear all queues
    (for-each (lambda (q) (set! q (list)))
              (:log-queues ent))
    all-logs))
