;; ── market-observer.wat ─────────────────────────────────────────────
;;
;; Predicts direction. Learned. Labels come from broker propagation —
;; the broker routes the actual direction back from resolved paper and
;; real trades. The market observer does NOT label itself. Reality labels it.
;; The generalist is just another lens. No special treatment.
;; Depends on: Reckoner :discrete, OnlineSubspace, WindowSampler,
;;             MarketLens (enums), Ctx, ThoughtEncoder.

(require primitives)
(require enums)
(require window-sampler)
(require engram-gate)
(require ctx)

;; ── Struct ──────────────────────────────────────────────────────────

(struct market-observer
  [lens : MarketLens]
  [reckoner : Reckoner]                ; :discrete — Up/Down
  [noise-subspace : OnlineSubspace]    ; background model
  [window-sampler : WindowSampler]     ; own time scale
  ;; Proof tracking
  [resolved : usize]                   ; how many predictions have been resolved
  ;; The reckoner carries its own curve. resolve() feeds it. edge-at() reads it.
  ;; No separate curve field — use (edge-at (:reckoner obs) conviction) and
  ;; (proven? (:reckoner obs) min-samples).
  ;; Engram gating
  [good-state-subspace : OnlineSubspace] ; learns what good discriminants look like
  [recalib-wins : usize]               ; wins since last recalibration
  [recalib-total : usize]              ; total since last recalibration
  [last-recalib-count : usize]         ; recalib-count at last engram check
  [last-prediction : Direction])       ; set by observe-candle, read by resolve

;; ── Interface ───────────────────────────────────────────────────────

(define (make-market-observer [lens : MarketLens]
                              [dims : usize]
                              [recalib-interval : usize]
                              [window-sampler : WindowSampler])
  : MarketObserver
  ;; Constructs the reckoner internally. noise-subspace: 8 principal components
  ;; for the background model. good-state-subspace: 4 components for engram
  ;; gating (fewer — the good-state manifold is simpler).
  (market-observer
    lens
    (reckoner "direction" dims recalib-interval (Discrete '("Up" "Down")))
    (online-subspace dims 8)
    window-sampler
    0                                  ; resolved
    (online-subspace dims 4)           ; good-state-subspace
    0                                  ; recalib-wins
    0                                  ; recalib-total
    0                                  ; last-recalib-count
    :down))                            ; last-prediction — arbitrary initial

(define (observe-candle [observer : MarketObserver]
                        [candle-window : Vec<Candle>]
                        [ctx : Ctx])
  : (Vector Prediction f64 Vec<(ThoughtAST Vector)>)
  ;; Encode the candle window into a thought. Update noise subspace.
  ;; Strip noise. Predict direction. Store last-prediction for resolve.
  ;; Returns: thought Vector, Prediction (Up/Down), edge (f64),
  ;; and cache misses.
  ;; The post calls (sample (:window-sampler observer) encode-count) to
  ;; get the window size, slices, and passes the slice.
  (let* ((thought misses (encode-thought ctx candle-window (:lens observer)))
         (_              (update (:noise-subspace observer) thought))
         (clean          (strip-noise observer thought))
         (pred           (predict (:reckoner observer) clean))
         (conviction     (match pred
                           ((Discrete _ c) c)))
         (edge           (edge-at (:reckoner observer) conviction)))
    (set! observer :last-prediction
          (match pred
            ((Discrete scores _)
              (if (> (second (first scores)) (second (second scores)))
                  :up :down))))
    (list clean pred edge misses)))

(define (resolve [observer : MarketObserver]
                 [thought : Vector]
                 [direction : Direction]
                 [weight : f64])
  ;; Called by broker propagation — reckoner learns from reality.
  ;; Compares last-prediction against the actual direction.
  ;; Match → correct. Mismatch → incorrect. Feeds the reckoner's
  ;; internal curve via (resolve (:reckoner obs) conviction correct?).
  (let ((correct? (= (:last-prediction observer) direction)))
    (observe (:reckoner observer) thought direction weight)
    ;; Feed the internal curve with conviction and correctness
    (let ((pred (predict (:reckoner observer) thought)))
      (match pred
        ((Discrete _ conviction)
          (resolve (:reckoner observer) conviction correct?))))
    ;; Engram gate — learn from real accuracy
    (inc! observer :resolved)
    (if correct?
        (inc! observer :recalib-wins))
    (inc! observer :recalib-total)
    (let ((gate-state (check-engram-gate
                        (:reckoner observer)
                        (:good-state-subspace observer)
                        (engram-gate-state
                          (:recalib-wins observer)
                          (:recalib-total observer)
                          (:last-recalib-count observer))
                        (:recalib-interval (ctx))
                        0.55)))
      (set! observer :recalib-wins (:recalib-wins gate-state))
      (set! observer :recalib-total (:recalib-total gate-state))
      (set! observer :last-recalib-count (:last-recalib-count gate-state)))))

(define (strip-noise [observer : MarketObserver]
                     [thought : Vector])
  : Vector
  ;; Return the anomalous component — what the noise subspace CANNOT explain.
  ;; The residual IS the signal. The reckoner learns from what is unusual,
  ;; not what is normal.
  (anomalous-component (:noise-subspace observer) thought))

(define (experience [observer : MarketObserver])
  : f64
  ;; How much has this observer learned?
  (experience (:reckoner observer)))
