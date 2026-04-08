; post.wat — a self-contained trading post for one asset pair.
;
; Depends on: IndicatorBank, MarketObserver, ExitObserver, Broker,
;             Proposal, Side, Direction, Distances, Levels,
;             ThoughtAST, LogEntry.
;
; The post is where the thinking happens. It owns the observers,
; the brokers, the indicator bank. It does NOT own proposals or
; trades — those belong to the treasury.
;
; Each post watches one market. No cross-talk between posts.
; The post proposes to the treasury. The treasury decides.
;
; Values up, not queues down. Every function that produces log entries
; or cache misses returns them in its return tuple.
;
; The four-step orchestration within a post:
;   post-on-candle (step 2) — tick indicators, encode, compose, propose
;   post-update-triggers (step 3c) — fresh distances for active trades
;   post-propagate (step 1/3b) — route outcomes to brokers -> observers

(require primitives)
(require enums)               ; Side, Direction, Outcome, Prediction
(require distances)           ; Distances, Levels
(require raw-candle)          ; RawCandle, Asset
(require candle)              ; Candle
(require indicator-bank)      ; IndicatorBank, tick
(require market-observer)     ; MarketObserver, observe-candle
(require exit-observer)       ; ExitObserver, encode-exit-facts, evaluate-and-compose,
                              ;   recommended-distances
(require broker)              ; Broker, propose, edge, register-paper, propagate, Resolution
(require proposal)            ; Proposal
(require log-entry)           ; LogEntry

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
;; Tick indicators -> push window -> market observers observe ->
;; exit observers compose -> brokers propose -> assemble proposals.
;;
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
;;   proposals for the treasury, market-thoughts for step 3c cache,
;;   AND all collected cache misses from encoding. Values up.

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
           (pmap (lambda (mi)
                   (let* ((obs (nth (:market-observers p) mi))
                          (window-size (sample (:window-sampler obs)
                                               (:encode-count p)))
                          (window (last-n (:candle-window p) window-size)))
                     ;; observe-candle returns (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
                     (observe-candle obs window ctx)))
                 (range (len (:market-observers p)))))

         ;; Extract market thoughts and collect all misses
         (market-thoughts (map first market-results))
         (all-misses (apply append (map (lambda (r) (nth r 3)) market-results)))

         ;; 4. For each (market-obs, exit-obs) pair — compose and propose
         (proposals (list))
         (n (len (:market-observers p)))
         (m (len (:exit-observers p))))

    ;; Iterate all N x M broker combinations
    (for-each
      (lambda (mi)
        (let* ((mkt-result (nth market-results mi))
               (mkt-thought (first mkt-result))
               (mkt-prediction (second mkt-result))
               (mkt-edge (nth mkt-result 2)))
          (for-each
            (lambda (ei)
              (let* ((exit-obs (nth (:exit-observers p) ei))
                     (slot-idx (+ (* mi m) ei))
                     (brkr (nth (:registry p) slot-idx))
                     ;; Exit observer encodes its own facts
                     (exit-asts (encode-exit-facts exit-obs candle))
                     ;; Compose: market thought + exit facts -> composed vector + misses
                     ((composed compose-misses)
                       (evaluate-and-compose exit-obs mkt-thought exit-asts ctx))
                     ;; Collect compose misses
                     (_ (set! all-misses (append all-misses compose-misses)))
                     ;; Exit observer recommends distances using the cascade
                     ((dists exit-exp)
                       (recommended-distances exit-obs composed
                                               (:scalar-accums brkr)))
                     ;; Broker predicts Grace/Violence from composed thought
                     (pred (propose brkr composed))
                     ;; Broker's edge measure
                     (brk-edge (edge brkr))
                     ;; Derive side from market observer's prediction
                     ;; Up -> :buy, Down -> :sell
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

                ;; Collect the proposal
                (push! proposals prop)))
            (range m))))
      (range n))

    (list proposals market-thoughts all-misses)))

;; ---- post-update-triggers --------------------------------------------------
;; Step 3c: update trailing stops for active trades.
;; The post composes fresh thoughts with exit observers for current distances,
;; then computes new levels from distance x price.
;;
;; Returns: (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
;;   level updates for the enterprise to write back to treasury,
;;   AND cache misses from exit observer composition.

(define (post-update-triggers [p : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let ((all-misses (list)))
    ;; For each active trade, re-compose and compute fresh distances
    (let ((updates
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
                       ;; Compose — returns (Vector, Vec<(ThoughtAST, Vector)>)
                       ((composed compose-misses)
                         (evaluate-and-compose exit-obs mkt-thought exit-asts ctx))
                       (_ (set! all-misses (append all-misses compose-misses)))
                       ;; Fresh distances from the cascade
                       ((dists exit-exp)
                         (recommended-distances exit-obs composed
                                                 (:scalar-accums brkr)))
                       ;; Convert distances to levels using current price
                       (price (current-price p))
                       (new-levels (match (:side trade)
                                     (:buy
                                       (make-levels
                                         (* price (- 1.0 (:trail dists)))      ; trail-stop
                                         (* price (- 1.0 (:stop dists)))       ; safety-stop
                                         (* price (+ 1.0 (:tp dists)))         ; take-profit
                                         (* price (- 1.0 (:runner-trail dists))))) ; runner-trail-stop
                                     (:sell
                                       (make-levels
                                         (* price (+ 1.0 (:trail dists)))
                                         (* price (+ 1.0 (:stop dists)))
                                         (* price (- 1.0 (:tp dists)))
                                         (* price (+ 1.0 (:runner-trail dists))))))))
                  (list trade-id new-levels)))
              trades)))
      (list updates all-misses))))

;; ---- current-price ---------------------------------------------------------
;; The close of the last candle in the post's candle-window.

