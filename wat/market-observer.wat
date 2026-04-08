; market-observer.wat — predicts direction (Up/Down).
;
; Depends on: reckoner (:discrete), OnlineSubspace, WindowSampler,
;             Curve, MarketLens, Prediction, ThoughtAST, ThoughtEncoder.
;
; The observer that perceives the market through a lens and predicts
; which way it will move. Has a noise subspace for stripping the boring
; part, a window sampler for its own time scale, a curve for proof
; tracking, and engram gating for discriminant quality control.
;
; Message protocol: (thought : Vector, prediction : Prediction, edge : f64).
; Every learned output carries its track record. The consumer decides.

(require primitives)
(require enums)             ; Direction, Prediction, reckoner-config, MarketLens
(require window-sampler)
(require thought-encoder)

;; ── Struct ──────────────────────────────────────────────────────────────

(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]                ; :discrete — Up/Down
  [noise-subspace : OnlineSubspace]    ; background model — learns what ALL thoughts look like
  [window-sampler : WindowSampler]     ; own time scale
  ;; Proof tracking
  [resolved : usize]                   ; how many predictions have been resolved
  [conviction-history : Vec<f64>]      ; recent conviction values for curve fitting
  [conviction-threshold : f64]         ; minimum conviction to participate.
                                       ; derived from the curve after recalibration:
                                       ; the conviction level where edge first appears.
                                       ; 0.0 when the curve has insufficient data.
  [curve : Curve]                      ; measures this observer's edge (conviction -> accuracy)
  [curve-valid : f64]                  ; cached edge from the curve. 0.0 = unproven.
                                       ; updated after each recalibration by querying the curve.
  [cached-accuracy : f64]              ; rolling accuracy of resolved predictions
  ;; Engram gating
  [good-state-subspace : OnlineSubspace] ; learns what good discriminants look like
  [recalib-wins : usize]               ; wins since last recalibration
  [recalib-total : usize]              ; total since last recalibration
  [last-recalib-count : usize])        ; recalib-count at last engram check

;; ── Constructor ─────────────────────────────────────────────────────────

(define (make-market-observer [lens : MarketLens]
                              [config : reckoner-config]
                              [sampler : WindowSampler])
  : MarketObserver
  ;; config must be Discrete with ("Up" "Down") labels.
  ;; noise-subspace created empty — learns from observations.
  ;; All proof-tracking and engram-gating fields initialize to zero/empty.
  (make-market-observer
    lens
    (make-reckoner config)
    (online-subspace (:dims config) 8)    ; noise subspace — k=8 components
    sampler
    0                                     ; resolved
    (list)                                ; conviction-history
    0.0                                   ; conviction-threshold
    (make-curve)                          ; curve
    0.0                                   ; curve-valid
    0.0                                   ; cached-accuracy
    (online-subspace (:dims config) 4)    ; good-state-subspace — k=4
    0                                     ; recalib-wins
    0                                     ; recalib-total
    0))                                   ; last-recalib-count

;; ── observe-candle — the encoding pipeline ──────────────────────────────
;;
;; candle-window: a slice of recent candles (the post sliced it using
;; sample(window-sampler, encode-count)). The observer encodes ->
;; noise update -> strip noise -> predict.
;;
;; Returns: (thought : Vector, prediction : Prediction, edge : f64)
;; The message protocol. Every learned output carries its track record.

