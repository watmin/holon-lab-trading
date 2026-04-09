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
(require engram-gate)       ; check-engram-gate

;; ── Struct ──────────────────────────────────────────────────────────────

(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]                ; :discrete — Up/Down
  [noise-subspace : OnlineSubspace]    ; background model — learns what ALL thoughts look like
  [window-sampler : WindowSampler]     ; own time scale
  ;; Proof tracking
  [resolved : usize]                   ; how many predictions have been resolved
  [curve : Curve]                      ; measures this observer's edge (conviction -> accuracy)
  [curve-valid : f64]                  ; cached edge from the curve. 0.0 = unproven.
                                       ; updated after each recalibration by querying the curve.
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
  (make-market-observer
    lens
    (make-reckoner config)
    (online-subspace (:dims config) 8)    ; noise subspace — k=8 components
    sampler
    0                                     ; resolved
    (make-curve)                          ; curve
    0.0                                   ; curve-valid
    (online-subspace (:dims config) 4)    ; good-state-subspace — k=4
    0                                     ; recalib-wins
    0                                     ; recalib-total
    0))                                   ; last-recalib-count

;; ── observe-candle — the encoding pipeline ──────────────────────────────
;;
;; candle-window: a slice of recent candles. The observer encodes ->
;; noise update -> strip noise -> predict.
;;
;; Returns: (thought : Vector, prediction : Prediction, edge : f64, misses : Vec<(ThoughtAST, Vector)>)
;; The message protocol. Every learned output carries its track record.
;; Cache misses are returned as values — the caller collects.

(define (observe-candle [obs : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [ctx : Ctx])
  : (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)

  ;; 1. Collect fact ASTs from vocab modules matching this lens
  (let* ((candle     (last candle-window))
         (fact-asts  (collect-market-facts (:lens obs) candle))

         ;; 2. Bundle all fact ASTs into one thought AST, then evaluate
         (thought-ast (Bundle fact-asts))
         ((raw-thought misses) (encode (:thought-encoder ctx) thought-ast))

         ;; 3. Feed the noise subspace — it learns what ALL thoughts look like
         (_           (update (:noise-subspace obs) raw-thought))

         ;; 4. Strip noise — what remains is what's unusual about THIS thought
         (thought     (strip-noise obs raw-thought))

         ;; 5. Predict direction from the denoised thought
         (pred        (predict (:reckoner obs) thought))

         ;; 6. Edge — the curve's accuracy at this conviction level
         (edge        (:curve-valid obs)))

    (list thought pred edge misses)))

;; ── collect-market-facts — lens -> vocab modules -> fact ASTs ───────────
;;
;; Each MarketLens variant selects a subset of the vocabulary.
;; The generalist selects all modules. Time facts are universal.

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

(define (strip-noise [obs : MarketObserver]
                     [thought : Vector])
  : Vector
  (anomalous-component (:noise-subspace obs) thought))

;; ── resolve — reality labels the observer ───────────────────────────────
;;
;; Called by broker propagation. direction: Direction (:up or :down).
;; weight: f64 — how much value was at stake.

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
         (pred  (predict (:reckoner obs) thought))
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

    ;; 6. Engram gating — shared logic
    (let* ((old-recalib (:last-recalib-count obs))
           (gate-result (check-engram-gate
                          (:reckoner obs)
                          (:good-state-subspace obs)
                          (:recalib-wins obs)
                          (:recalib-total obs)
                          old-recalib
                          correct
                          "Up")))
      (set! (:recalib-wins obs) (first gate-result))
      (set! (:recalib-total obs) (second gate-result))
      (set! (:last-recalib-count obs) (nth gate-result 2))

      ;; Update cached edge from the curve when recalibration happened
      (when (> (nth gate-result 2) old-recalib)
        (set! (:curve-valid obs)
              (if (proven? (:curve obs) 50)
                  (edge-at (:curve obs) 0.5)
                  0.0))))))

;; ── experience — how much has this observer learned? ────────────────────

(define (experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))
