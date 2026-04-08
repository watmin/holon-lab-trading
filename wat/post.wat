; post.wat — a self-contained trading post for one asset pair.
;
; Depends on: IndicatorBank, MarketObserver, ExitObserver, Broker,
;             Proposal, Side, Direction, Distances, Levels,
;             ThoughtAST, PropagationFacts, simulation.
;
; The post is where the thinking happens. It owns the observers,
; the brokers, the indicator bank. It does NOT own proposals or
; trades — those belong to the treasury.
;
; Each post watches one market. No cross-talk between posts.
;
; The N*M composition uses map-and-collect: map the grid producing
; (Proposal, misses) per cell, then unzip. Values, not places.
; No set!/push! inside for-each for proposals/misses.
;
; post-propagate calls broker.propagate to get PropagationFacts,
; then applies them to observers. distances-to-levels for level conversion.

(require primitives)
(require enums)               ; Side, Direction, Outcome, Prediction
(require distances)           ; Distances, Levels, distances-to-levels
(require raw-candle)          ; RawCandle, Asset
(require candle)              ; Candle
(require indicator-bank)      ; IndicatorBank, tick
(require market-observer)     ; MarketObserver, observe-candle, resolve
(require exit-observer)       ; ExitObserver, encode-exit-facts, evaluate-and-compose,
                              ;   recommended-distances, observe-distances
(require broker)              ; Broker, propose, edge, register-paper, propagate,
                              ;   PropagationFacts
(require proposal)            ; Proposal
(require simulation)          ; compute-optimal-distances

;; ---- Struct ----------------------------------------------------------------

(struct post
  ;; Identity
  [post-idx : usize]                   ; this post's index in the enterprise
  [source-asset : Asset]               ; e.g. USDC
  [target-asset : Asset]               ; e.g. WBTC
  ;; Data pipeline
  [indicator-bank : IndicatorBank]     ; streaming indicators for this pair
  [candle-window : VecDeque<Candle>]   ; bounded history
  [max-window-size : usize]            ; capacity
  ;; Observers
  [market-observers : Vec<MarketObserver>]  ; [N]
  [exit-observers : Vec<ExitObserver>]      ; [M]
  ;; Accountability
  [registry : Vec<Broker>]             ; one per observer set, pre-allocated
  ;; Counter
  [encode-count : usize])

;; ---- Constructor -----------------------------------------------------------

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
  (make-post
    post-idx source target
    indicator-bank
    (deque)                          ; candle-window — empty
    max-window-size
    market-observers
    exit-observers
    registry
    0))                              ; encode-count

;; ---- post-on-candle --------------------------------------------------------
;; Step 2: COMPUTE + DISPATCH.
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
;;   proposals for the treasury, market-thoughts for step 3c, AND all misses.
;; Uses map-and-collect for the N*M grid — no set!/push! for proposals.

