;; market-observer.wat — MarketObserver struct + interface
;; Depends on: enums (MarketLens, Direction, prediction), thought-encoder, ctx,
;;             window-sampler, engram-gate

(require primitives)
(require enums)
(require thought-encoder)
(require ctx)
(require window-sampler)
(require engram-gate)
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

;; ── MarketObserver ────────────────────────────────────────────────────
;; Predicts direction. Learned. Labels come from broker propagation.
;; The generalist is just another lens. No special treatment.
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
                              [ws : WindowSampler])
  : MarketObserver
  (let ((reck (make-reckoner
                (format "direction-{}" lens)
                dims recalib-interval
                (Discrete (list "Up" "Down")))))
    (market-observer
      lens
      reck
      (online-subspace dims 8)    ; noise subspace — 8 principal components
      ws
      0                            ; resolved
      (online-subspace dims 4)    ; good-state-subspace — 4 components
      0 0 0                       ; recalib-wins, recalib-total, last-recalib-count
      :up)))                      ; last-prediction default

;; ── lens-to-market-facts — dispatch vocabulary modules by lens ────────
(define (lens-to-market-facts [lens : MarketLens]
                               [c : Candle])
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

;; ── strip-noise — return the anomalous component ──────────────────────
;; What the noise subspace CANNOT explain. The residual IS the signal.
(define (strip-noise [obs : MarketObserver]
                     [thought : Vector])
  : Vector
  (update (:noise-subspace obs) thought)
  (anomalous-component (:noise-subspace obs) thought))

;; ── observe-candle — encode, noise, predict ───────────────────────────
;; Returns: thought Vector, Prediction (Up/Down), edge (f64), cache misses.
(define (observe-candle [obs : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [ctx : Ctx])
  : (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
  (let (;; Get the most recent candle for vocabulary
        (latest (last candle-window))
        ;; Gather facts from the lens's vocabulary modules
        (fact-asts (lens-to-market-facts (:lens obs) latest))
        ;; Wrap in a Bundle AST
        (bundle-ast (Bundle fact-asts))
        ;; Encode via the ThoughtEncoder on ctx
        ((raw-thought misses) (encode (:thought-encoder ctx) bundle-ast))
        ;; Strip noise — update subspace, get anomalous component
        (thought (strip-noise obs raw-thought))
        ;; Predict
        (pred (predict (:reckoner obs) thought))
        ;; Extract direction from prediction
        (direction (match pred
                     ((Discrete scores conviction)
                       (let ((up-score (fold-left (lambda (best s)
                                         (if (= (first s) "Up") (second s) best))
                                       0.0 scores))
                             (down-score (fold-left (lambda (best s)
                                           (if (= (first s) "Down") (second s) best))
                                         0.0 scores)))
                         (if (>= up-score down-score) :up :down)))
                     ((Continuous _ _) :up)))  ; should not happen for market observer
        ;; Compute edge from reckoner's curve
        (conviction (match pred
                      ((Discrete _ c) c)
                      ((Continuous _ _) 0.0)))
        (edge (if (proven? (:reckoner obs) 100)
                (edge-at (:reckoner obs) conviction)
                0.0)))
    ;; Store last prediction for resolve to compare against
    (set! obs :last-prediction direction)
    (list thought pred edge misses)))

;; ── resolve — learn from reality ──────────────────────────────────────
;; direction: Direction — the actual price movement.
;; weight: f64 — how much value was at stake.
(define (resolve [obs : MarketObserver]
                 [thought : Vector]
                 [direction : Direction]
                 [weight : f64])
  ;; Reckoner observes the actual direction label
  (let ((label (match direction
                 (:up "Up")
                 (:down "Down"))))
    (observe (:reckoner obs) thought label weight)
    ;; Check if the prediction was correct
    (let ((correct? (match (list (:last-prediction obs) direction)
                      ((:up :up) true)
                      ((:down :down) true)
                      (_ false)))
          ;; Feed the reckoner's internal curve
          (conviction 0.0)) ; use last known conviction
      ;; Extract conviction from a fresh predict (or store it)
      (let ((pred (predict (:reckoner obs) thought)))
        (match pred
          ((Discrete _ c)
            (begin
              (resolve (:reckoner obs) c correct?)
              ;; Engram gating
              (let (((new-gss new-rw new-rt new-lrc gate-passed)
                      (check-engram-gate
                        (:good-state-subspace obs)
                        (:recalib-wins obs)
                        (:recalib-total obs)
                        (:last-recalib-count obs)
                        (:reckoner obs)
                        correct?)))
                (set! obs :good-state-subspace new-gss)
                (set! obs :recalib-wins new-rw)
                (set! obs :recalib-total new-rt)
                (set! obs :last-recalib-count new-lrc))))
          (_ (begin))))
      (inc! obs :resolved))))

;; ── experience — how much has this observer learned? ──────────────────
(define (experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))
