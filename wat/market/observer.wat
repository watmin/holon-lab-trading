;; -- market/observer.wat -- a leaf node in the enterprise tree ---------------
;;
;; Each observer thinks different thoughts at their own time scale.
;; The manager aggregates their predictions -- it does not encode candle data.
;; Observers perceive, they don't decide.

(require core/primitives)
(require core/structural)
(require std/memory)           ;; OnlineSubspace
(require journal)
(require window-sampler)

;; -- Constants ----------------------------------------------------------------

(define NOISE_MIN_SAMPLES 50)  ;; minimum noise observations before subspace activates

;; -- Lens (enum) -----------------------------------------------------------
;; The compiler guards renames — no silent string mismatches.
;; Each lens selects which eval methods fire during thought encoding.

(enum lens :momentum :structure :volume :narrative :regime :generalist)

;; -- State ------------------------------------------------------------------

(struct observer
  lens                   ; lens enum — which vocabulary this observer thinks through
  journal                ; Journal -- Template 1: learns Buy/Sell from residual
  noise-subspace         ; OnlineSubspace -- Template 2: learns boring thought patterns from Noise outcomes
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

;; Two OnlineSubspace instances, different purposes:
;;   noise-subspace:      operates on THOUGHT vectors. Learns what fact compositions are boring.
;;                        Updated on Noise outcomes. Used to strip noise before journal sees it.
;;   good-state-subspace: operates on DISCRIMINANT vectors. Learns what good journal states look like.
;;                        Updated on good recalibrations. Used for engram gating.

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
      :noise-subspace (online-subspace dims 8)
      :resolved (deque) :good-state-subspace (online-subspace dims 8)
      :recalib-wins 0 :recalib-total 0 :last-recalib-count 0
      :window-sampler (window-sampler seed 12 2016)
      :conviction-history (deque) :conviction-threshold 0.0
      :curve-valid false)))

;; -- Two-stage pipeline -------------------------------------------------------
;;
;; Every observer uses both templates:
;;   Stage 1: encode all true thoughts from vocabulary → thought vector
;;   Stage 2: strip noise → L2-normalize residual → predict from clean signal
;;
;; The noise subspace learns from Noise outcomes only — candles where price
;; didn't cross the threshold. Those thoughts are definitionally uninformative.
;; The residual after subtraction is what's UNUSUAL about this candle.

(define (strip-noise observer thought)
  "Project thought onto noise manifold, subtract, L2-normalize the residual.
   Monotonic warmup: pass through unfiltered until min-samples reached."
  (if (< (n (:noise-subspace observer)) NOISE_MIN_SAMPLES)
      thought  ;; warmup: unfiltered passthrough
      (let ((noise (project (:noise-subspace observer) thought)))
        (l2-normalize (difference thought noise)))))

(define (observe-candle observer candles vm)
  "The full observer pipeline: encode → strip noise → predict."
  (let ((thought (encode-thought candles vm (:lens observer)))
        (residual (strip-noise observer thought)))
    (predict (:journal observer) residual)))

;; -- Resolve ----------------------------------------------------------------

;; The central method. Handles: learning, accuracy tracking, engram gating,
;; curve validation, conviction threshold update, resolved prediction tracking.
;; Returns a resolve-log if the observer had a directional prediction.

(define (resolve observer thought-vec prediction outcome signal-weight
                 conviction-quantile conviction-window)
  "Resolve a prediction against an observed outcome.
   Learning splits by outcome:
     Noise  → teach the noise subspace what's boring (raw thought, not residual)
     Buy/Sell → teach the journal from clean signal (L2-normalized residual)"

  ;; 1. Learn: split by outcome type
  (if (= outcome :noise)
      ;; Noise: the thought was uninformative — teach the noise subspace
      (update (:noise-subspace observer) thought-vec)
      ;; Buy/Sell: strip noise, normalize, teach the journal from residual
      (let ((residual (strip-noise observer thought-vec)))
        (observe (:journal observer) residual outcome signal-weight)))

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

;; -- The Observer is domain-agnostic -------------------------------------------
;;
;; The two-stage pipeline (noise subspace + journal) is not a market concept.
;; Three configuration axes define what the observer thinks about:
;;
;;   | Domain    | Vocabulary                           | Labels             |
;;   |-----------|--------------------------------------|--------------------|
;;   | Market    | RSI, MACD, harmonics, regime, ...    | Buy / Sell         |
;;   | Risk      | drawdown, accuracy, streak, ...      | Healthy / Unhealthy|
;;   | Exit      | P&L, hold duration, MFE, stop, ...   | Hold / Exit        |
;;
;; The pipeline is the same: facts → noise subspace → residual → journal.
;; The vocabulary is configuration. The manager sees (name, direction, conviction).

;; -- What observers do NOT do -----------------------------------------------
;; - Do NOT decide trades (that's the manager + treasury)
;; - Do NOT encode candle data themselves (that's ThoughtEncoder)
;; - Do NOT see other observers' predictions (they are independent)
;; - Do NOT manage positions (that's the position lifecycle)
;; - They perceive, filter noise, learn from the residual, and offer opinions.
