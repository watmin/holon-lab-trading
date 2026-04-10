;; post.wat — Post struct + interface
;; Depends on: everything above
;; A self-contained unit for one asset pair.

(require primitives)
(require enums)
(require distances)
(require raw-candle)
(require candle)
(require indicator-bank)
(require window-sampler)
(require market-observer)
(require exit-observer)
(require broker)
(require proposal)
(require trade)
(require log-entry)
(require thought-encoder)
(require ctx)
(require simulation)

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
  [market-observers : Vec<MarketObserver>]   ; [N]
  [exit-observers : Vec<ExitObserver>]       ; [M]
  ;; Accountability
  [registry : Vec<Broker>]                   ; N×M brokers
  ;; Counter
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
  (post post-idx source target indicator-bank (deque)
    max-window-size market-observers exit-observers registry 0))

;; Current price: close of the last candle
(define (current-price [p : Post])
  : f64
  (if (empty? (:candle-window p))
    0.0
    (:close (last (:candle-window p)))))

;; The main per-candle entry point for a post
;; Returns (Post, Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
(define (post-on-candle [p : Post] [rc : RawCandle] [c : Ctx])
  : (Post Vec<Proposal> Vec<Vector> Vec<(ThoughtAST, Vector)>)
  (let (;; Step: tick indicators
        ((enriched new-bank) (tick (:indicator-bank p) rc))
        ;; Push to window
        (new-window (let ((w (push-back (:candle-window p) enriched)))
                      (if (> (len w) (:max-window-size p))
                        (second (pop-front w))
                        w)))
        (new-count (+ (:encode-count p) 1))

        ;; Step: market observers observe-candle
        ;; Each returns (updated-obs, thought, prediction, edge, misses)
        (market-results
          (pmap (lambda (obs)
                  (let ((win-size (sample (:window-sampler obs) new-count))
                        (window-slice (last-n (rb-to-list new-window)
                                       (min win-size (len new-window)))))
                    (observe-candle obs window-slice c)))
                (:market-observers p)))

        (updated-market-obs (map first market-results))
        (market-thoughts (map second market-results))
        (market-predictions (map (lambda (r) (nth r 2)) market-results))
        (market-edges (map (lambda (r) (nth r 3)) market-results))
        (market-misses (apply append (map (lambda (r) (nth r 4)) market-results)))

        ;; N market × M exit → N×M proposals via map-and-collect
        (n (length updated-market-obs))
        (m (length (:exit-observers p)))
        (grid-results
          (map (lambda (slot-idx)
                 (let ((mi (/ slot-idx m))
                       (ei (mod slot-idx m))
                       (market-thought (nth market-thoughts mi))
                       (market-pred (nth market-predictions mi))
                       (market-edge-val (nth market-edges mi))
                       (exit-obs (nth (:exit-observers p) ei))
                       (broker-ref (nth (:registry p) slot-idx))

                       ;; Exit: encode facts and compose with market thought
                       (exit-fact-asts (encode-exit-facts exit-obs enriched))
                       ((composed exit-misses)
                         (evaluate-and-compose exit-obs market-thought exit-fact-asts c))

                       ;; Exit: recommend distances
                       ((dists exit-exp)
                         (recommended-distances exit-obs composed
                           (:scalar-accums broker-ref)))

                       ;; Broker: propose Grace/Violence
                       ((updated-broker broker-pred) (propose broker-ref composed))

                       ;; Derive side from market prediction
                       (side-val (match market-pred
                                   ((Discrete scores conv)
                                     (let ((up-score (fold (lambda (best pair)
                                                      (if (= (first pair) "Up") (second pair) best))
                                                    0.0 scores))
                                           (down-score (fold (lambda (best pair)
                                                        (if (= (first pair) "Down") (second pair) best))
                                                      0.0 scores)))
                                       (if (>= up-score down-score) :buy :sell)))
                                   (_ :buy)))

                       ;; Broker edge
                       (edge-val (broker-edge updated-broker))

                       ;; Assemble proposal
                       (prop (make-proposal composed dists edge-val side-val
                               (:source-asset p) (:target-asset p)
                               (:post-idx p) slot-idx))

                       ;; Register paper
                       (broker-with-paper
                         (register-paper updated-broker composed
                           (current-price p) dists)))

                  (list prop broker-with-paper exit-misses)))
               (range 0 (* n m))))

        ;; Unzip results
        (proposals (map first grid-results))
        (updated-brokers (map second grid-results))
        (exit-misses-all (apply append (map (lambda (r) (nth r 2)) grid-results)))

        ;; Combine all cache misses
        (all-misses (append market-misses exit-misses-all))

        ;; Updated post
        (updated-post (update p
                        :indicator-bank new-bank
                        :candle-window new-window
                        :market-observers updated-market-obs
                        :registry updated-brokers
                        :encode-count new-count)))

    (list updated-post proposals market-thoughts all-misses)))

;; Update triggers: re-query exit observers for fresh distances on active trades
;; Returns (Vec<(TradeId, Levels)>, Vec<misses>)
(define (post-update-triggers [p : Post]
                               [trades : Vec<(TradeId, Trade)>]
                               [market-thoughts : Vec<Vector>]
                               [c : Ctx])
  : (Vec<(TradeId, Levels)> Vec<(ThoughtAST, Vector)>)
  (let ((m (length (:exit-observers p)))
        (enriched (if (empty? (:candle-window p)) None
                    (Some (last (:candle-window p))))))
    (match enriched
      (None (list '() '()))
      ((Some candle)
        (let ((results
                (map (lambda (trade-pair)
                       (let (((tid t) trade-pair)
                             (slot (:broker-slot-idx t))
                             (mi (/ slot m))
                             (ei (mod slot m))
                             (market-thought (nth market-thoughts mi))
                             (exit-obs (nth (:exit-observers p) ei))
                             (broker-ref (nth (:registry p) slot))
                             ;; Compose fresh
                             (exit-fact-asts (encode-exit-facts exit-obs candle))
                             ((composed misses)
                               (evaluate-and-compose exit-obs market-thought
                                 exit-fact-asts c))
                             ;; Get fresh distances
                             ((dists exp)
                               (recommended-distances exit-obs composed
                                 (:scalar-accums broker-ref)))
                             ;; Convert to levels
                             (price (current-price p))
                             (lvls (distances-to-levels dists price (:side t))))
                         (list (list tid lvls) misses)))
                     trades)))
          (list (map first results)
                (apply append (map second results))))))))

;; Propagate a resolved outcome to the right observers
(define (post-propagate [p : Post]
                         [slot-idx : usize]
                         [thought : Vector]
                         [outcome : Outcome]
                         [weight : f64]
                         [direction : Direction]
                         [optimal : Distances])
  : (Post Vec<LogEntry>)
  (let ((broker-ref (nth (:registry p) slot-idx))
        ;; Broker propagate — returns (updated-broker, logs, propagation-facts)
        ((updated-broker logs facts)
          (broker-propagate broker-ref thought outcome weight direction optimal))
        ;; Apply propagation facts to observers
        (mi (:market-idx facts))
        (ei (:exit-idx facts))
        (updated-market (resolve-market-observer
                          (nth (:market-observers p) mi)
                          (:composed-thought facts)
                          (:direction facts)
                          (:weight facts)))
        (updated-exit (observe-distances
                        (nth (:exit-observers p) ei)
                        (:composed-thought facts)
                        (:optimal facts)
                        (:weight facts)))
        ;; Update post
        (new-market-obs (map (lambda (pair)
                          (let (((i obs) pair))
                            (if (= i mi) updated-market obs)))
                        (map (lambda (i) (list i (nth (:market-observers p) i)))
                             (range 0 (length (:market-observers p))))))
        (new-exit-obs (map (lambda (pair)
                        (let (((i obs) pair))
                          (if (= i ei) updated-exit obs)))
                      (map (lambda (i) (list i (nth (:exit-observers p) i)))
                           (range 0 (length (:exit-observers p))))))
        (new-registry (map (lambda (pair)
                        (let (((i b) pair))
                          (if (= i slot-idx) updated-broker b)))
                      (map (lambda (i) (list i (nth (:registry p) i)))
                           (range 0 (length (:registry p)))))))
    (list (update p
            :market-observers new-market-obs
            :exit-observers new-exit-obs
            :registry new-registry)
          logs)))
