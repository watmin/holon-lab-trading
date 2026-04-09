;; market-observer.wat — MarketObserver struct + interface
;; Depends on: enums, thought-encoder, window-sampler, engram-gate, ctx

(require primitives)
(require enums)
(require thought-encoder)
(require window-sampler)
(require engram-gate)
(require ctx)

;; Vocabulary imports — lens determines which modules fire
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
  [reckoner : Reckoner]
  [noise-subspace : OnlineSubspace]
  [window-sampler : WindowSampler]
  ;; Proof tracking
  [resolved : usize]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize]
  [last-prediction : Direction])

(define (make-market-observer [lens : MarketLens] [dims : usize]
                              [recalib-interval : usize]
                              [window-sampler : WindowSampler])
  : MarketObserver
  (market-observer
    lens
    (make-reckoner "direction" dims recalib-interval (Discrete '("Up" "Down")))
    (online-subspace dims 8)
    window-sampler
    0             ; resolved
    (online-subspace dims 4)  ; good-state-subspace
    0 0 0         ; recalib-wins, recalib-total, last-recalib-count
    :up))         ; last-prediction — default, overwritten on first observe

;; Collect vocabulary ASTs based on this observer's lens.
(define (collect-market-asts [lens : MarketLens] [candle : Candle])
  : Vec<ThoughtAST>
  (let ((time-facts (encode-time-facts candle)))
    (append time-facts
      (match lens
        (:momentum
          (append (encode-oscillator-facts candle)
                  (encode-momentum-facts candle)
                  (encode-stochastic-facts candle)))
        (:structure
          (append (encode-keltner-facts candle)
                  (encode-fibonacci-facts candle)
                  (encode-ichimoku-facts candle)
                  (encode-price-action-facts candle)))
        (:volume
          (encode-flow-facts candle))
        (:narrative
          (append (encode-timeframe-facts candle)
                  (encode-divergence-facts candle)))
        (:regime
          (append (encode-regime-facts candle)
                  (encode-persistence-facts candle)))
        (:generalist
          (append (encode-oscillator-facts candle)
                  (encode-momentum-facts candle)
                  (encode-stochastic-facts candle)
                  (encode-keltner-facts candle)
                  (encode-fibonacci-facts candle)
                  (encode-ichimoku-facts candle)
                  (encode-price-action-facts candle)
                  (encode-flow-facts candle)
                  (encode-timeframe-facts candle)
                  (encode-divergence-facts candle)
                  (encode-regime-facts candle)
                  (encode-persistence-facts candle)))))))

;; Remove what the noise subspace already knows — return the anomalous component.
(define (strip-noise [obs : MarketObserver] [thought : Vector])
  : Vector
  (update (:noise-subspace obs) thought)
  (anomalous-component (:noise-subspace obs) thought))

;; How much has this observer learned?
(define (experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))

;; Observe a candle and produce a prediction.
;; candle-window: slice of recent candles (the post determines the window size).
;; Returns: (thought, prediction, edge, cache-misses)
(define (observe-candle [obs : MarketObserver] [candle-window : Vec<Candle>]
                        [ctx : Ctx])
  : (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
  (let ((candle (last candle-window))
        ;; Collect ASTs from vocabulary modules matching this lens
        (fact-asts (collect-market-asts (:lens obs) candle))
        ;; Wrap in a Bundle for encoding
        (bundle-ast (Bundle fact-asts))
        ;; Encode via the ThoughtEncoder
        ((raw-thought misses) (encode (:thought-encoder ctx) bundle-ast))
        ;; Strip noise — get the anomalous component
        (thought (strip-noise obs raw-thought))
        ;; Predict direction
        (pred (predict (:reckoner obs) thought))
        ;; Extract conviction and direction from prediction
        (conviction (match pred ((Discrete scores conv) conv) ((Continuous v e) 0.0)))
        ;; Edge from the reckoner's internal curve
        (edge (edge-at (:reckoner obs) conviction))
        ;; Determine predicted direction from scores
        (direction (match pred
          ((Discrete scores conv)
            (let ((up-score (fold (lambda (best s)
                              (if (= (first s) "Up") (second s) best))
                            0.0 scores))
                  (down-score (fold (lambda (best s)
                              (if (= (first s) "Down") (second s) best))
                            0.0 scores)))
              (if (>= up-score down-score) :up :down)))
          ((Continuous v e) :up))))  ; shouldn't happen for market observer
    ;; Store last prediction for resolve comparison
    (set! obs :last-prediction direction)
    (list thought pred edge misses)))

;; Resolve a prediction against reality. Called by broker propagation.
;; direction: the actual price movement (:up or :down).
;; weight: how much value was at stake.
(define (resolve [obs : MarketObserver] [thought : Vector]
                 [direction : Direction] [weight : f64])
  ;; Compare last-prediction against actual direction
  (let ((correct? (= (:last-prediction obs) direction))
        (conviction (let ((pred (predict (:reckoner obs) thought)))
                      (match pred
                        ((Discrete scores conv) conv)
                        ((Continuous v e) 0.0)))))
    ;; Feed the reckoner: learn from the actual direction
    (let ((label (match direction (:up "Up") (:down "Down"))))
      (observe (:reckoner obs) thought label weight))
    ;; Feed the internal curve with conviction and correctness
    (resolve (:reckoner obs) conviction correct?)
    ;; Increment resolved count
    (inc! obs :resolved)
    ;; Engram gating
    (let ((outcome (if correct? :grace :violence))
          ((accepted new-wins new-total new-last)
            (check-engram-gate (:reckoner obs) (:good-state-subspace obs)
                               (:recalib-wins obs) (:recalib-total obs)
                               (:last-recalib-count obs) outcome)))
      (set! obs :recalib-wins new-wins)
      (set! obs :recalib-total new-total)
      (set! obs :last-recalib-count new-last))))