(define (observe-candle [obs : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [ctx : Ctx]
                        [miss-queue : Vec<(ThoughtAST, Vector)>])
  : (Vector, Prediction, f64)

  ;; 1. Collect fact ASTs from vocab modules matching this lens
  (let* ((candle     (last candle-window))
         (fact-asts  (collect-market-facts (:lens obs) candle))

         ;; 2. Bundle all fact ASTs into one thought AST, then evaluate
         (thought-ast (Bundle fact-asts))
         (raw-thought (encode (:thought-encoder ctx) thought-ast miss-queue))

         ;; 3. Feed the noise subspace — it learns what ALL thoughts look like
         (_           (update (:noise-subspace obs) raw-thought))

         ;; 4. Strip noise — what remains is what's unusual about THIS thought
         (thought     (strip-noise obs raw-thought))

         ;; 5. Predict direction from the denoised thought
         (pred        (predict (:reckoner obs) thought))

         ;; 6. Edge — the curve's accuracy at this conviction level
         (edge        (:curve-valid obs)))

    (list thought pred edge)))

;; ── collect-market-facts — lens -> vocab modules -> fact ASTs ───────────
;;
;; Each MarketLens variant selects a subset of the vocabulary.
;; The generalist selects all modules.

(define (collect-market-facts [lens : MarketLens]
                              [candle : Candle])
  : Vec<ThoughtAST>
  ;; Time facts are universal context — every lens gets them.
  (let ((time-facts (encode-time-facts candle))
        (domain-facts
          (match lens
            (:momentum   (append (encode-oscillator-facts candle)
                                 (encode-momentum-facts candle)
                                 (encode-stochastic-facts candle)))
            (:structure  (append (encode-keltner-facts candle)
                                 (encode-fibonacci-facts candle)
                                 (encode-ichimoku-facts candle)
                                 (encode-price-action-facts candle)))
            (:volume     (encode-flow-facts candle))
            (:narrative  (append (encode-timeframe-facts candle)
                                 (encode-divergence-facts candle)))
            (:regime     (append (encode-regime-facts candle)
                                 (encode-persistence-facts candle)))
            (:generalist (append (encode-oscillator-facts candle)
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
                                 (encode-persistence-facts candle))))))
    (append time-facts domain-facts)))

;; ── strip-noise — subtract the boring part ──────────────────────────────
;;
;; The noise subspace has learned what ALL thoughts look like.
;; The anomalous component is what's UNUSUAL about this thought.
;; The reckoner learns from the unusual part, not the boring part.

(define (strip-noise [obs : MarketObserver]
                     [thought : Vector])
  : Vector
  (let ((noise (anomalous-component (:noise-subspace obs) thought)))
    ;; anomalous-component returns the part NOT explained by the subspace.
    ;; That IS the signal — what makes this thought different from average.
    noise))

;; ── resolve — reality labels the observer ───────────────────────────────
;;
;; Called by broker propagation. The market observer does NOT label itself.
;; Reality labels it: the actual direction (Up/Down) from a resolved trade
;; or paper.
;;
;; direction: Direction (:up or :down) — what the price actually did.
;; weight: f64 — how much value was at stake. A $500 Grace teaches harder.

(define (resolve [obs : MarketObserver]
                 [thought : Vector]
                 [direction : Direction]
                 [weight : f64])
  ;; 1. Map direction to the reckoner's label
  (let* ((label (match direction
                  (:up   "Up")
                  (:down "Down")))

         ;; 2. The reckoner learns from reality
         (_     (observe (:reckoner obs) thought label weight))

         ;; 3. Record the prediction's outcome for the curve
         ;;    Was the reckoner's prediction correct?
         (pred  (predict (:reckoner obs) thought))
         ;; scores are in registration order: first='Up', second='Down'
         (predicted-dir (match pred
                          ((Discrete scores conviction)
                            (if (> (second (first scores)) (second (second scores)))
                                "Up" "Down"))))
         (correct (= label predicted-dir)))

    ;; 4. Feed the curve — conviction vs correctness
    (match pred
      ((Discrete scores conviction)
        (record-prediction (:curve obs) conviction correct)))

    ;; 5. Update proof tracking
    (inc! (:resolved obs))

    ;; 6. Engram gating — check if recalibration happened
    (let ((current-recalib (recalib-count (:reckoner obs))))
      (when (> current-recalib (:last-recalib-count obs))
        ;; A recalibration happened. Update engram gate.
        (begin
          ;; Check accuracy since last recalib
          (when correct
            (inc! (:recalib-wins obs)))
          (inc! (:recalib-total obs))

          ;; If enough data and good accuracy, snapshot the discriminant
          (when (and (> (:recalib-total obs) 0)
                     (> (/ (+ (:recalib-wins obs) 0.0)
                           (+ (:recalib-total obs) 0.0))
                        0.55))
            (let ((disc (discriminant (:reckoner obs) "Up")))
              (when-let ((d (Some disc)))
                (update (:good-state-subspace obs) d))))

          ;; Update cached edge from the curve
          (set! (:curve-valid obs)
                (if (proven? (:curve obs) 50)
                    (edge-at (:curve obs) 0.5)
                    0.0))

          ;; Reset recalib counters
          (set! (:recalib-wins obs) 0)
          (set! (:recalib-total obs) 0)
          (set! (:last-recalib-count obs) current-recalib))))))

;; ── experience — how much has this observer learned? ────────────────────

(define (experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))
