;; post.wat — Post struct + interface
;; Depends on: everything above

(require primitives)
(require enums)
(require raw-candle)
(require candle)
(require indicator-bank)
(require distances)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require trade)
(require log-entry)
(require thought-encoder)
(require ctx)

;; ── Post ───────────────────────────────────────────────────────────
;; A self-contained unit for one asset pair. The post is where the
;; thinking happens.

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
  (post post-idx source target indicator-bank
    (deque) max-window-size
    market-observers exit-observers registry 0))

;; ── current-price — the close of the last candle ───────────────────

(define (current-price [p : Post])
  : f64
  (if (empty? (:candle-window p))
    0.0
    (:close (last (:candle-window p)))))

;; ── direction-to-side — Up → :buy, Down → :sell ───────────────────

(define (direction-to-side [pred : Prediction])
  : Side
  (match pred
    ((Discrete scores conv)
      (let ((up-score (fold (lambda (best pair)
                        (if (= (first pair) "Up") (second pair) best))
                      0.0 scores))
            (down-score (fold (lambda (best pair)
                          (if (= (first pair) "Down") (second pair) best))
                        0.0 scores)))
        (if (>= up-score down-score) :buy :sell)))
    ((Continuous val exp) :buy)))

;; ── post-on-candle ─────────────────────────────────────────────────
;; Returns: (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
;; Proposals for the treasury, market-thoughts for step 3c, cache misses.

(define (post-on-candle [p : Post] [raw-candle : RawCandle] [c : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  ;; 1. Tick the indicator bank
  (let ((enriched (tick (:indicator-bank p) raw-candle)))

  ;; 2. Push to candle window (bounded)
  (push-back (:candle-window p) enriched)
  (when (> (length (:candle-window p)) (:max-window-size p))
    (pop-front (:candle-window p)))

  ;; Increment encode count
  (set! p :encode-count (+ (:encode-count p) 1))

  ;; 3. Market observers observe — parallel
  (let ((n (length (:market-observers p)))
        (m (length (:exit-observers p)))
        (all-misses '())
        ;; Each market observer produces (thought, prediction, edge, misses)
        (market-results
          (pmap (lambda (obs)
            (let ((window-size (sample (:window-sampler obs) (:encode-count p)))
                  (win-len (min window-size (length (:candle-window p))))
                  (candle-window (last-n (:candle-window p) win-len)))
              (observe-candle obs candle-window c)))
            (:market-observers p)))
        ;; Extract market thoughts and collect misses
        (market-thoughts (map first market-results))
        (market-predictions (map second market-results))
        (market-edges (map (lambda (r) (nth r 2)) market-results))
        (market-misses (apply append (map (lambda (r) (nth r 3)) market-results))))

  (set! all-misses (append all-misses market-misses))

  ;; 4. N×M composition — map-and-collect
  (let ((proposals-and-misses
          (map (lambda (mi)
            (let ((market-obs (nth (:market-observers p) mi))
                  (market-thought (nth market-thoughts mi))
                  (market-pred (nth market-predictions mi))
                  (market-edge (nth market-edges mi)))
              (map (lambda (ei)
                (let ((exit-obs (nth (:exit-observers p) ei))
                      (slot-idx (+ (* mi m) ei))
                      (broker (nth (:registry p) slot-idx))
                      ;; Exit observer encodes + composes
                      (exit-fact-asts (encode-exit-facts exit-obs enriched))
                      ((composed exit-misses)
                        (evaluate-and-compose exit-obs market-thought exit-fact-asts c))
                      ;; Exit observer recommends distances
                      ((dists exit-exp)
                        (recommended-distances exit-obs composed (:scalar-accums broker)))
                      ;; Broker proposes
                      (broker-pred (propose broker composed))
                      (edge (broker-edge broker))
                      ;; Derive side from market prediction
                      (side (direction-to-side market-pred))
                      ;; Assemble proposal
                      (prop (make-proposal composed broker-pred dists edge side
                              (:source-asset p) (:target-asset p)
                              (:post-idx p) slot-idx))
                      ;; Register paper
                      (entry-atr (:atr enriched)))
                  (register-paper broker composed (:close enriched) entry-atr dists)
                  (list prop exit-misses)))
                (range 0 m))))
            (range 0 n)))
        ;; Flatten the N×M grid
        (flat-results (apply append (apply append proposals-and-misses)))
        ;; Actually the structure is list of (prop, misses) per cell
        (flat-cells (apply append proposals-and-misses))
        (proposals (map first flat-cells))
        (cell-misses (apply append (map second flat-cells))))

  (set! all-misses (append all-misses cell-misses))

  (list proposals market-thoughts all-misses)))))

;; ── post-update-triggers ───────────────────────────────────────────
;; Returns: (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)

(define (post-update-triggers [p : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [c : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let ((updates '())
        (all-misses '())
        (m (length (:exit-observers p)))
        (price (current-price p))
        (enriched (if (empty? (:candle-window p)) None (Some (last (:candle-window p))))))
    (for-each (lambda (trade-pair)
      (let (((trade-id trd) trade-pair)
            (slot-idx (:broker-slot-idx trd))
            (market-idx (/ slot-idx m))
            (exit-idx (mod slot-idx m))
            (market-thought (nth market-thoughts market-idx))
            (exit-obs (nth (:exit-observers p) exit-idx))
            (broker (nth (:registry p) slot-idx)))
        ;; Re-compose with fresh exit facts
        (when-let ((candle enriched))
          (let ((exit-facts (encode-exit-facts exit-obs candle))
                ((composed misses) (evaluate-and-compose exit-obs market-thought exit-facts c))
                ((dists exp) (recommended-distances exit-obs composed (:scalar-accums broker)))
                (new-levels (distances-to-levels dists price (:side trd))))
            (set! all-misses (append all-misses misses))
            (set! updates (append updates (list (list trade-id new-levels))))))))
      trades)
    (list updates all-misses)))

;; ── post-propagate ─────────────────────────────────────────────────
;; Route outcomes to the right broker and observers.

(define (post-propagate [p : Post]
                        [slot-idx : usize]
                        [thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances])
  : Vec<LogEntry>
  (let ((m (length (:exit-observers p)))
        (broker (nth (:registry p) slot-idx))
        ;; Broker learns and returns propagation facts
        ((logs facts) (propagate broker thought outcome weight direction optimal))
        ;; Apply to market observer
        (market-idx (:market-idx facts))
        (exit-idx (:exit-idx facts))
        (market-obs (nth (:market-observers p) market-idx))
        (exit-obs (nth (:exit-observers p) exit-idx)))
    ;; Market observer learns direction
    (resolve market-obs (:composed-thought facts) (:direction facts) (:weight facts))
    ;; Exit observer learns optimal distances
    (observe-distances exit-obs (:composed-thought facts) (:optimal facts) (:weight facts))
    logs))
