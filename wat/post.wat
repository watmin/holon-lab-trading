;; ── post.wat ────────────────────────────────────────────────────────
;;
;; The per-asset-pair unit. A self-contained trading post. Owns the
;; indicator bank, candle window, market observers, exit observers,
;; and the broker registry. Does NOT own proposals or trades — those
;; belong to the treasury.
;;
;; Each post watches one market. No cross-talk between posts.
;; Depends on: indicator-bank, candle, raw-candle, distances,
;;   enums, newtypes, proposal, log-entry, ctx.

(require indicator-bank)
(require candle)
(require raw-candle)
(require distances)
(require enums)
(require newtypes)
(require proposal)
(require log-entry)
(require ctx)

;; ── Struct ──────────────────────────────────────────────────────

(struct post
  ;; Identity
  [post-idx : usize]                   ; this post's index in the enterprise's posts vec
  [source-asset : Asset]               ; e.g. USDC
  [target-asset : Asset]               ; e.g. WBTC

  ;; Data pipeline
  [indicator-bank : IndicatorBank]     ; streaming indicators for this pair
  [candle-window : VecDeque<Candle>]   ; bounded history
  [max-window-size : usize]            ; capacity

  ;; Observers — both are learned, both are per-pair
  [market-observers : Vec<MarketObserver>]  ; [N]
  [exit-observers : Vec<ExitObserver>]      ; [M]

  ;; Accountability — brokers in a flat vec, parallel access
  [registry : Vec<Broker>]             ; one per observer set, pre-allocated

  ;; Counter
  [encode-count : usize])

;; ── Constructor ─────────────────────────────────────────────────

(define (make-post [post-idx : usize]
                   [source : Asset]
                   [target : Asset]
                   [dims : usize]
                   [recalib-interval : usize]
                   [max-window-size : usize]
                   [indicator-bank : IndicatorBank]
                   [market-observers : Vec<MarketObserver>]
                   [exit-observers : Vec<ExitObserver>]
                   [registry : Vec<Broker>])
  : Post
  (make-post post-idx source target
    indicator-bank (deque) max-window-size
    market-observers exit-observers registry
    0))

;; ── post-on-candle ──────────────────────────────────────────────
;; The N x M grid. Tick indicators, push window, market observers
;; observe, exit observers compose, brokers propose, register papers.
;; Returns proposals + market-thoughts + cache misses.

