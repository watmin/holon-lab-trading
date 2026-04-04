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
(define NOISE_RESIDUAL_THRESHOLD 0.1) ;; residual norm below this → thought is boring

;; -- Lens (enum) -----------------------------------------------------------
;; The compiler guards renames — no silent string mismatches.
;; Each lens selects which eval methods fire during thought encoding.

(enum lens :momentum :structure :volume :narrative :regime :generalist)

;; -- State ------------------------------------------------------------------

(struct observer
  lens                   ; lens enum — which vocabulary this observer thinks through
  journal                ; Journal -- Template 1: learns Win/Loss from residual
  noise-subspace         ; OnlineSubspace -- Template 2: learns boring thought patterns from Noise outcomes
  resolved               ; (deque (conviction, correct)) -- resolved predictions
  good-state-subspace    ; OnlineSubspace -- engram of discriminant states with > 55% accuracy
  recalib-wins           ; u32 -- wins since last recalibration
  recalib-total          ; u32 -- total since last recalibration
  last-recalib-count     ; usize -- tracks when journal recalibrates
  window-sampler         ; WindowSampler -- deterministic log-uniform window selection
  conviction-history     ; (deque f64) -- recent conviction values, cap 2000
  conviction-threshold   ; f64 -- dynamic quantile threshold for flip zone
  primary-label          ; Label -- first registered label (Win)
  curve-valid            ; bool -- proof gate: has this observer proven predictive edge?
  cached-acc)            ; f64 -- rolling accuracy of resolved predictions, updated on resolve

;; Two OnlineSubspace instances, different purposes:
;;   noise-subspace:      operates on THOUGHT vectors. Learns what fact compositions are boring.
;;                        Updated on Noise outcomes. Used to strip noise before journal sees it.
;;   good-state-subspace: operates on DISCRIMINANT vectors. Learns what good journal states look like.
;;                        Updated on good recalibrations. Used for engram gating.

(struct resolve-log
  name conviction direction correct)

;; -- Construction -----------------------------------------------------------

