;; -- market/observer.wat -- a leaf node in the enterprise tree ---------------
;;
;; Each observer thinks different thoughts at their own time scale.
;; The manager aggregates their predictions -- it does not encode candle data.
;; Observers perceive, they don't decide.

(require core/primitives)
(require core/structural)
(require journal)
(require window-sampler)

;; -- Lens (enum) -----------------------------------------------------------
;; The compiler guards renames — no silent string mismatches.
;; Each lens selects which eval methods fire during thought encoding.

(enum lens :momentum :structure :volume :narrative :regime :generalist)

;; -- State ------------------------------------------------------------------

(struct observer
  lens                   ; lens enum — which vocabulary this observer thinks through
  journal                ; Journal -- the learning primitive
  resolved               ; (deque (conviction, correct)) -- resolved predictions
  good-state-subspace    ; OnlineSubspace -- engram of discriminant states with > 55% accuracy
  recalib-wins           ; u32 -- wins since last recalibration
  recalib-total          ; u32 -- total since last recalibration
  last-recalib-count     ; usize -- tracks when journal recalibrates
  window-sampler         ; WindowSampler -- deterministic log-uniform window selection
  conviction-history     ; (deque f64) -- recent conviction values, cap 2000
  conviction-threshold   ; f64 -- dynamic quantile threshold for flip zone
  primary-label          ; Label -- first registered label (for discriminant access)
  curve-valid            ; bool -- proof gate: has this observer proven direction edge?
  cached-acc)            ; f64 -- rolling accuracy of resolved predictions, updated on resolve

(struct resolve-log
  name conviction direction correct)

;; -- Construction -----------------------------------------------------------

(define (new-observer lens dims recalib-interval seed labels)
  "Create an observer with its own journal and window sampler."
  (let ((jrnl (journal lens dims recalib-interval))
        (primary-label (register jrnl (first labels))))
    ;; Register remaining labels
    (for-each (lambda (l) (register jrnl l)) (rest labels))
    (observer
      :lens lens
      :journal jrnl :primary-label primary-label
      :resolved (deque) :good-state-subspace (online-subspace dims 8)
      :recalib-wins 0 :recalib-total 0 :last-recalib-count 0
      :window-sampler (window-sampler seed 12 2016)
      :conviction-history (deque) :conviction-threshold 0.0
      :curve-valid false)))

;; -- Resolve ----------------------------------------------------------------

;; The central method. Handles: learning, accuracy tracking, engram gating,
;; curve validation, conviction threshold update, resolved prediction tracking.
;; Returns a resolve-log if the observer had a directional prediction.

(define (resolve observer thought-vec prediction outcome signal-weight
                 conviction-quantile conviction-window)
  "Resolve a prediction against an observed outcome."

  ;; 1. Learn: accumulate this observation
  (observe (:journal observer) thought-vec outcome signal-weight)

  ;; 2. Track accuracy since last recalib (for engram gating)
  (when (:direction prediction)
    (inc! (:recalib-total observer))
    (when (= (:direction prediction) outcome)
      (inc! (:recalib-wins observer))))

  ;; 3. Engram gating: if observer just recalibrated with good accuracy,
  ;;    snapshot the discriminant as a "good state"
  ;; recalib-count: Journal method. Returns how many times the journal
  ;; has recalibrated (rebuilt prototypes). Integer, monotonically increasing.
  ;; discriminant: Journal method. Returns the difference vector between
  ;; two label prototypes: discriminant(label) = prototype(label) - prototype(other).
  ;; The discriminant IS the journal's learned separation. None if < 2 labels registered.
  (when (> (recalib-count (:journal observer)) (:last-recalib-count observer))
    (set! (:last-recalib-count observer) (recalib-count (:journal observer)))
    (when (and (>= (:recalib-total observer) 20)
              (> (/ (:recalib-wins observer) (:recalib-total observer)) 0.55))
      (when-let ((disc (discriminant (:journal observer) (:primary-label observer))))
        (update (:good-state-subspace observer) disc)))
    (set! (:recalib-wins observer) 0)
    (set! (:recalib-total observer) 0))

  ;; 4-7 only if observer had a directional prediction
  ;; accuracy: fraction of correct predictions in a sequence of (conviction, correct) pairs.

  (when-let ((pred-dir (:direction prediction)))
    (let ((correct (= pred-dir outcome)))

      ;; 4. Track resolved predictions
      (push-back (:resolved observer) (pred-dir correct))
      (when (> (len (:resolved observer)) conviction-window)
        (pop-front (:resolved observer)))

      ;; 5. Update conviction history + threshold
      ;; Rust passes conviction_window through CandleContext; observer.resolve() uses it.
      (push-back (:conviction-history observer) (:conviction prediction))
      (when (> (len (:conviction-history observer)) conviction-window)
        (pop-front (:conviction-history observer)))
      (when (and (>= (len (:conviction-history observer)) 200)
                (= (mod (len (:resolved observer)) 50) 0))
        (set! (:conviction-threshold observer)
              (quantile (:conviction-history observer) conviction-quantile)))

      ;; 6. Proof gate: does this observer have direction edge?
      (when (>= (len (:resolved observer)) 100)
        (let ((high-conv (filter (lambda (r) (>= (first r) (* (:conviction-threshold observer) 0.8)))
                                 (:resolved observer))))
          (when (>= (len high-conv) 20)
            (set! (:curve-valid observer)
                  (> (/ (count (lambda (r) (second r)) high-conv)
                        (len high-conv))
                     0.52)))))

      ;; 7. Return log data
      (resolve-log :name (:name observer)
                   :conviction (:conviction prediction)
                   :direction pred-dir
                   :correct correct))))

;; -- What observers do NOT do -----------------------------------------------
;; - Do NOT decide trades (that's the manager + treasury)
;; - Do NOT encode candle data themselves (that's ThoughtEncoder)
;; - Do NOT see other observers' predictions (they are independent)
;; - Do NOT manage positions (that's the position lifecycle)
;; - They perceive, learn, and offer opinions. That's all.
