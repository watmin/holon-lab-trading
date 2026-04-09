;; market-observer.wat — MarketObserver struct + interface
;; Depends on: enums (MarketLens, Direction, Outcome), reckoner, window-sampler,
;;             thought-encoder (ThoughtAST), engram-gate, ctx
;; Predicts direction (Up/Down). Labels come from broker propagation.

(require primitives)
(require enums)
(require window-sampler)
(require thought-encoder)
(require engram-gate)
(require ctx)
(require candle)
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
  [resolved : usize]                   ; how many predictions have been resolved
  [curve : Curve]                      ; measures this observer's edge
  [curve-valid : f64]                  ; cached edge from the curve. 0.0 = unproven.
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize]
  [last-prediction : Direction])       ; set by observe-candle, read by resolve

(define (make-market-observer [lens : MarketLens]
                              [config : ReckConfig]
                              [ws : WindowSampler])
  : MarketObserver
  (let ((dims (match config
                ((Discrete d _ _) d)
                ((Continuous d _ _) d))))
    (market-observer
      lens
      (make-reckoner config)
      (online-subspace dims 8)           ; 8 principal components for background
      ws
      0                                   ; resolved
      (make-curve)                        ; curve
      0.0                                 ; curve-valid — 0.0 = unproven
      (online-subspace dims 4)           ; 4 components for engram gating
      0                                   ; recalib-wins
      0                                   ; recalib-total
      0                                   ; last-recalib-count
      :up)))                              ; last-prediction — initial doesn't matter

;; Collect vocab ASTs for this lens.
;; The observer calls the modules matching its lens, appends the results.
(define (market-lens-facts [lens : MarketLens] [c : Candle])
  : Vec<ThoughtAST>
  (let ((time-facts (encode-time-facts c)))
    (match lens
      (:momentum
        (append time-facts
                (encode-oscillator-facts c)
                (encode-momentum-facts c)
                (encode-stochastic-facts c)))
      (:structure
        (append time-facts
                (encode-keltner-facts c)
                (encode-fibonacci-facts c)
                (encode-ichimoku-facts c)
                (encode-price-action-facts c)))
      (:volume
        (append time-facts
                (encode-flow-facts c)))
      (:narrative
        (append time-facts
                (encode-timeframe-facts c)
                (encode-divergence-facts c)))
      (:regime
        (append time-facts
                (encode-regime-facts c)
                (encode-persistence-facts c)))
      (:generalist
        (append time-facts
                (encode-oscillator-facts c)
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
                (encode-persistence-facts c))))))

;; Strip noise — return the anomalous component.
;; The residual IS the signal. The reckoner learns from what is unusual.
(define (strip-noise [obs : MarketObserver] [thought : Vector])
  : Vector
  (update (:noise-subspace obs) thought)
  (anomalous-component (:noise-subspace obs) thought))

;; Observe a candle — encode, strip noise, predict.
;; Returns: (thought, prediction, edge, cache-misses)
(define (observe-candle [obs : MarketObserver] [candle-window : Vec<Candle>]
                        [c : Ctx])
  : (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
  (let ((latest (last candle-window))
        ;; Collect facts for this lens
        (fact-asts (market-lens-facts (:lens obs) latest))
        ;; Wrap in a Bundle — still data
        (bundle-ast (Bundle fact-asts))
        ;; Encode via ctx's ThoughtEncoder
        ((raw-thought misses) (encode (:thought-encoder c) bundle-ast))
        ;; Strip noise — the anomalous component IS the signal
        (thought (strip-noise obs raw-thought))
        ;; Predict direction
        (pred (predict (:reckoner obs) thought))
        ;; Store the predicted direction for resolve to compare
        (direction (match pred
                     ((Discrete scores _)
                       (let ((up-score  (fold (lambda (best s)
                                          (if (= (first s) "Up") (second s) best))
                                        -2.0 scores))
                             (dn-score  (fold (lambda (best s)
                                          (if (= (first s) "Down") (second s) best))
                                        -2.0 scores)))
                         (if (>= up-score dn-score) :up :down)))
                     ((Continuous _ _) :up))))  ; fallback, shouldn't happen
    (set! (:last-prediction obs) direction)
    (list thought pred (:curve-valid obs) misses)))

;; Resolve — the actual direction is routed back.
;; Called by broker propagation. The reckoner learns from reality.
(define (resolve [obs : MarketObserver] [thought : Vector]
                 [direction : Direction] [weight : f64])
  ;; Observe with the actual label
  (let ((label (match direction (:up "Up") (:down "Down"))))
    (observe (:reckoner obs) thought label weight)
    ;; Track engram accuracy: compare last-prediction against actual
    (let ((correct (match (:last-prediction obs)
                     (:up   (match direction (:up true) (:down false)))
                     (:down (match direction (:down true) (:up false))))))
      ;; Record in curve
      (let ((conviction (match (predict (:reckoner obs) thought)
                          ((Discrete _ c) c)
                          ((Continuous _ _) 0.0))))
        (record-prediction (:curve obs) conviction correct))
      ;; Update engram gate tracking
      (let (((w t) (engram-gate-record correct
                     (:recalib-wins obs) (:recalib-total obs))))
        (set! (:recalib-wins obs) w)
        (set! (:recalib-total obs) t))
      (inc! (:resolved obs))
      ;; Check engram gate on recalibration
      (let (((ok sub w2 t2 rc)
              (check-engram-gate
                (:reckoner obs) (:good-state-subspace obs)
                (:recalib-wins obs) (:recalib-total obs)
                (:last-recalib-count obs) 0.55)))
        (set! (:good-state-subspace obs) sub)
        (set! (:recalib-wins obs) w2)
        (set! (:recalib-total obs) t2)
        (set! (:last-recalib-count obs) rc)
        ;; Update cached edge from curve
        (when (proven? (:curve obs) 50)
          (set! (:curve-valid obs)
            (edge-at (:curve obs) (match (predict (:reckoner obs) thought)
                                    ((Discrete _ c) c)
                                    ((Continuous _ _) 0.0)))))))))

;; How much has this observer learned?
(define (experience [obs : MarketObserver])
  : f64
  (+ 0.0 (:resolved obs)))
