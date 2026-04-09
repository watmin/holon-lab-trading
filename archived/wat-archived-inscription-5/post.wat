;; post.wat — Post struct + interface
;; Depends on: everything above — indicator-bank, market-observer, exit-observer,
;;             broker, proposal, distances, enums, ctx, candle, raw-candle, log-entry
;; A self-contained unit for one asset pair. Where the thinking happens.

(require primitives)
(require raw-candle)
(require indicator-bank)
(require candle)
(require enums)
(require distances)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require log-entry)
(require ctx)
(require thought-encoder)
(require settlement)

(struct post
  ;; Identity
  [post-idx : usize]
  [source-asset : Asset]               ; e.g. USDC
  [target-asset : Asset]               ; e.g. WBTC
  ;; Data pipeline
  [indicator-bank : IndicatorBank]
  [candle-window : VecDeque<Candle>]   ; bounded history
  [max-window-size : usize]
  ;; Observers
  [market-observers : Vec<MarketObserver>]  ; [N]
  [exit-observers : Vec<ExitObserver>]      ; [M]
  ;; Accountability — brokers in a flat vec
  [registry : Vec<Broker>]
  ;; Counter
  [encode-count : usize])

(define (make-post [post-idx : usize] [source : Asset] [target : Asset]
                   [dims : usize] [recalib-interval : usize]
                   [max-window-size : usize]
                   [bank : IndicatorBank]
                   [market-obs : Vec<MarketObserver>]
                   [exit-obs : Vec<ExitObserver>]
                   [registry : Vec<Broker>])
  : Post
  (post post-idx source target bank (deque) max-window-size
        market-obs exit-obs registry 0))

;; Current price — the close of the last candle.
(define (current-price [p : Post])
  : f64
  (if (empty? (:candle-window p))
    0.0
    (:close (last (:candle-window p)))))

;; Derive Side from market observer's prediction.
;; Up → :buy, Down → :sell.
(define (side-from-prediction [pred : Prediction])
  : Side
  (match pred
    ((Discrete scores _)
      (let ((up-score (fold (lambda (best s)
                        (if (= (first s) "Up") (second s) best))
                      -2.0 scores))
            (dn-score (fold (lambda (best s)
                        (if (= (first s) "Down") (second s) best))
                      -2.0 scores)))
        (if (>= up-score dn-score) :buy :sell)))
    ((Continuous _ _) :buy)))  ; fallback

;; ── post-on-candle ─────────────────────────────────────────────────
;; The main entry point. Returns proposals, market-thoughts, cache misses.
;; Uses map-and-collect for the N×M grid.
(define (post-on-candle [p : Post] [raw : RawCandle] [c : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  ;; Step 1: tick indicators, push to window
  (let ((enriched (tick (:indicator-bank p) raw)))
    (push-back (:candle-window p) enriched)
    (when (> (len (:candle-window p)) (:max-window-size p))
      (pop-front (:candle-window p)))
    (inc! (:encode-count p))

    ;; Step 2: market observers observe-candle
    ;; Each returns (thought, prediction, edge, misses)
    (let ((candle-list (ring-to-list (:candle-window p)))  ; as Vec for slicing
          (market-results
            (map (lambda (obs)
              (let ((window-size (sample (:window-sampler obs) (:encode-count p)))
                    (win (last-n candle-list (min window-size (len candle-list)))))
                (observe-candle obs win c)))
              (:market-observers p)))
          ;; Extract market thoughts and misses
          (market-thoughts (map first market-results))
          (market-preds    (map second market-results))
          (market-edges    (map (lambda (r) (nth r 2)) market-results))
          (market-misses   (apply append (map (lambda (r) (nth r 3)) market-results))))

    ;; Step 3: for each (market, exit) pair — map-and-collect
    (let ((n (len (:market-observers p)))
          (m (len (:exit-observers p)))
          ;; Map the N×M grid — values, not mutation
          (grid-results
            (map (lambda (slot-idx)
              (let ((mi (/ slot-idx m))
                    (ei (mod slot-idx m))
                    (market-thought (nth market-thoughts mi))
                    (market-pred    (nth market-preds mi))
                    (market-edge-val (nth market-edges mi))
                    (exit-obs       (nth (:exit-observers p) ei))
                    (brok           (nth (:registry p) slot-idx)))
                ;; Exit observer: encode facts and compose with market thought
                (let ((exit-asts (encode-exit-facts exit-obs enriched))
                      ((composed comp-misses) (evaluate-and-compose exit-obs market-thought exit-asts c))
                      ;; Exit observer: recommended distances
                      ((dist exp-val) (recommended-distances exit-obs composed (:scalar-accums brok)))
                      ;; Broker: propose
                      (pred (propose brok composed))
                      (edge-val (edge brok))
                      ;; Derive side from market prediction
                      (side (side-from-prediction market-pred))
                      ;; Register paper
                      (_ (register-paper brok composed (current-price p) (:atr enriched) dist))
                      ;; Assemble proposal
                      (prop (make-proposal composed pred dist edge-val side
                              (:source-asset p) (:target-asset p)
                              (:post-idx p) slot-idx)))
                  (list prop comp-misses))))
              (range 0 (* n m))))

          ;; Unzip: proposals and misses
          (proposals    (map first grid-results))
          (grid-misses  (apply append (map second grid-results)))
          (all-misses   (append market-misses grid-misses)))

      (list proposals market-thoughts all-misses))))))

;; ── post-update-triggers ───────────────────────────────────────────
;; Step 3c: compose fresh thoughts, query exit observers for distances.
;; Returns: (Vec<(TradeId, Levels)>, Vec<misses>)
(define (post-update-triggers [p : Post] [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [c : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let ((m (len (:exit-observers p)))
        (enriched (last (:candle-window p)))
        (results
          (map (lambda (trade-pair)
            (let (((trade-id t) trade-pair)
                  (slot    (:broker-slot-idx t))
                  (mi      (/ slot m))
                  (ei      (mod slot m))
                  (mkt     (nth market-thoughts mi))
                  (exit-obs (nth (:exit-observers p) ei))
                  (brok    (nth (:registry p) slot))
                  ;; Fresh exit composition
                  (exit-asts (encode-exit-facts exit-obs enriched))
                  ((composed misses) (evaluate-and-compose exit-obs mkt exit-asts c))
                  ;; Fresh distances
                  ((dist _) (recommended-distances exit-obs composed (:scalar-accums brok)))
                  ;; Convert to levels
                  (lvls (distances-to-levels dist (current-price p) (:side t))))
              (list (list trade-id lvls) misses)))
            trades))
        (level-updates (map first results))
        (all-misses    (apply append (map second results))))
    (list level-updates all-misses)))

;; ── post-propagate ─────────────────────────────────────────────────
;; Route a settlement to the broker, then apply PropagationFacts to observers.
(define (post-propagate [p : Post] [slot-idx : usize]
                        [thought : Vector] [outcome : Outcome]
                        [weight : f64] [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let ((brok (nth (:registry p) slot-idx))
        ((logs facts) (propagate brok thought outcome weight direction optimal)))
    ;; Apply to market observer
    (resolve (nth (:market-observers p) (:market-idx facts))
             (:composed-thought facts) (:direction facts) (:weight facts))
    ;; Apply to exit observer
    (observe-distances (nth (:exit-observers p) (:exit-idx facts))
                       (:composed-thought facts) (:optimal facts) (:weight facts))
    logs))
