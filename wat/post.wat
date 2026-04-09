;; post.wat — Post struct + interface
;; Depends on: everything above

(require primitives)
(require raw-candle)
(require candle)
(require enums)
(require distances)
(require indicator-bank)
(require window-sampler)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require thought-encoder)
(require ctx)
(require log-entry)
(require settlement)
(require newtypes)
(require trade)

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
  [market-observers : Vec<MarketObserver>]
  [exit-observers : Vec<ExitObserver>]
  ;; Accountability
  [registry : Vec<Broker>]
  ;; Counter
  [encode-count : usize])

(define (make-post [post-idx : usize] [source : Asset] [target : Asset]
                   [dims : usize] [recalib-interval : usize]
                   [max-window-size : usize]
                   [indicator-bank : IndicatorBank]
                   [market-observers : Vec<MarketObserver>]
                   [exit-observers : Vec<ExitObserver>]
                   [registry : Vec<Broker>])
  : Post
  (post post-idx source target
        indicator-bank (deque) max-window-size
        market-observers exit-observers registry
        0))

;; The latest close price from the candle window.
(define (current-price [p : Post])
  : f64
  (if (empty? (:candle-window p))
    0.0
    (:close (last (:candle-window p)))))

;; Derive Side from a market observer's Discrete prediction.
(define (side-from-prediction [pred : Prediction])
  : Side
  (match pred
    ((Discrete scores conv)
      (let ((up-score (fold (lambda (best s)
                        (if (= (first s) "Up") (second s) best))
                      f64-neg-infinity scores))
            (down-score (fold (lambda (best s)
                        (if (= (first s) "Down") (second s) best))
                      f64-neg-infinity scores)))
        (if (>= up-score down-score) :buy :sell)))
    ((Continuous v e) :buy)))  ; shouldn't happen

;; Main per-candle processing.
;; Returns (proposals, market-thoughts, cache-misses).
(define (post-on-candle [p : Post] [raw : RawCandle] [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let (;; 1. Tick the indicator bank
        (enriched (tick (:indicator-bank p) raw))
        ;; 2. Push to candle window
        (_ (begin
             (push-back (:candle-window p) enriched)
             (when (> (len (:candle-window p)) (:max-window-size p))
               (pop-front (:candle-window p)))))
        ;; 3. Increment encode count
        (_ (inc! p :encode-count))
        (n (length (:market-observers p)))
        (m (length (:exit-observers p)))
        (all-misses '()))

    ;; 4. Market observers observe — parallel (par_iter safe, each reads own state)
    (let ((market-results
            (pmap (lambda (obs)
              (let ((ws (sample (:window-sampler obs) (:encode-count p)))
                    (window-size (min ws (len (:candle-window p))))
                    (candle-window (last-n (rb-to-list (:candle-window p)) window-size)))
                (observe-candle obs candle-window ctx)))
              (:market-observers p)))
          (market-thoughts (map first market-results))
          (market-preds (map second market-results))
          (market-edges (map (lambda (r) (nth r 2)) market-results))
          (market-misses (apply append (map (lambda (r) (nth r 3)) market-results))))

      ;; Collect market misses
      (set! all-misses (append all-misses market-misses))

      ;; 5. For each (market, exit) pair — compose, propose
      (let ((proposals '())
            (price (current-price p)))

        (for-each (lambda (mi)
          (let ((market-thought (nth market-thoughts mi))
                (market-pred (nth market-preds mi))
                (market-edge (nth market-edges mi)))
            (for-each (lambda (ei)
              (let ((exit-obs (nth (:exit-observers p) ei))
                    (broker-slot (+ (* mi m) ei))
                    (broker (nth (:registry p) broker-slot))
                    ;; Exit observer produces fact ASTs
                    (exit-asts (encode-exit-facts exit-obs enriched))
                    ;; Evaluate and compose with market thought
                    ((composed compose-misses)
                      (evaluate-and-compose exit-obs market-thought exit-asts ctx)))
                (set! all-misses (append all-misses compose-misses))

                ;; Exit observer recommends distances
                (let (((dists exit-exp)
                        (recommended-distances exit-obs composed (:scalar-accums broker)))
                      ;; Broker proposes — Grace/Violence prediction
                      (broker-pred (propose broker composed))
                      (broker-edge (edge broker))
                      ;; Side from market prediction
                      (side (side-from-prediction market-pred)))

                  ;; Register paper
                  (register-paper broker composed price (:atr enriched) dists)

                  ;; Build proposal
                  (push! proposals
                    (make-proposal composed broker-pred dists broker-edge side
                                   (:source-asset p) (:target-asset p)
                                   (:post-idx p) broker-slot)))))
              (range 0 m))))
          (range 0 n))

        (list proposals market-thoughts all-misses)))))

;; Update trigger levels for active trades.
;; Returns (Vec<(TradeId, Levels)>, Vec<misses>).
(define (post-update-triggers [p : Post] [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>] [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let ((updates '())
        (all-misses '())
        (m (length (:exit-observers p)))
        (price (current-price p))
        (enriched (last (:candle-window p))))
    (for-each (lambda (trade-pair)
      (let (((trade-id trade) trade-pair)
            (broker-slot (:broker-slot-idx trade))
            (market-idx (/ broker-slot m))
            (exit-idx (mod broker-slot m))
            (market-thought (nth market-thoughts market-idx))
            (exit-obs (nth (:exit-observers p) exit-idx))
            (broker (nth (:registry p) broker-slot))
            ;; Compose fresh thought
            (exit-asts (encode-exit-facts exit-obs enriched))
            ((composed misses)
              (evaluate-and-compose exit-obs market-thought exit-asts ctx)))
        (set! all-misses (append all-misses misses))
        ;; Get fresh distances
        (let (((dists exp)
                (recommended-distances exit-obs composed (:scalar-accums broker)))
              (new-levels (distances-to-levels dists price (:side trade))))
          (push! updates (list trade-id new-levels)))))
      trades)
    (list updates all-misses)))

;; Propagate a settlement back to the observers.
;; Returns Propagated log entries.
(define (post-propagate [p : Post] [slot-idx : usize]
                        [thought : Vector] [outcome : Outcome]
                        [weight : f64] [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let ((broker (nth (:registry p) slot-idx))
        (m (length (:exit-observers p)))
        ((logs prop-facts) (propagate broker thought outcome weight direction optimal))
        ;; Apply propagation facts to observers
        (market-idx (:market-idx prop-facts))
        (exit-idx (:exit-idx prop-facts))
        (market-obs (nth (:market-observers p) market-idx))
        (exit-obs (nth (:exit-observers p) exit-idx)))
    ;; Market observer learns direction
    (resolve market-obs (:composed-thought prop-facts)
             (:direction prop-facts) (:weight prop-facts))
    ;; Exit observer learns optimal distances
    (observe-distances exit-obs (:composed-thought prop-facts)
                       (:optimal prop-facts) (:weight prop-facts))
    logs))