(define (post-on-candle [p : Post]
                        [raw : RawCandle]
                        [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  ;; 1. Tick indicators -> enriched candle
  (let* ((candle (tick (:indicator-bank p) raw))
         (_ (begin
              ;; 2. Push candle into window (bounded)
              (when (>= (len (:candle-window p)) (:max-window-size p))
                (pop-front (:candle-window p)))
              (push-back (:candle-window p) candle)
              (inc! (:encode-count p))))

         ;; 3. Market observers observe in parallel
         ;; Each returns (thought, prediction, edge, misses)
         (market-results
           (pmap (lambda (obs)
                   (let* ((window-size (sample (:window-sampler obs)
                                               (:encode-count p)))
                          (window (last-n (:candle-window p) window-size)))
                     (observe-candle obs window ctx)))
                 (:market-observers p)))

         ;; Extract market thoughts and misses
         (market-thoughts (map first market-results))
         (market-misses (apply append (map (lambda (r) (nth r 3)) market-results)))

         ;; 4. Map the N*M grid: for each (market-obs, exit-obs) pair,
         ;; produce (Proposal, misses). Then unzip.
         (n (len (:market-observers p)))
         (m (len (:exit-observers p)))

         (grid-results
           (map (lambda (mi)
                  (let* ((mkt-result (nth market-results mi))
                         (mkt-thought (first mkt-result))
                         (mkt-prediction (second mkt-result))
                         (mkt-edge (nth mkt-result 2)))
                    (map (lambda (ei)
                           (let* ((exit-obs (nth (:exit-observers p) ei))
                                  (slot-idx (+ (* mi m) ei))
                                  (brkr (nth (:registry p) slot-idx))
                                  ;; Exit observer encodes its own facts
                                  (exit-asts (encode-exit-facts exit-obs candle))
                                  ;; Compose: market thought + exit facts -> composed vector
                                  ((composed exit-misses)
                                    (evaluate-and-compose exit-obs mkt-thought
                                                          exit-asts ctx))
                                  ;; Exit observer recommends distances using the cascade
                                  ((dists exit-exp)
                                    (recommended-distances exit-obs composed
                                                           (:scalar-accums brkr)))
                                  ;; Broker predicts Grace/Violence from composed thought
                                  (pred (propose brkr composed))
                                  ;; Broker's edge measure
                                  (brk-edge (edge brkr))
                                  ;; Derive side from market observer's prediction
                                  (side (match mkt-prediction
                                          ((Discrete scores conviction)
                                            (if (> (second (first scores))
                                                   (second (second scores)))
                                                :buy :sell))))
                                  ;; Assemble the proposal
                                  (prop (make-proposal composed pred dists brk-edge side
                                                       (:post-idx p) slot-idx)))

                             ;; Register a paper trade for learning
                             (register-paper brkr composed (:close candle) (:atr candle) dists)

                             ;; Return (proposal, misses) per cell
                             (list prop exit-misses)))
                         (range m))))
                (range n)))

         ;; Flatten the N*M grid and unzip
         (flat-results (apply append grid-results))
         ((proposals grid-misses) (unzip flat-results))
         (all-misses (append market-misses (apply append grid-misses))))

    (list proposals market-thoughts all-misses)))

;; ---- post-update-triggers --------------------------------------------------
;; Step 3c: update trailing stops for active trades.
;; Uses distances-to-levels for conversion.
;; Returns: (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)

(define (post-update-triggers [p : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let* ((results
           (map
             (lambda (trade-pair)
               (let* ((trade-id (first trade-pair))
                      (trade (second trade-pair))
                      (slot-idx (:broker-slot-idx trade))
                      (brkr (nth (:registry p) slot-idx))
                      ;; Derive observer indices from slot-idx
                      (m (len (:exit-observers p)))
                      (mkt-idx (/ slot-idx m))
                      (exit-idx (mod slot-idx m))
                      ;; The market thought for this candle
                      (mkt-thought (nth market-thoughts mkt-idx))
                      ;; Exit observer composes fresh
                      (exit-obs (nth (:exit-observers p) exit-idx))
                      (candle (last (:candle-window p)))
                      (exit-asts (encode-exit-facts exit-obs candle))
                      ((composed exit-misses)
                        (evaluate-and-compose exit-obs mkt-thought
                                              exit-asts ctx))
                      ;; Fresh distances from the cascade
                      ((dists _)
                        (recommended-distances exit-obs composed
                                               (:scalar-accums brkr)))
                      ;; Convert distances to levels using current price and side
                      (price (current-price p))
                      (new-levels (distances-to-levels dists price (:side trade))))
                 (list (list trade-id new-levels) exit-misses)))
             trades))
         ;; Unzip: Vec<((TradeId, Levels), misses)> -> (updates, all-misses)
         ((updates all-misses-nested) (unzip results))
         (all-misses (apply append all-misses-nested)))
    (list updates all-misses)))

;; ---- current-price ---------------------------------------------------------

(define (current-price [p : Post])
  : f64
  (:close (last (:candle-window p))))

;; ---- post-propagate --------------------------------------------------------
;; Route a resolved outcome to the right broker. The broker returns
;; PropagationFacts. The post applies them to its own observers.
;; Returns: Vec<LogEntry>

(define (post-propagate [p : Post]
                        [slot-idx : usize]
                        [composed-thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let* ((brkr (nth (:registry p) slot-idx))
         ;; Broker learns its own lessons, returns PropagationFacts
         ((logs facts) (propagate brkr composed-thought outcome weight
                                  direction optimal))
         ;; Apply facts to observers
         ;; Direction + thought + weight -> market observer via resolve
         (mkt-obs (nth (:market-observers p) (:market-idx facts)))
         (_ (resolve mkt-obs (:composed-thought facts)
                     (:direction facts) (:weight facts)))
         ;; Optimal + composed + weight -> exit observer via observe-distances
         (exit-obs (nth (:exit-observers p) (:exit-idx facts)))
         (_ (observe-distances exit-obs (:composed-thought facts)
                               (:optimal facts) (:weight facts))))
    logs))
