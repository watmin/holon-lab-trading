; enterprise.wat — the coordination plane. The CSP sync point.
;
; Depends on: Post, Treasury, TreasurySettlement, Settlement,
;             Direction, Outcome, Distances, LogEntry,
;             ThoughtAST, ThoughtEncoder, Resolution.
;
; The enterprise is the only entity that sees the whole picture.
; Every other entity is an independent process. The enterprise
; holds posts and a treasury. It routes raw candles to the right
; post. It coordinates the four-step loop.
;
; THREE fields only. No queue fields. Log entries and cache misses
; are returned as values from each step — values up, not queues down.
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
(require post)                ; Post, post-on-candle, post-update-triggers,
                              ;   current-price, compute-optimal-distances,
                              ;   post-propagate
(require treasury)            ; Treasury, submit-proposal, fund-proposals,
                              ;   settle-triggered, update-trade-stops,
                              ;   trades-for-post
(require thought-encoder)     ; ThoughtAST, ThoughtEncoder
(require broker)              ; Resolution

;; ---- Struct ----------------------------------------------------------------
;; THREE fields. No queue fields. Log entries and cache misses are values.

(struct enterprise
  ;; The posts — one per asset pair
  [posts : Vec<Post>]                  ; each watches one market
  ;; The treasury — shared across all posts
  [treasury : Treasury]                ; holds capital, funds trades, settles
  ;; Per-candle cache — produced in step 2, consumed in step 3c
  [market-thoughts-cache : Vec<Vec<Vector>>]) ; one Vec<Vector> per post, cleared each candle

;; ---- Constructor -----------------------------------------------------------

(define (make-enterprise [posts : Vec<Post>]
                         [treasury : Treasury])
  : Enterprise
  (let ((num-posts (len posts)))
    (make-enterprise
      posts
      treasury
      (map (lambda (_) (list)) (range num-posts)))))  ; market-thoughts-cache

;; ---- on-candle — the four-step loop ----------------------------------------
;; Route to the right post, then four steps. ctx flows in from the binary.
;; Each step returns its log entries and cache misses as values. The
;; enterprise collects all cache misses from all steps and returns them
;; alongside the concatenated log entries.
;;
;; Returns: (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
;;   logs for the ledger, cache misses for the seam.

(define (on-candle [ent : Enterprise]
                   [raw : RawCandle]
                   [ctx : Ctx])
  : (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>)
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
                 (range (len (:posts ent)))))
         (all-logs (list))
         (all-misses (list)))

    (when-let ((post-idx (Some target-post-idx)))

      ;; ── Step 1: RESOLVE + PROPAGATE ──────────────────────────────
      (let ((step1-logs (step-resolve-and-propagate ent)))
        (set! all-logs (append all-logs step1-logs)))

      ;; ── Step 2: COMPUTE + DISPATCH ───────────────────────────────
      (let (((proposals market-thoughts step2-misses)
              (step-compute-dispatch ent post-idx raw ctx)))

        ;; Cache market thoughts for step 3c
        (set! (nth (:market-thoughts-cache ent) post-idx) market-thoughts)
        (set! all-misses (append all-misses step2-misses))

        ;; ── Step 3a: TICK (parallel) ───────────────────────────────
        (let (((resolutions step3a-logs) (step-tick ent post-idx)))
          (set! all-logs (append all-logs step3a-logs))

          ;; ── Step 3b: PROPAGATE (sequential — paper resolutions) ──
          (let ((step3b-logs (step-propagate ent post-idx resolutions)))
            (set! all-logs (append all-logs step3b-logs)))

          ;; ── Step 3c: UPDATE TRIGGERS ─────────────────────────────
          (let ((step3c-misses (step-update-triggers ent post-idx market-thoughts ctx)))
            (set! all-misses (append all-misses step3c-misses))))

        ;; ── Step 4: COLLECT + FUND ─────────────────────────────────
        ;; Submit proposals to treasury
        (for-each (lambda (prop) (submit-proposal (:treasury ent) prop))
                  proposals)
        (let ((step4-logs (step-collect-fund ent)))
          (set! all-logs (append all-logs step4-logs)))))

    (list all-logs all-misses)))

;; ---- step-resolve-and-propagate --------------------------------------------
;; Step 1: settle triggered trades, enrich into Settlements, propagate.
;; Returns Vec<LogEntry>. No ctx needed — uses pre-existing vectors, no encoding.
;; The enterprise collects current prices internally (calls current-price
;; on each post). Treasury settles triggered trades using those prices.
;; For each settlement: enterprise computes optimal-distances via
;; compute-optimal-distances (free function), then routes to the post
;; for propagation.

