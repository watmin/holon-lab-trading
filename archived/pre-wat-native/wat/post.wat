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
                   [indicator-bank : IndicatorBank]
                   [max-window-size : usize]
                   [market-observers : Vec<MarketObserver>]
                   [exit-observers : Vec<ExitObserver>]
                   [registry : Vec<Broker>])
  : Post
  (make-post post-idx source target
    indicator-bank (deque) max-window-size
    market-observers exit-observers registry
    0))

;; ── Free functions: vocab wiring ────────────────────────────────
;; These select which vocab modules each lens calls. NOT methods on
;; observers. The CRITICAL wiring — different lenses see different
;; market data.

(define (market-lens-facts [lens : MarketLens]
                           [candle : Candle]
                           [window : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((facts (encode-time-facts candle))
         (_ (extend! facts (encode-standard-facts window))))
    (match lens
      (Momentum
        (extend! facts (encode-oscillator-facts candle))
        (extend! facts (encode-momentum-facts candle))
        (extend! facts (encode-stochastic-facts candle)))
      (Structure
        (extend! facts (encode-keltner-facts candle))
        (extend! facts (encode-fibonacci-facts candle))
        (extend! facts (encode-ichimoku-facts candle))
        (extend! facts (encode-price-action-facts candle)))
      (Volume
        (extend! facts (encode-flow-facts candle)))
      (Narrative
        (extend! facts (encode-timeframe-facts candle))
        (extend! facts (encode-divergence-facts candle)))
      (Regime
        (extend! facts (encode-regime-facts candle))
        (extend! facts (encode-persistence-facts candle)))
      (Generalist
        ;; ALL modules
        (extend! facts (encode-oscillator-facts candle))
        (extend! facts (encode-momentum-facts candle))
        (extend! facts (encode-stochastic-facts candle))
        (extend! facts (encode-keltner-facts candle))
        (extend! facts (encode-fibonacci-facts candle))
        (extend! facts (encode-ichimoku-facts candle))
        (extend! facts (encode-price-action-facts candle))
        (extend! facts (encode-flow-facts candle))
        (extend! facts (encode-timeframe-facts candle))
        (extend! facts (encode-divergence-facts candle))
        (extend! facts (encode-regime-facts candle))
        (extend! facts (encode-persistence-facts candle))))
    facts))

(define (exit-lens-facts [lens : ExitLens]
                         [candle : Candle])
  : Vec<ThoughtAST>
  (match lens
    (Volatility (encode-exit-volatility-facts candle))
    (Structure (encode-exit-structure-facts candle))
    (Timing (encode-exit-timing-facts candle))
    (Generalist
      (let ((facts (encode-exit-volatility-facts candle)))
        (extend! facts (encode-exit-structure-facts candle))
        (extend! facts (encode-exit-timing-facts candle))
        facts))))

;; ── post-on-candle ──────────────────────────────────────────────
;; The N x M grid. Tick indicators, push window, market observers
;; encode via incremental bundles, exit observers pre-encode, then
;; the grid composes and proposes. Returns proposals + market-thoughts
;; + cache misses.

(define (post-on-candle [post : Post] [raw-candle : RawCandle] [ctx : Ctx])
  : (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>)
  (let* (;; Tick indicators -> enriched candle
         (candle (tick (:indicator-bank post) raw-candle))
         ;; Push onto window, trim to capacity
         (_ (begin (push-back (:candle-window post) candle)
                   (when (> (len (:candle-window post)) (:max-window-size post))
                     (pop-front (:candle-window post)))))
         ;; Increment encode-count
         (_ (inc! (:encode-count post)))

         ;; Snapshot window for parallel access
         (window (vec (:candle-window post)))

         ;; Market observers: par_iter_mut. Each computes its own lens
         ;; facts, encodes via incremental bundle, then observes.
         ;; Returns (thought, prediction, edge, misses).
         (market-results
           (par-iter-mut
             (lambda (obs)
               (let* ((facts (market-lens-facts (:lens obs) candle window))
                      ((thought misses)
                        (incremental-encode (:incremental obs) facts
                                            (:thought-encoder ctx)))
                      (result (observe obs thought (vec))))
                 (list (:thought result)
                       (:prediction result)
                       (:edge result)
                       misses)))
             (:market-observers post)))

         ;; Extract columns from market results
         (market-thoughts (map first market-results))
         (market-predictions (map second market-results))
         (market-edges (map (lambda (r) (nth r 2)) market-results))
         (all-misses (apply append (map (lambda (r) (nth r 3)) market-results)))

         ;; Pre-encode exit facts per exit observer (M, not N x M).
         ;; Each exit observer's incremental bundle maintains sums
         ;; across candles. The exit-vecs are shared across all N
         ;; market observers.
         (exit-results
           (par-iter-mut
             (lambda (eobs)
               (let ((exit-fact-asts (exit-lens-facts (:lens eobs) candle)))
                 (incremental-encode (:incremental eobs) exit-fact-asts
                                     (:thought-encoder ctx))))
             (:exit-observers post)))
         (exit-vecs (map first exit-results))
         (_ (for-each (lambda (r)
              (extend! all-misses (second r)))
            exit-results))

         ;; N market x M exit -> N*M proposals
         ;; Parallel phase: compute values. Sequential phase: apply mutations.
         (n (len (:market-observers post)))
         (m (len (:exit-observers post)))
         (price (current-price post))

         ;; pmap: each slot computes independently. Pure reads only.
         (grid-values
           (par-iter
             (lambda (slot-idx)
               (let* ((mi (/ slot-idx m))
                      (ei (mod slot-idx m))
                      (market-thought (nth market-thoughts mi))
                      (exit-vec (nth exit-vecs ei))

                      ;; Compose market thought with exit facts
                      (composed (bundle (list market-thought exit-vec)))

                      ;; Exit: recommend distances
                      ((dists _exit-exp)
                        (recommended-distances (nth (:exit-observers post) ei)
                          composed
                          (:scalar-accums (nth (:registry post) slot-idx))
                          (scalar-encoder (:thought-encoder ctx))))

                      ;; Derive side + edge (reads only)
                      (side-val (derive-side-from-prediction
                                  (nth market-predictions mi)))
                      (edge-val (edge (nth (:registry post) slot-idx)))
                      (enterprise-pred (holon-prediction-to-enterprise
                                         (nth market-predictions mi))))

                 (list slot-idx composed dists side-val edge-val enterprise-pred)))
             (range (* n m))))

         ;; Build proposals (pure — struct construction, no mutation)
         (proposals
           (map (lambda (gv)
                  (let (((slot-idx composed dists side-val edge-val enterprise-pred) gv))
                    (make-proposal composed dists edge-val side-val
                      (:source-asset post) (:target-asset post)
                      enterprise-pred (:post-idx post) slot-idx)))
                grid-values))

         ;; Apply mutations per-broker in parallel
         (_ (par-iter-mut-zip
              (lambda (broker gv)
                (let (((_ composed dists _ _ _) gv))
                  (propose broker composed)
                  (register-paper broker composed price dists)))
              (:registry post)
              grid-values)))

    (list proposals market-thoughts all-misses)))

;; ── post-propagate ──────────────────────────────────────────────
;; Route a resolved outcome to the broker, then apply propagation
;; facts to observers. Values up, not effects down.
;; Takes recalib-interval as a parameter (not from constructor).

(define (post-propagate [post : Post]
                        [slot-idx : usize]
                        [thought : Vector]
                        [outcome : Outcome]
                        [weight : f64]
                        [direction : Direction]
                        [optimal : Distances]
                        [recalib-interval : usize])
  : Vec<LogEntry>
  (let* ((broker (nth (:registry post) slot-idx))
         (prop-facts
           (propagate broker thought outcome weight direction optimal
                      recalib-interval (ctx-scalar-encoder-placeholder)))
         ;; Apply propagation facts to observers
         (mi (:market-idx prop-facts))
         (ei (:exit-idx prop-facts))

         (_ (when (< mi (len (:market-observers post)))
              (resolve (nth (:market-observers post) mi)
                (:composed-thought prop-facts)
                (:direction prop-facts)
                (:weight prop-facts)
                recalib-interval)))

         (_ (when (< ei (len (:exit-observers post)))
              (observe-distances (nth (:exit-observers post) ei)
                (:composed-thought prop-facts)
                (:optimal prop-facts)
                (:weight prop-facts)))))

    (list (log-entry-propagated slot-idx 2))))

;; ── post-update-triggers ────────────────────────────────────────
;; Re-query exit observers for fresh distances on active trades.
;; Encodes exit facts directly via lens and composes with market
;; thought. Uses par_iter for active trades.
;; Returns level updates and cache misses as values.

(define (post-update-triggers [post : Post]
                              [trades : Vec<(TradeId, Trade)>]
                              [market-thoughts : Vec<Vector>]
                              [ctx : Ctx])
  : (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>)
  (let* ((m (len (:exit-observers post)))
         (candle (last (:candle-window post))))

    (if (nil? candle)
      (list (vec) (vec))
      (let* ((results
               (par-iter
                 (lambda (trade-pair)
                   (let* (((trade-id trade) trade-pair)
                          (slot-idx (:broker-slot-idx trade))
                          (mi (/ slot-idx m))
                          (ei (mod slot-idx m)))

                     (if (>= mi (len market-thoughts))
                       nil
                       (let* ((market-thought (nth market-thoughts mi))

                              ;; Exit: encode facts via lens, compose with market thought
                              (exit-lens (:lens (nth (:exit-observers post) ei)))
                              (exit-fact-asts (exit-lens-facts exit-lens candle))
                              (exit-bundle (thought-ast-bundle exit-fact-asts))
                              ((exit-vec misses)
                                (encode (:thought-encoder ctx) exit-bundle))

                              (composed (bundle (list market-thought exit-vec)))

                              ;; Get fresh distances
                              ((dists _)
                                (recommended-distances (nth (:exit-observers post) ei)
                                  composed
                                  (:scalar-accums (nth (:registry post) slot-idx))
                                  (scalar-encoder (:thought-encoder ctx))))

                              ;; Convert to levels
                              (new-levels (distances-to-levels dists
                                            (current-price post) (:side trade))))

                         (list (list trade-id new-levels) misses)))))
                 trades))

             ;; Filter nils, collect
             (valid (filter (lambda (r) (not (nil? r))) results))
             (level-updates (map first valid))
             (all-misses (apply append (map second valid))))

        (list level-updates all-misses)))))

;; ── current-price ───────────────────────────────────────────────
;; The close of the last candle in the post's candle-window.

(define (current-price [post : Post])
  : f64
  (:close (last (:candle-window post))))
