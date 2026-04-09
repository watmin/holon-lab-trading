;; post.wat — per-asset-pair trading unit
;;
;; Depends on: enums (Side, Direction, Outcome, MarketLens, Prediction),
;;             distances (Distances, Levels, distances-to-levels),
;;             market-observer, exit-observer, broker, proposal, trade,
;;             settlement, log-entry, indicator-bank, simulation, ctx, newtypes
;;
;; The post is where the thinking happens. It owns observers, brokers,
;; and the indicator bank. It does NOT own proposals or trades.
;; Uses map-and-collect for the N x M grid — values, not mutation.
;; Calls simulation.wat's compute-optimal-distances.
;; Calls distances.wat's distances-to-levels.

(require primitives)
(require enums)
(require newtypes)
(require distances)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require trade)
(require settlement)
(require log-entry)
(require indicator-bank)
(require simulation)
(require ctx)

(struct post
  ;; Identity
  [post-idx : usize]
  [source-asset : Asset]
  [target-asset : Asset]
  ;; Data pipeline
  [indicator-bank : IndicatorBank]
  [candle-window : VecDeque<Candle>]
  [max-window-size : usize]
  ;; Observers
  [market-observers : Vec<MarketObserver>]    ; [N]
  [exit-observers : Vec<ExitObserver>]        ; [M]
  ;; Accountability
  [registry : Vec<Broker>]                    ; one per (market, exit) pair
  ;; Counter
  [encode-count : usize])

;; ── Constructor ────────────────────────────────────────────────────

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
  (post
    post-idx
    source
    target
    indicator-bank
    (deque)                                        ; candle-window — empty
    max-window-size
    market-observers
    exit-observers
    registry
    0))                                            ; encode-count

;; ── post-on-candle ─────────────────────────────────────────────────
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
;; proposals for the treasury, market-thoughts for step 3c, cache misses.
;;
;; N x M composition uses map-and-collect: map the grid producing
;; (Proposal, misses) per cell, unzip.