(define (current-price [p : Post])
  : f64
  (:close (last (:candle-window p))))

;; ---- compute-optimal-distances ---------------------------------------------
;; FREE FUNCTION — not a Post method. Takes no self. Pure.
;; Sweep candidate values against the price-history. For each candidate,
;; simulate the trailing stop mechanics. The candidate that produces
;; the maximum residue IS the optimal distance.
;;
;; direction: Direction — :up or :down. Which way the price moved.

(define (compute-optimal-distances [price-history : Vec<f64>]
                                    [direction : Direction])
  : Distances
  (let* ((entry (first price-history))
         (prices (rest price-history))
         ;; Sweep trail distance
         (optimal-trail
           (best-distance prices entry direction
             (lambda (p e d dir)
               (simulate-trail p e d dir))))
         ;; Sweep stop distance
         (optimal-stop
           (best-distance prices entry direction
             (lambda (p e d dir)
               (simulate-stop p e d dir))))
         ;; Sweep take-profit distance
         (optimal-tp
           (best-distance prices entry direction
             (lambda (p e d dir)
               (simulate-tp p e d dir))))
         ;; Sweep runner trail distance
         (optimal-runner
           (best-distance prices entry direction
             (lambda (p e d dir)
               (simulate-runner-trail p e d dir)))))
    (make-distances optimal-trail optimal-stop optimal-tp optimal-runner)))

;; ---- best-distance — sweep helper ------------------------------------------
;; Try candidates from 0.002 to 0.10 in 50 steps. Return the distance
;; that maximizes the residue (simulated by the given function).

(define (best-distance [prices : Vec<f64>]
                        [entry : f64]
                        [direction : Direction]
                        [simulate-fn : Fn])
  : f64
  (let* ((steps 50)
         (min-d 0.002)
         (max-d 0.100)
         (step-size (/ (- max-d min-d) (- steps 1)))
         (candidates (map (lambda (i) (+ min-d (* i step-size)))
                          (range steps)))
         (results (map (lambda (d)
                         (list d (simulate-fn prices entry d direction)))
                       candidates)))
    ;; Pick the candidate with the highest residue
    (first (first (sort-by second > results)))))

;; ---- simulate-trail --------------------------------------------------------
;; Given a price series, entry, distance, and direction, simulate a
;; trailing stop and return the residue (profit or loss as fraction).

(define (simulate-trail [prices : Vec<f64>]
                         [entry : f64]
                         [distance : f64]
                         [direction : Direction])
  : f64
  (let* ((extreme entry)
         (exit-price
           (fold (lambda (result price)
                   (if (some? result)
                       result
                       (let* ((new-extreme
                                (match direction
                                  (:up   (max extreme price))
                                  (:down (min extreme price))))
                              (trail-level
                                (match direction
                                  (:up   (* new-extreme (- 1.0 distance)))
                                  (:down (* new-extreme (+ 1.0 distance)))))
                              (triggered
                                (match direction
                                  (:up   (<= price trail-level))
                                  (:down (>= price trail-level)))))
                         (set! extreme new-extreme)
                         (if triggered
                             (Some trail-level)
                             None))))
                 None
                 prices)))
    ;; Residue: how much gained or lost
    (let ((exit (match exit-price
                  ((Some p) p)
                  (None (last prices)))))
      (match direction
        (:up   (/ (- exit entry) entry))
        (:down (/ (- entry exit) entry))))))

;; ---- simulate-stop ---------------------------------------------------------
(define (simulate-stop [prices : Vec<f64>]
                        [entry : f64]
                        [distance : f64]
                        [direction : Direction])
  : f64
  (let* ((stop-level (match direction
                       (:up   (* entry (- 1.0 distance)))
                       (:down (* entry (+ 1.0 distance)))))
         (hit (some? (filter (lambda (p)
                               (match direction
                                 (:up   (<= p stop-level))
                                 (:down (>= p stop-level))))
                             prices))))
    (if hit
        (- distance)   ; loss = negative residue
        ;; Never hit — use final price
        (match direction
          (:up   (/ (- (last prices) entry) entry))
          (:down (/ (- entry (last prices)) entry))))))

;; ---- simulate-tp -----------------------------------------------------------
(define (simulate-tp [prices : Vec<f64>]
                      [entry : f64]
                      [distance : f64]
                      [direction : Direction])
  : f64
  (let* ((tp-level (match direction
                     (:up   (* entry (+ 1.0 distance)))
                     (:down (* entry (- 1.0 distance)))))
         (hit (some? (filter (lambda (p)
                               (match direction
                                 (:up   (>= p tp-level))
                                 (:down (<= p tp-level))))
                             prices))))
    (if hit distance
        ;; Never hit — use final price
        (match direction
          (:up   (/ (- (last prices) entry) entry))
          (:down (/ (- entry (last prices)) entry))))))

;; ---- simulate-runner-trail -------------------------------------------------
(define (simulate-runner-trail [prices : Vec<f64>]
                                [entry : f64]
                                [distance : f64]
                                [direction : Direction])
  : f64
  ;; Runner trail is the same mechanics as trail but wider.
  ;; The optimal runner distance maximizes residue beyond principal recovery.
  (simulate-trail prices entry distance direction))

;; ---- post-propagate --------------------------------------------------------
;; Route a resolved outcome to the right broker. The broker fans out
;; to its market observer and exit observer.
;; Returns Vec<LogEntry> — values up.

(define (post-propagate [p : Post]
                        [slot-idx : usize]
                        [composed-thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let ((brkr (nth (:registry p) slot-idx)))
    (propagate brkr composed-thought outcome weight direction optimal
               (:market-observers p)
               (:exit-observers p))))
