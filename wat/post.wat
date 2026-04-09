;; post.wat — Post struct + interface
;; Depends on: everything above (indicators, observers, brokers, etc.)

(require primitives)
(require raw-candle)
(require candle)
(require enums)
(require distances)
(require newtypes)
(require indicator-bank)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require trade)
(require log-entry)
(require thought-encoder)
(require ctx)
(require simulation)

;; ── Post — a self-contained unit for one asset pair ───────────────────
(struct post
  [post-idx : usize]
  [source-asset : Asset]
  [target-asset : Asset]
  [indicator-bank : IndicatorBank]
  [candle-window : VecDeque<Candle>]
  [max-window-size : usize]
  [market-observers : Vec<MarketObserver>]
  [exit-observers : Vec<ExitObserver>]
  [registry : Vec<Broker>]
  [encode-count : usize])

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
    post-idx source target
    indicator-bank
    (deque)            ; candle-window — empty
    max-window-size
    market-observers
    exit-observers
    registry
    0))                ; encode-count

;; ── current-price — the close of the last candle ──────────────────────
(define (current-price [p : Post])
  : f64
  (if (empty? (:candle-window p))
    0.0
    (:close (last (:candle-window p)))))

;; ── post-on-candle — the compute+dispatch step ───────────────────────
;; Returns: proposals, market-thoughts, cache misses.
(define (post-on-candle [p : Post]
                        [raw : RawCandle]
                        [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  ;; 1. Tick indicators → enriched candle
  (let ((enriched (tick (:indicator-bank p) raw)))
    ;; 2. Push to candle window (bounded)
    (push-back (:candle-window p) enriched)
    (when (> (len (:candle-window p)) (:max-window-size p))
      (pop-front (:candle-window p)))
    ;; 3. Market observers observe
    (let ((n (length (:market-observers p)))
          (m (length (:exit-observers p)))
          (encode-count (:encode-count p))
          (all-misses '())
          (market-thoughts '())
          (market-predictions '())
          (market-edges '()))
      ;; Parallel: each market observer encodes and predicts
      (pfor-each (lambda (i)
        (let ((obs (nth (:market-observers p) i))
              ;; Sample window size
              (win-size (sample (:window-sampler obs) encode-count))
              ;; Slice the candle window
              (window-len (min win-size (len (:candle-window p))))
              (candle-window (last-n window-len (:candle-window p)))
              ;; Observe
              ((thought pred obs-edge misses) (observe-candle obs candle-window ctx)))
          (set! market-thoughts (append market-thoughts (list thought)))
          (set! market-predictions (append market-predictions (list pred)))
          (set! market-edges (append market-edges (list obs-edge)))
          (set! all-misses (append all-misses misses))))
        (range 0 n))
      ;; 4. For each (market, exit) pair: compose, propose, register paper
      (let ((proposals '()))
        (for-each (lambda (mi)
          (let ((market-thought (nth market-thoughts mi))
                (market-pred (nth market-predictions mi))
                (market-edge-val (nth market-edges mi)))
            (for-each (lambda (ei)
              (let ((exit-obs (nth (:exit-observers p) ei))
                    (slot-idx (+ (* mi m) ei))
                    (brk (nth (:registry p) slot-idx))
                    ;; Get exit facts for this candle
                    (exit-fact-asts (encode-exit-facts exit-obs enriched))
                    ;; Evaluate and compose: market thought + exit facts
                    ((composed compose-misses)
                      (evaluate-and-compose exit-obs market-thought exit-fact-asts ctx)))
                (set! all-misses (append all-misses compose-misses))
                ;; Get recommended distances
                (let (((dists _exp)
                        (recommended-distances exit-obs composed (:scalar-accums brk)))
                      ;; Broker proposes (Grace/Violence prediction)
                      (broker-pred (propose brk composed))
                      ;; Broker's edge
                      (broker-edge (edge brk))
                      ;; Derive side from market prediction
                      (side (match market-pred
                              ((Discrete scores _)
                                (let ((up-score (fold-left (lambda (best s)
                                                  (if (= (first s) "Up") (second s) best))
                                                0.0 scores)))
                                  (if (>= up-score 0.0) :buy :sell)))
                              (_ :buy))))
                  ;; Assemble the proposal — 8 fields, NO prediction
                  (push! proposals
                    (proposal composed dists broker-edge side
                      (:source-asset p) (:target-asset p)
                      (:post-idx p) slot-idx))
                  ;; Register paper
                  (register-paper brk composed (current-price p) dists))))
              (range 0 m))))
          (range 0 n))
        ;; Increment encode count
        (inc! p :encode-count)
        (list proposals market-thoughts all-misses)))))

;; ── post-update-triggers — update stop levels for active trades ───────
;; Returns: (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
(define (post-update-triggers [p : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let ((updates '())
        (all-misses '())
        (m (length (:exit-observers p)))
        (price (current-price p))
        (enriched (last (:candle-window p))))
    (for-each (lambda (trade-pair)
      (let (((trade-id trade) trade-pair)
            (slot (:broker-slot-idx trade))
            (market-idx (/ slot m))
            (exit-idx (mod slot m)))
        ;; Get the market thought for this broker's market observer
        (when (< market-idx (length market-thoughts))
          (let ((market-thought (nth market-thoughts market-idx))
                (exit-obs (nth (:exit-observers p) exit-idx))
                ;; Compose fresh exit facts with market thought
                (exit-fact-asts (encode-exit-facts exit-obs enriched))
                ((composed misses)
                  (evaluate-and-compose exit-obs market-thought exit-fact-asts ctx))
                (brk (nth (:registry p) slot))
                ;; Get fresh distances
                ((_dists _exp)
                  (recommended-distances exit-obs composed (:scalar-accums brk)))
                ;; Convert to levels using current price and trade side
                (new-levels (distances-to-levels _dists price (:side trade))))
            (set! all-misses (append all-misses misses))
            (push! updates (list trade-id new-levels))))))
      trades)
    (list updates all-misses)))

;; ── post-propagate — route a settlement to the right broker + observers
;; Returns: Vec<LogEntry>
(define (post-propagate [p : Post]
                        [slot-idx : usize]
                        [thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let ((brk (nth (:registry p) slot-idx))
        ;; Broker learns and returns propagation facts
        ((log-entries facts)
          (propagate brk thought outcome weight direction optimal)))
    ;; Apply facts to observers
    ;; Market observer learns direction
    (let ((market-obs (nth (:market-observers p) (:market-idx facts))))
      (resolve market-obs (:composed-thought facts) (:direction facts) (:weight facts)))
    ;; Exit observer learns optimal distances
    (let ((exit-obs (nth (:exit-observers p) (:exit-idx facts))))
      (observe-distances exit-obs (:composed-thought facts) (:optimal facts) (:weight facts)))
    log-entries))