(define (post-on-candle [post : Post]
                        [raw-candle : RawCandle]
                        [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let* (;; Step: tick indicators, produce enriched candle
         (candle (tick (:indicator-bank post) raw-candle))
         ;; Push to window, cap at max
         (_ (begin
              (push-back (:candle-window post) candle)
              (when (> (len (:candle-window post)) (:max-window-size post))
                (pop-front (:candle-window post)))))
         ;; Increment encode-count
         (_ (inc! (:encode-count post)))

         ;; Step: market observers observe (parallel)
         ;; Each returns (thought, prediction, edge, misses)
         (market-results
           (pmap (lambda (obs)
                   (let* ((window-size (sample (:window-sampler obs)
                                               (:encode-count post)))
                          (window-len (len (:candle-window post)))
                          (actual-size (min window-size window-len))
                          (candle-slice (last-n (:candle-window post)
                                                actual-size)))
                     (observe-candle obs candle-slice ctx)))
                 (:market-observers post)))
         (market-thoughts (map first market-results))
         (market-predictions (map second market-results))
         (market-edges (map (lambda (r) (nth r 2)) market-results))
         (market-misses (apply append (map (lambda (r) (nth r 3)) market-results)))

         ;; Step: N x M grid — map-and-collect
         ;; For each (market-idx, exit-idx) pair, produce (Proposal, misses)
         (n (len (:market-observers post)))
         (m (len (:exit-observers post)))
         (grid-results
           (map (lambda (slot-idx)
                  (let* ((market-idx (/ slot-idx m))
                         (exit-idx   (mod slot-idx m))
                         (market-thought (nth market-thoughts market-idx))
                         (market-pred    (nth market-predictions market-idx))
                         (market-edge-val (nth market-edges market-idx))
                         (exit-obs (nth (:exit-observers post) exit-idx))
                         (brkr     (nth (:registry post) slot-idx))

                         ;; Exit observer: encode facts, compose with market thought
                         (exit-fact-asts (encode-exit-facts exit-obs candle))
                         ((composed compose-misses)
                           (evaluate-and-compose exit-obs market-thought
                                                 exit-fact-asts ctx))

                         ;; Exit observer: recommended distances
                         ((dists exit-exp)
                           (recommended-distances exit-obs composed
                                                  (:scalar-accums brkr)))

                         ;; Broker: propose (Grace/Violence prediction)
                         (broker-pred (propose brkr composed))
                         (broker-edge-val (edge brkr))

                         ;; Register paper trade
                         (_ (register-paper brkr composed
                                            (:close candle)
                                            (:atr candle) dists))

                         ;; Derive side from market prediction
                         (side (match market-pred
                                 ((Discrete scores _)
                                   (let ((up-score (second (first (filter
                                                   (lambda (p) (= (first p) "Up"))
                                                   scores))))
                                         (down-score (second (first (filter
                                                     (lambda (p) (= (first p) "Down"))
                                                     scores)))))
                                     (if (>= up-score down-score) :buy :sell)))
                                 ((Continuous _ _) :buy)))

                         ;; Assemble Proposal
                         (prop (proposal composed broker-pred dists
                                         broker-edge-val side
                                         (:post-idx post)
                                         slot-idx)))
                    (list prop compose-misses)))
                (range (* n m))))

         ;; Unzip: proposals and misses
         (proposals (map first grid-results))
         (grid-misses (apply append (map second grid-results)))
         (all-misses (append market-misses grid-misses)))

    (list proposals market-thoughts all-misses)))

;; ── post-update-triggers ───────────────────────────────────────────
;; Returns: (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
;; Level updates and cache misses from exit observer composition.

(define (post-update-triggers [post : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let* ((candle (last (:candle-window post)))
         (price (:close candle))
         (m (len (:exit-observers post)))
         ;; For each trade, compose fresh thoughts, query exit observer for distances
         (results
           (map (lambda (trade-pair)
                  (let* ((trade-id (first trade-pair))
                         (trd (second trade-pair))
                         (slot-idx (:broker-slot-idx trd))
                         (market-idx (/ slot-idx m))
                         (exit-idx   (mod slot-idx m))
                         (market-thought (nth market-thoughts market-idx))
                         (exit-obs (nth (:exit-observers post) exit-idx))
                         (brkr (nth (:registry post) slot-idx))
                         ;; Compose fresh
                         (exit-fact-asts (encode-exit-facts exit-obs candle))
                         ((composed compose-misses)
                           (evaluate-and-compose exit-obs market-thought
                                                 exit-fact-asts ctx))
                         ;; Fresh distances
                         ((dists _)
                           (recommended-distances exit-obs composed
                                                  (:scalar-accums brkr)))
                         ;; Convert to levels
                         (new-levels (distances-to-levels dists price (:side trd))))
                    (list (list trade-id new-levels) compose-misses)))
                trades))
         (level-updates (map first results))
         (all-misses (apply append (map second results))))
    (list level-updates all-misses)))

;; ── current-price ──────────────────────────────────────────────────
;; The close of the last candle in the post's candle-window.

(define (current-price [post : Post])
  : f64
  (:close (last (:candle-window post))))

;; ── post-propagate ─────────────────────────────────────────────────
;; The enterprise routes a settlement back to the post.
;; Calls broker.propagate to get PropagationFacts, then applies them.
;; Returns Propagated log entries.

(define (post-propagate [post : Post]
                        [slot-idx : usize]
                        [thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let* ((brkr (nth (:registry post) slot-idx))
         ;; Broker learns and returns facts for observers
         ((broker-logs facts) (propagate brkr thought outcome weight
                                         direction optimal))
         ;; Apply facts to observers
         ;; Market observer learns direction
         (market-obs (nth (:market-observers post) (:market-idx facts)))
         (_ (resolve market-obs
                     (:composed-thought facts)
                     (:direction facts)
                     (:weight facts)))
         ;; Exit observer learns optimal distances
         (exit-obs (nth (:exit-observers post) (:exit-idx facts)))
         (_ (observe-distances exit-obs
                               (:composed-thought facts)
                               (:optimal facts)
                               (:weight facts))))
    broker-logs))
