;; market-observer.wat — MarketObserver struct + interface
;; Depends on: enums.wat, window-sampler.wat, engram-gate.wat, thought-encoder.wat, ctx.wat

(require primitives)
(require enums)
(require window-sampler)
(require engram-gate)
(require thought-encoder)
(require ctx)

;; ── Vocabulary module dispatch ─────────────────────────────────────
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

;; ── MarketObserver ─────────────────────────────────────────────────
;; Predicts direction (Up/Down). Learned. Labels come from broker propagation.

(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]
  [noise-subspace : OnlineSubspace]
  [window-sampler : WindowSampler]
  [resolved : usize]
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize]
  [last-prediction : Direction])

(define (make-market-observer [lens : MarketLens]
                              [dims : usize]
                              [recalib-interval : usize]
                              [window-sampler : WindowSampler])
  : MarketObserver
  (let ((rk (make-reckoner (format "direction-{}" lens)
              dims recalib-interval (Discrete '("Up" "Down")))))
    (market-observer
      lens rk
      (online-subspace dims 8)    ; noise — 8 principal components
      window-sampler
      0                            ; resolved
      (online-subspace dims 4)    ; good-state — 4 components
      0 0 0                        ; engram tracking
      :up)))                       ; last-prediction default

;; ── lens-fact-asts — collect vocab modules matching this lens ──────

(define (lens-fact-asts [lens : MarketLens] [c : Candle])
  : Vec<ThoughtAST>
  (let ((time-facts (encode-time-facts c))
        (domain-facts
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
                      (encode-persistence-facts c))))))
    (append time-facts domain-facts)))

;; ── strip-noise — return the anomalous component ──────────────────
;; The residual IS the signal. What the noise subspace cannot explain.

(define (strip-noise [obs : MarketObserver] [thought : Vector])
  : Vector
  (update (:noise-subspace obs) thought)
  (anomalous-component (:noise-subspace obs) thought))

;; ── observe-candle ─────────────────────────────────────────────────
;; Returns: (thought, Prediction, edge, cache-misses)

(define (observe-candle [obs : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [c : Ctx])
  : (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
  (let (;; The latest candle in the window
        (candle (last candle-window))
        ;; Collect fact ASTs for this lens
        (fact-asts (lens-fact-asts (:lens obs) candle))
        ;; Wrap in a Bundle AST
        (bundle-ast (Bundle fact-asts))
        ;; Encode via the ThoughtEncoder
        ((raw-thought misses) (encode (:thought-encoder c) bundle-ast))
        ;; Strip noise — the residual IS the signal
        (thought (strip-noise obs raw-thought))
        ;; Predict
        (pred (predict (:reckoner obs) thought))
        ;; Extract conviction from prediction
        (conviction (match pred
                      ((Discrete scores conv) conv)
                      ((Continuous val exp) 0.0)))
        ;; Edge from the reckoner's internal curve
        (min-samples 100)
        (edge (if (proven? (:reckoner obs) min-samples)
                (edge-at (:reckoner obs) conviction)
                0.0))
        ;; Store the predicted direction
        (predicted-direction
          (match pred
            ((Discrete scores conv)
              (let ((up-score (or (get (map-of scores) "Up") 0.0))
                    (down-score (or (get (map-of scores) "Down") 0.0)))
                (if (>= up-score down-score) :up :down)))
            ((Continuous val exp) :up))))
    (set! obs :last-prediction predicted-direction)
    (list thought pred edge misses)))

;; ── resolve — learn from reality ───────────────────────────────────
;; direction: what the price actually did. weight: how much value.

(define (resolve [obs : MarketObserver]
                 [thought : Vector]
                 [direction : Direction]
                 [weight : f64])
  (let ((label (match direction (:up "Up") (:down "Down"))))
    ;; Teach the reckoner
    (observe (:reckoner obs) thought label weight)

    ;; Feed the reckoner's internal curve
    (let ((pred (predict (:reckoner obs) thought))
          (conviction (match pred
                        ((Discrete scores conv) conv)
                        ((Continuous val exp) 0.0)))
          (correct? (= (:last-prediction obs) direction)))
      (resolve (:reckoner obs) conviction correct?))

    ;; Engram gating — track accuracy and snapshot good states
    (let ((outcome (if (= (:last-prediction obs) direction) :grace :violence))
          (accuracy-threshold 0.55))
      (check-engram-gate
        (:reckoner obs)
        (:good-state-subspace obs)
        (:recalib-wins obs)
        (:recalib-total obs)
        (:last-recalib-count obs)
        outcome
        accuracy-threshold
        "Up"))

    ;; Track resolved count
    (set! obs :resolved (+ (:resolved obs) 1))))

;; ── experience — how much has this observer learned? ───────────────

(define (market-observer-experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))
