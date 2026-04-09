;; market-observer.wat — predicts direction (Up/Down) from candle data
;;
;; Depends on: enums (MarketLens, Direction, Outcome, Prediction, ThoughtAST),
;;             engram-gate, window-sampler, ctx
;;
;; Each market observer has a lens that selects which vocabulary modules
;; it thinks through. Six lenses: momentum, structure, volume, narrative,
;; regime, generalist. The generalist is just another lens.
;;
;; observe-candle returns FOUR values as a list:
;;   (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
;;   thought, prediction, curve-valid, cache-misses

(require primitives)
(require enums)
(require engram-gate)
(require window-sampler)
(require ctx)

(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]                  ; :discrete — Up/Down
  [noise-subspace : OnlineSubspace]      ; background model
  [window-sampler : WindowSampler]       ; own time scale
  ;; Proof tracking
  [resolved : usize]                     ; how many predictions have been resolved
  [curve : Curve]                        ; measures this observer's edge
  [curve-valid : f64]                    ; cached edge. 0.0 = unproven.
  ;; Engram gating
  [good-state-subspace : OnlineSubspace] ; learns what good discriminants look like
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

;; ── Constructor ────────────────────────────────────────────────────

(define (make-market-observer [lens : MarketLens]
                              [config : ReckConfig]
                              [window-sampler : WindowSampler])
  : MarketObserver
  (let ((dims (match config
                ((Discrete d _ _) d)
                ((Continuous d _ _) d))))
    (market-observer
      lens
      (make-reckoner config)
      (online-subspace dims 8)             ; 8 principal components for background
      window-sampler
      0                                     ; resolved
      (make-curve)                          ; curve
      0.0                                   ; curve-valid — unproven
      (online-subspace dims 4)             ; 4 components for engram gating
      0                                     ; recalib-wins
      0                                     ; recalib-total
      0)))                                  ; last-recalib-count

;; ── observe-candle ─────────────────────────────────────────────────
;; Returns: (thought : Vector, prediction : Prediction, edge : f64,
;;           misses : Vec<(ThoughtAST, Vector)>)
;; FOUR values as a list.
;;
;; candle-window: a slice of recent candles — the post slices based on
;; the window sampler's output. The observer encodes, updates noise,
;; strips noise, predicts.

(define (observe-candle [obs : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [ctx : Ctx])
  : (Vector, Prediction, f64, Vec<(ThoughtAST, Vector)>)
  (let* ((candle (last candle-window))
         ;; Collect fact ASTs from vocab modules matching this lens
         (fact-asts (match (:lens obs)
                      (:momentum    (encode-momentum-facts candle))
                      (:structure   (encode-structure-facts candle))
                      (:volume      (encode-volume-facts candle))
                      (:narrative   (encode-narrative-facts candle))
                      (:regime      (encode-regime-facts candle))
                      (:generalist  (append
                                      (encode-momentum-facts candle)
                                      (encode-structure-facts candle)
                                      (encode-volume-facts candle)
                                      (encode-narrative-facts candle)
                                      (encode-regime-facts candle)))))
         ;; Wrap in a Bundle AST and encode
         (bundle-ast (Bundle fact-asts))
         ((raw-thought misses) (encode (:thought-encoder ctx) bundle-ast))
         ;; Update noise subspace with the raw thought
         (_ (update (:noise-subspace obs) raw-thought))
         ;; Strip noise
         (thought (strip-noise obs raw-thought))
         ;; Predict
         (pred (predict (:reckoner obs) thought)))
    (list thought pred (:curve-valid obs) misses)))

;; ── strip-noise ────────────────────────────────────────────────────
;; Remove the background model from a thought. What remains is unusual.

(define (strip-noise [obs : MarketObserver] [thought : Vector])
  : Vector
  (let ((noise (anomalous-component (:noise-subspace obs) thought)))
    (difference thought noise)))

;; ── resolve ────────────────────────────────────────────────────────
;; The actual direction is routed back from resolved trades/papers.
;; The reckoner learns from reality. The curve records the prediction.
;; Engram gating checks for good discriminant states.

(define (resolve [obs : MarketObserver]
                 [thought : Vector]
                 [direction : Direction]
                 [weight : f64])
  ;; Reckoner learns the actual direction
  (let ((label (match direction (:up "Up") (:down "Down"))))
    (observe (:reckoner obs) thought label weight))
  ;; Curve records the prediction
  (let* ((pred (predict (:reckoner obs) thought))
         (conviction (match pred
                       ((Discrete _ c) c)
                       ((Continuous _ _) 0.0)))
         (correct (match direction
                    (:up   (match pred
                             ((Discrete scores _)
                               (> (second (first (filter (lambda (p) (= (first p) "Up")) scores)))
                                  (second (first (filter (lambda (p) (= (first p) "Down")) scores)))))
                             ((Continuous _ _) false)))
                    (:down (match pred
                             ((Discrete scores _)
                               (> (second (first (filter (lambda (p) (= (first p) "Down")) scores)))
                                  (second (first (filter (lambda (p) (= (first p) "Up")) scores)))))
                             ((Continuous _ _) false))))))
    (record-prediction (:curve obs) conviction correct)
    ;; Update cached edge
    (set! (:curve-valid obs) (edge-at (:curve obs) conviction)))
  ;; Increment resolved count
  (inc! (:resolved obs))
  ;; Engram gating
  (let* ((outcome (match direction (:up :grace) (:down :grace)))  ; outcome for engram check
         ((new-wins new-total new-last)
           (check-engram-gate
             (:reckoner obs)
             (:good-state-subspace obs)
             (:recalib-wins obs)
             (:recalib-total obs)
             (:last-recalib-count obs)
             outcome
             "Up")))
    (set! (:recalib-wins obs) new-wins)
    (set! (:recalib-total obs) new-total)
    (set! (:last-recalib-count obs) new-last)))

;; ── experience ─────────────────────────────────────────────────────
;; How much has this observer learned?

(define (experience [obs : MarketObserver])
  : f64
  (experience (:reckoner obs)))