(define (step-resolve-and-propagate [ent : Enterprise])
  : Vec<LogEntry>
  ;; Collect current prices from all posts
  (let* ((current-prices
           (fold (lambda (m p)
                   (assoc m
                          (list (:source-asset p) (:target-asset p))
                          (current-price p)))
                 (map-of)
                 (:posts ent)))

         ;; Treasury settles triggered trades — returns (settlements, logs)
         ((treasury-settlements settle-logs)
           (settle-triggered (:treasury ent) current-prices))

         (propagate-logs (list)))

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
               ;; Route to the right post for propagation
               (p (nth (:posts ent) (:post-idx trade)))
               (slot-idx (:broker-slot-idx trade))
               ;; Propagate through the post -> broker -> observers
               (prop-logs (post-propagate p
                                          slot-idx
                                          (:composed-thought ts)
                                          (:outcome ts)
                                          (:amount ts)
                                          direction
                                          optimal)))
          (set! propagate-logs (append propagate-logs prop-logs))))
      treasury-settlements)

    (append settle-logs propagate-logs)))

;; ---- step-compute-dispatch -------------------------------------------------
;; Step 2: the post encodes, composes, proposes.
;; Returns (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>).

(define (step-compute-dispatch [ent : Enterprise]
                                [post-idx : usize]
                                [raw : RawCandle]
                                [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  ;; Delegate to the post's on-candle — encodes the candle,
  ;; composes market + exit thoughts, and collects broker proposals.
  ;; Returns proposals, market-thoughts, and cache misses as values.
  (let ((p (nth (:posts ent) post-idx)))
    (post-on-candle p raw ctx)))

;; ---- step-tick -------------------------------------------------------------
;; Step 3a: parallel tick of all brokers' papers.
;; Returns (Vec<Resolution>, Vec<LogEntry>).

(define (step-tick [ent : Enterprise]
                   [post-idx : usize])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let* ((p (nth (:posts ent) post-idx))
         (price (current-price p))
         ;; Parallel tick — each broker touches only its own papers
         (results (pmap (lambda (brkr) (tick-papers brkr price))
                        (:registry p)))
         ;; Unzip: collect all resolutions and all logs
         (all-resolutions (apply append (map first results)))
         (all-logs (apply append (map second results))))
    (list all-resolutions all-logs)))

;; ---- step-propagate --------------------------------------------------------
;; Step 3b: sequential — apply paper resolutions to shared observers.
;; Returns Vec<LogEntry>.

(define (step-propagate [ent : Enterprise]
                        [post-idx : usize]
                        [resolutions : Vec<Resolution>])
  : Vec<LogEntry>
  (let* ((p (nth (:posts ent) post-idx))
         (logs (list)))
    ;; Sequential — observers are shared, mutations must not race
    (for-each
      (lambda (res)
        (let ((prop-logs
                (post-propagate p
                                (:broker-slot-idx res)
                                (:composed-thought res)
                                (:outcome res)
                                (:amount res)
                                (:direction res)
                                (:optimal-distances res))))
          (set! logs (append logs prop-logs))))
      resolutions)
    logs))

;; ---- step-update-triggers --------------------------------------------------
;; Step 3c: fresh stop levels for active trades.
;; Query treasury for trades belonging to this post. The post composes
;; fresh thoughts, queries exit observers, computes new levels.
;; The enterprise writes the new values back to the treasury's trade records
;; and collects the misses.
;; Returns Vec<(ThoughtAST, Vector)> — cache misses.

(define (step-update-triggers [ent : Enterprise]
                               [post-idx : usize]
                               [market-thoughts : Vec<Vector>]
                               [ctx : Ctx])
  : Vec<(ThoughtAST, Vector)>
  (let* ((p (nth (:posts ent) post-idx))
         (trade-pairs (trades-for-post (:treasury ent) post-idx))
         ;; Post computes new levels and collects misses
         ;; Returns (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
         ((updates misses) (post-update-triggers p trade-pairs market-thoughts ctx)))

    ;; Write new levels back to treasury
    (for-each
      (lambda (update)
        (update-trade-stops (:treasury ent) (first update) (second update)))
      updates)

    misses))

;; ---- step-collect-fund -----------------------------------------------------
;; Step 4: treasury evaluates proposals and funds proven ones.
;; Returns Vec<LogEntry>.

(define (step-collect-fund [ent : Enterprise])
  : Vec<LogEntry>
  (fund-proposals (:treasury ent)))
