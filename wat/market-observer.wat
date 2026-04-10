;; market-observer.wat — MarketObserver struct + interface
;; Depends on: reckoner, window-sampler, enums, engram-gate, thought-encoder, ctx

(require primitives)
(require enums)
(require window-sampler)
(require engram-gate)
(require thought-encoder)
(require ctx)
(require vocab/shared/time)
(require vocab/market/oscillators)
(require vocab/market/flow)
(require vocab/market/persistence)
(require vocab/market/regime)
(require vocab/market/divergence)
(require vocab/market/ichimoku)
(require vocab/market/stochastic)
(require vocab/market/fibonacci)
(require vocab/market/keltner)
(require vocab/market/momentum)
(require vocab/market/price-action)
(require vocab/market/timeframe)

(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]                ; :discrete — Up/Down
  [noise-subspace : OnlineSubspace]    ; background model
  [window-sampler : WindowSampler]     ; own time scale
  ;; Proof tracking
  [resolved : usize]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize]
  [last-prediction : Direction])

(define (make-market-observer [lens : MarketLens]
                              [dims : usize]
                              [recalib-interval : usize]
                              [ws : WindowSampler])
  : MarketObserver
  (market-observer
    lens
    (make-reckoner (format "market-{}" lens) dims recalib-interval
      (Discrete (list "Up" "Down")))
    (online-subspace dims 8)
    ws
    0
    (online-subspace dims 4)
    0 0 0
    :up))

;; Collect vocabulary facts for this lens
(define (lens-facts [lens : MarketLens] [c : Candle])
  : Vec<ThoughtAST>
  (let ((time-facts (encode-time-facts c)))
    (append time-facts
      (match lens
        (:momentum
          (append (encode-oscillator-facts c)
                  (encode-momentum-facts c)
                  (encode-stochastic-facts c)))
        (:structure
          (append (encode-keltner-facts c)
                  (encode-fibonacci-facts c)
                  (encode-ichimoku-facts c)
                  (encode-price-action-facts c)))
        (:volume
          (encode-flow-facts c))
        (:narrative
          (append (encode-timeframe-facts c)
                  (encode-divergence-facts c)))
        (:regime
          (append (encode-regime-facts c)
                  (encode-persistence-facts c)))
        (:generalist
          (append (encode-oscillator-facts c)
                  (encode-momentum-facts c)
                  (encode-stochastic-facts c)
                  (encode-keltner-facts c)
                  (encode-fibonacci-facts c)
                  (encode-ichimoku-facts c)
                  (encode-price-action-facts c)
                  (encode-flow-facts c)
                  (encode-timeframe-facts c)
                  (encode-divergence-facts c)
                  (encode-regime-facts c)
                  (encode-persistence-facts c)))))))

;; Strip noise: return the anomalous component
(define (strip-noise [obs : MarketObserver] [thought : Vector])
  : Vector
  (anomalous-component (:noise-subspace obs) thought))

;; Experience: how much has this observer learned?
(define (market-observer-experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))

;; Observe a candle and produce a thought + prediction + edge + misses
(define (observe-candle [obs : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [c : Ctx])
  : (MarketObserver Vector Prediction f64 Vec<(ThoughtAST, Vector)>)
  (let ((candle (last candle-window))
        ;; Collect facts for this lens
        (fact-asts (lens-facts (:lens obs) candle))
        ;; Wrap in a Bundle AST
        (bundle-ast (Bundle fact-asts))
        ;; Encode via ThoughtEncoder
        ((thought misses) (encode (:thought-encoder c) bundle-ast))
        ;; Update noise subspace
        (_ (update (:noise-subspace obs) thought))
        ;; Strip noise — the signal is what the subspace cannot explain
        (stripped (strip-noise obs thought))
        ;; Predict direction
        (pred (predict (:reckoner obs) stripped))
        ;; Extract conviction and edge
        (conviction (match pred
                      ((Discrete scores conv) conv)
                      ((Continuous v e) 0.0)))
        (edge-val (if (proven? (:reckoner obs) 50)
                    (edge-at (:reckoner obs) conviction)
                    0.0))
        ;; Determine predicted direction from scores
        (predicted-dir (match pred
                         ((Discrete scores conv)
                           (let ((up-score (fold (lambda (best pair)
                                            (if (= (first pair) "Up") (second pair) best))
                                          0.0 scores))
                                 (down-score (fold (lambda (best pair)
                                              (if (= (first pair) "Down") (second pair) best))
                                            0.0 scores)))
                             (if (>= up-score down-score) :up :down)))
                         ((Continuous v e) :up)))
        ;; Update observer with last-prediction
        (updated-obs (update obs :last-prediction predicted-dir)))
    (list updated-obs thought pred edge-val misses)))

;; Resolve: the market told us what actually happened
(define (resolve-market-observer [obs : MarketObserver]
                                  [thought : Vector]
                                  [actual-direction : Direction]
                                  [weight : f64])
  : MarketObserver
  (let ((stripped (strip-noise obs thought))
        ;; The actual direction becomes the label
        (label (match actual-direction
                 (:up "Up")
                 (:down "Down")))
        ;; Observe the label
        (_ (observe (:reckoner obs) stripped label weight))
        ;; Check if prediction was correct
        (correct (match (list (:last-prediction obs) actual-direction)
                   ((:up :up) true)
                   ((:down :down) true)
                   (_ false)))
        ;; Get conviction for curve
        (pred (predict (:reckoner obs) stripped))
        (conviction (match pred
                      ((Discrete scores conv) conv)
                      ((Continuous v e) 0.0)))
        ;; Feed the curve
        (_ (resolve (:reckoner obs) conviction correct))
        ;; Check engram gate
        (outcome-for-gate (if correct :grace :violence))
        ((new-gs new-rw new-rt new-lrc)
          (check-engram-gate (:reckoner obs)
            (:good-state-subspace obs)
            (:recalib-wins obs)
            (:recalib-total obs)
            (:last-recalib-count obs)
            outcome-for-gate)))
    (update obs
      :resolved (+ (:resolved obs) 1)
      :good-state-subspace new-gs
      :recalib-wins new-rw
      :recalib-total new-rt
      :last-recalib-count new-lrc)))