(define (new-observer lens dims recalib-interval seed)
  "Create an observer with Win/Loss labels."
  (let ((jrnl (journal lens dims recalib-interval))
        (win-label (register jrnl "Win"))
        (loss-label (register jrnl "Loss")))
    (observer
      :lens lens
      :journal jrnl :primary-label win-label
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
;; The noise subspace learns from Noise outcomes — candles where the simulated
;; position produced no decisive outcome, OR where the thought was boring
;; (low residual norm) regardless of position result.

(define (strip-noise observer thought)
  "Project thought onto noise manifold, subtract, L2-normalize the residual.
   Monotonic warmup: pass through unfiltered until min-samples reached."
  (if (< (n (:noise-subspace observer)) NOISE_MIN_SAMPLES)
      thought  ;; warmup: unfiltered passthrough
      (let ((noise (project (:noise-subspace observer) thought)))
        (l2-normalize (difference thought noise)))))

(define (residual-norm observer thought)
  "Measure how much signal remains after noise subtraction.
   High norm = unusual thought. Low norm = boring thought.
   Used by the labeling function to classify stop-outs."
  (if (< (n (:noise-subspace observer)) NOISE_MIN_SAMPLES)
      1.0  ;; warmup: treat all thoughts as unusual
      (let ((noise (project (:noise-subspace observer) thought)))
        (l2-norm (difference thought noise)))))

(define (observe-candle observer candles vm)
  "The full observer pipeline: encode → strip noise → predict."
  (let ((thought (encode-thought candles vm (:lens observer)))
        (residual (strip-noise observer thought)))
    (predict (:journal observer) residual)))

;; -- Outcome simulation --------------------------------------------------------
;;
;; Pure function: given an entry point and subsequent candles, simulate what
;; a position would have done. No mutable state. No side effects.
;; Returns (outcome, weight) where outcome is :win, :loss, or :noise.

(define (simulate-outcome entry-idx direction candles k-stop k-tp k-trail)
  "Simulate a position from entry-idx through subsequent candles.
   Returns (outcome, weight).

   Win:   TP reached. weight = grace = (peak-rate - tp-rate) / tp-rate.
   Loss:  stop hit violently. weight = violence = actual-loss / stop-distance.
   Noise: horizon expiry or gentle stop.

   The noise subspace provides an additional gate: if the thought's residual
   norm is low (the thought is boring), the outcome is Noise regardless of
   position result. The subspace IS the tolerance boundary."
  (let* ((entry-candle (nth candles entry-idx))
         (entry-rate   (if (= direction :buy)
                           (:close entry-candle)
                           (/ 1.0 (:close entry-candle))))
         (entry-atr    (:atr-r entry-candle))
         (stop-level   (* entry-rate (- 1.0 (* k-stop entry-atr))))
         (tp-level     (* entry-rate (+ 1.0 (* k-tp entry-atr))))
         (trail-stop   stop-level)
         (extreme-rate entry-rate)
         (horizon      (min (* k-tp k-tp) 2000))  ;; diffusion bound with hard cap
         (end-idx      (min (+ entry-idx horizon) (len candles))))

    ;; Fold over subsequent candles: pure, no mutation
    (fold-candles entry-idx end-idx candles
      (lambda (candle-idx)
        (let* ((c (nth candles candle-idx))
               (rate (if (= direction :buy) (:close c) (/ 1.0 (:close c))))
               ;; Trail stop upward
               (new-extreme (max extreme-rate rate))
               (new-trail   (max trail-stop (* new-extreme (- 1.0 (* k-trail entry-atr))))))

          (cond
            ;; Stop hit
            ((<= rate new-trail)
             (let ((actual-loss (/ (- entry-rate rate) entry-rate))
                   (stop-dist  (* k-stop entry-atr)))
               (let ((violence (/ actual-loss stop-dist)))
                 (list :stop violence))))

            ;; TP hit
            ((>= rate tp-level)
             (let ((grace (/ (- new-extreme tp-level) tp-level)))
               (list :tp grace)))

            ;; Continue
            (else
             (set! extreme-rate new-extreme)
             (set! trail-stop new-trail)
             false))))

    ;; If fold completes without stop or TP → Noise (horizon expiry)
    (list :noise 0.0)))

(define (classify-outcome sim-result residual-norm)
  "Apply the noise subspace gate to the simulation result.
   The subspace IS the tolerance boundary:
     - Boring thought (low residual) + any result → Noise
     - Unusual thought (high residual) + TP hit → Win (weight = grace)
     - Unusual thought (high residual) + stop hit → Loss (weight = violence)
     - Horizon expiry → Noise"
  (if (< residual-norm NOISE_RESIDUAL_THRESHOLD)
      ;; Boring thought — noise subspace explains it. Noise regardless.
      (list :noise 0.0)
      ;; Unusual thought — classify by position outcome
      (match (first sim-result)
        :tp   (list :win (second sim-result))     ;; grace
        :stop (list :loss (second sim-result))    ;; violence
        :noise (list :noise 0.0))))

;; -- Resolve ----------------------------------------------------------------

;; The central method. Handles: learning, accuracy tracking, engram gating,
;; curve validation, conviction threshold update, resolved prediction tracking.
;; Returns a resolve-log if the observer had a directional prediction.
;;
;; Labels are outcome-based (proposal 004):
;;   Win:  the simulated position reached TP. Grace-weighted.
;;   Loss: the simulated position stopped out violently. Violence-weighted.
;;   Noise: boring thought or gentle stop or horizon expiry. Teaches noise subspace.
;;
;; The noise subspace IS the tolerance boundary. No magic tolerance_factor.
;; If the thought's residual norm is low, the outcome is Noise regardless.

(define (resolve observer thought-vec prediction outcome weight
                 conviction-quantile conviction-window)
  "Resolve a prediction against an observed outcome.
   Learning splits by outcome:
     Noise → teach the noise subspace what's boring (raw thought)
     Win   → teach the journal from residual (weighted by grace)
     Loss  → teach the journal from residual (weighted by violence)"

  ;; 1. Learn: split by outcome type
  (match outcome
    :noise
      ;; Noise: the thought was boring or the market didn't commit
      (update (:noise-subspace observer) thought-vec)
    :win
      ;; Win: strip noise, teach journal the residual, weighted by grace
      (let ((residual (strip-noise observer thought-vec)))
        (observe (:journal observer) residual (:primary-label observer) weight))
    :loss
      ;; Loss: strip noise, teach journal the residual, weighted by violence
      (let ((residual (strip-noise observer thought-vec))
            (loss-label (second (labels (:journal observer)))))
        (observe (:journal observer) residual loss-label weight)))

  ;; 2. Track accuracy since last recalib (for engram gating)
  (when (:direction prediction)
    (inc! (:recalib-total observer))
    (when (= (:direction prediction) outcome)
      (inc! (:recalib-wins observer))))

  ;; 3. Engram gating: if observer just recalibrated with good accuracy,
  ;;    snapshot the discriminant as a "good state"
  (when (> (recalib-count (:journal observer)) (:last-recalib-count observer))
    (set! (:last-recalib-count observer) (recalib-count (:journal observer)))
    (when (and (>= (:recalib-total observer) 20)
              (> (/ (:recalib-wins observer) (:recalib-total observer)) 0.55))
      (when-let ((disc (discriminant (:journal observer) (:primary-label observer))))
        (update (:good-state-subspace observer) disc)))
    (set! (:recalib-wins observer) 0)
    (set! (:recalib-total observer) 0))

  ;; 4-7 only if observer had a directional prediction
  (when-let ((pred-dir (:direction prediction)))
    (let ((correct (= pred-dir outcome)))

      ;; 4. Track resolved predictions
      (push-back (:resolved observer) (pred-dir correct))
      (when (> (len (:resolved observer)) conviction-window)
        (pop-front (:resolved observer)))

      ;; 5. Update conviction history + threshold
      (push-back (:conviction-history observer) (:conviction prediction))
      (when (> (len (:conviction-history observer)) conviction-window)
        (pop-front (:conviction-history observer)))
      (when (and (>= (len (:conviction-history observer)) 200)
                (= (mod (len (:resolved observer)) 50) 0))
        (set! (:conviction-threshold observer)
              (quantile (:conviction-history observer) conviction-quantile)))

      ;; 6. Proof gate: does this observer have predictive edge?
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
;;   | Market    | RSI, MACD, harmonics, regime, ...    | Win / Loss         |
;;   | Risk      | drawdown, accuracy, streak, ...      | Healthy / Unhealthy|
;;   | Exit      | P&L, hold duration, MFE, stop, ...   | Hold / Exit        |
;;
;; The pipeline is the same: facts → noise subspace → residual → journal.
;; The vocabulary is configuration. The manager sees (name, direction, conviction).
;;
;; The noise subspace and the journal are coupled through strip-noise:
;; the journal sees thought MINUS noise-model. A fibered dependency —
;; the journal operates on a fiber over the noise subspace's state.
;; What the noise subspace learns changes what the journal sees.
;; (Proposal 004, Resolution: Grothendieck construction, not entanglement.)

;; -- Johnson-Lindenstrauss regime ----------------------------------------------
;;
;; Every thought vector lives on the surface of a D-dimensional unit sphere.
;; JL lemma guarantees that D = O(log N / epsilon^2) dimensions preserve
;; pairwise distances among N fact combinations. At D=10,000 and ~53 facts
;; with scalar encodings, the structure is preserved with high fidelity.
;; The codebook atoms are labeled points on the sphere. The prototypes are
;; centroids. The discriminant separates Win from Loss on the sphere.

;; -- What observers do NOT do -----------------------------------------------
;; - Do NOT decide trades (that's the manager + treasury)
;; - Do NOT encode candle data themselves (that's ThoughtEncoder)
;; - Do NOT see other observers' predictions (they are independent)
;; - Do NOT manage positions (that's the position lifecycle)
;; - They perceive, filter noise, learn from the residual, and offer opinions.