(define (post-on-candle [post : Post] [raw-candle : RawCandle] [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let* (;; Tick indicators → enriched candle
         (candle (tick (:indicator-bank post) raw-candle))
         ;; Push onto window, trim to capacity
         (_ (begin (push-back (:candle-window post) candle)
                   (when (> (len (:candle-window post)) (:max-window-size post))
                     (pop-front (:candle-window post)))))
         ;; Increment encode-count
         (_ (inc! (:encode-count post)))

         ;; Market observers observe-candle (parallel)
         ;; Each returns (thought, prediction, edge, misses)
         (market-results
           (pmap (lambda (obs)
                   (let ((window-size (sample (:window-sampler obs) (:encode-count post)))
                         (window (last-n (:candle-window post) window-size)))
                     (observe-candle obs window ctx)))
                 (:market-observers post)))

         ;; Extract market-thoughts and collect misses
         (market-thoughts (map first market-results))
         (market-predictions (map second market-results))
         (market-edges (map (lambda (r) (nth r 2)) market-results))
         (all-misses (apply append (map (lambda (r) (nth r 3)) market-results)))

         ;; N x M composition: for each market observer x exit observer pair
         (n (len (:market-observers post)))
         (m (len (:exit-observers post)))
         (grid-results
           (map (lambda (slot-idx)
                  (let* ((market-idx (/ slot-idx m))
                         (exit-idx (mod slot-idx m))
                         (market-thought (nth market-thoughts market-idx))
                         (market-pred (nth market-predictions market-idx))
                         (exit-obs (nth (:exit-observers post) exit-idx))
                         (broker (nth (:registry post) slot-idx))

                         ;; Exit observer: encode facts, compose with market thought
                         (exit-fact-asts (encode-exit-facts exit-obs candle))
                         ((composed compose-misses)
                           (evaluate-and-compose exit-obs market-thought exit-fact-asts ctx))

                         ;; Exit observer: recommended distances using broker's accums
                         ((distances experience)
                           (recommended-distances exit-obs composed (:scalar-accums broker)))

                         ;; Broker: propose (Grace/Violence prediction)
                         (prediction (propose broker composed))

                         ;; Derive side from market prediction
                         (side (match market-pred
                                 ((Discrete scores _)
                                   (let ((up-score (second (first (filter (lambda (s) (= (first s) "Up")) scores))))
                                         (down-score (second (first (filter (lambda (s) (= (first s) "Down")) scores)))))
                                     (if (>= up-score down-score) :buy :sell)))))

                    ;; Register paper on broker
                    (register-paper broker composed (current-price post) distances)

                    ;; Assemble proposal
                    (list (make-proposal composed distances
                            (edge broker) side
                            (:source-asset post) (:target-asset post)
                            prediction (:post-idx post) slot-idx)
                          compose-misses)))
                (range (* n m))))

         ;; Unzip proposals and misses from grid
         (proposals (map first grid-results))
         (grid-misses (apply append (map second grid-results)))
         (total-misses (append all-misses grid-misses)))

    (list proposals market-thoughts total-misses)))

;; ── post-tick ───────────────────────────────────────────────────
;; Parallel tick all brokers' papers. Returns resolutions + log entries.

(define (post-tick [post : Post])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let* ((price (current-price post))
         (results (pmap (lambda (broker)
                          (tick-papers broker price))
                        (:registry post)))
         (resolutions (apply append (map first results)))
         (logs (apply append (map second results))))
    (list resolutions logs)))

;; ── post-propagate ──────────────────────────────────────────────
;; Route a resolved outcome to the broker, then apply propagation
;; facts to observers. Values up, not effects down.

(define (post-propagate [post : Post]
                        [slot-idx : usize]
                        [thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let* ((broker (nth (:registry post) slot-idx))
         ((logs prop-facts)
           (propagate broker thought outcome weight direction optimal))
         ;; Apply propagation facts to observers
         (market-obs (nth (:market-observers post) (:market-idx prop-facts)))
         (_ (resolve market-obs
              (:composed-thought prop-facts)
              (:direction prop-facts)
              (:weight prop-facts)))
         (exit-obs (nth (:exit-observers post) (:exit-idx prop-facts)))
         (_ (observe-distances exit-obs
              (:composed-thought prop-facts)
              (:optimal prop-facts)
              (:weight prop-facts))))
    logs))

;; ── post-update-triggers ────────────────────────────────────────
;; Step 3c: re-query exit observers for fresh distances on active
;; trades. Returns level updates and cache misses as values.

(define (post-update-triggers [post : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let* ((m (len (:exit-observers post)))
         (results
           (map (lambda (trade-pair)
                  (let* (((trade-id trade) trade-pair)
                         (slot-idx (:broker-slot-idx trade))
                         (market-idx (/ slot-idx m))
                         (exit-idx (mod slot-idx m))
                         (market-thought (nth market-thoughts market-idx))
                         (exit-obs (nth (:exit-observers post) exit-idx))
                         (broker (nth (:registry post) slot-idx))

                         ;; Compose fresh thought with exit facts
                         (exit-fact-asts (encode-exit-facts exit-obs
                                          (last (:candle-window post))))
                         ((composed misses)
                           (evaluate-and-compose exit-obs market-thought exit-fact-asts ctx))

                         ;; Get fresh distances
                         ((distances _)
                           (recommended-distances exit-obs composed (:scalar-accums broker)))

                         ;; Convert to levels
                         (new-levels (distances-to-levels distances
                                       (current-price post) (:side trade))))
                    (list (list trade-id new-levels) misses)))
                trades))
         (level-updates (map first results))
         (all-misses (apply append (map second results))))
    (list level-updates all-misses)))

;; ── current-price ───────────────────────────────────────────────
;; The close of the last candle in the post's candle-window.

(define (current-price [post : Post])
  : f64
  (:close (last (:candle-window post))))
