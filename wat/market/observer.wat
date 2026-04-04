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
  journal                ; Journal -- Template 1: learns Win/Loss from residual
  noise-subspace         ; OnlineSubspace -- Template 2: learns the texture of all thoughts
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
  cached-accuracy)       ; f64 -- rolling accuracy of resolved predictions, updated on resolve

;; Two OnlineSubspace instances, different purposes:
;;   noise-subspace:      operates on THOUGHT vectors. Learns from ALL thoughts, every candle.
;;                        The background model. Captures the average texture of thought-space.
;;                        Used to strip noise before journal sees it.
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
;; The noise subspace learns from ALL thoughts, every candle. It is the
;; background model — what thoughts normally look like. The residual after
;; subtraction is what's UNUSUAL about this candle. The journal learns only
;; from resolved simulations (Win/Loss), weighted by grace and violence,
;; scaled by residual norm.

(define (strip-noise observer thought)
  "Subtract noise manifold, L2-normalize the residual.
   Monotonic warmup: pass through unfiltered until min-samples reached."
  (if (< (sample-count (:noise-subspace observer)) NOISE_MIN_SAMPLES)
      thought  ;; warmup: unfiltered passthrough
      (l2-normalize (anomalous-component (:noise-subspace observer) thought))))

(define (residual-norm observer thought)
  "Measure how much signal remains after noise subtraction.
   High norm = unusual thought. Low norm = boring thought.
   Scales the learning weight: boring thoughts teach softly, unusual thoughts teach hard."
  (if (< (sample-count (:noise-subspace observer)) NOISE_MIN_SAMPLES)
      1.0  ;; warmup: treat all thoughts as unusual
      (l2-norm (anomalous-component (:noise-subspace observer) thought))))

(define (observe-candle observer candles vm)
  "The full observer pipeline: encode → update noise subspace → strip noise → predict.
   The noise subspace learns from EVERY thought (background model)."
  (let ((thought (encode-thought candles vm (:lens observer))))
    ;; Noise subspace sees every thought — it learns the texture
    (update (:noise-subspace observer) thought)
    ;; Journal sees the residual — what's unusual
    (let ((residual (strip-noise observer thought)))
      (predict (:journal observer) residual))))

;; -- Outcome: MFE vs MAE -------------------------------------------------------
;;
;; The market tells us the label. Not the simulation.
;; Every pending entry tracks two values as it ages:
;;   max-favorable-excursion (MFE): biggest move in our direction
;;   max-adverse-excursion   (MAE): biggest move against us
;;
;; At horizon drain, the question is binary:
;;   MFE > |MAE|  →  Win  (the trade went right before it went wrong)
;;   MFE ≤ |MAE|  →  Loss (the trade went wrong before it went right)
;;
;; Weight = |MFE - |MAE|| — how decisively the market answered.
;; Strong favorable-first = high weight Win. The journal learns hard.
;; Near the boundary = ambiguous. The journal learns softly.
;;
;; This produces ~50/50 labels in a random walk.
;; Deviations from 50/50 are real signal — that's what the journal learns.
;;
;; No k-stop, k-tp, k-trail in the label. Those exist for position management
;; (ManagedPosition lifecycle), not for observer learning.
;; The observers learn what the market DOES, not what we parameterized.

(define (classify-excursion mfe mae)
  "Classify a pending entry's excursion into Win or Loss.
   mfe: max favorable excursion (positive).
   mae: max adverse excursion (negative).
   Returns (:win weight) or (:loss weight)."
  (let ((favorable-first (> mfe (abs mae)))
        (weight (max (abs (- mfe (abs mae))) 0.01)))
    (if favorable-first
        (list :win weight)
        (list :loss weight))))

;; -- Resolve ----------------------------------------------------------------

;; The central method. Handles: learning, accuracy tracking, engram gating,
;; curve validation, conviction threshold update, resolved prediction tracking.
;; Returns a resolve-log if the observer had a directional prediction.
;;
;; Labels are excursion-based (discovered from data analysis):
;;   Win:  MFE > |MAE| — the trade went right before it went wrong (84% profitable)
;;   Loss: MFE ≤ |MAE| — the trade went wrong before it went right (16% profitable)
;;
;; No Outcome::Noise. The noise subspace learns from ALL thoughts every candle
;; (in observe-candle). The journal learns only at horizon drain.
;; Weight = |MFE - |MAE|| — how decisively the market spoke.

(define (resolve observer thought-vec prediction outcome weight
                 conviction-quantile conviction-window)
  "Resolve a prediction against an observed outcome.
   outcome: :win or :loss (from classify-excursion at horizon drain).
   weight: |MFE - |MAE|| — decisiveness of the market's answer."

  ;; 1. Learn: journal sees the residual, weighted by outcome magnitude
  (let ((residual (strip-noise observer thought-vec))
        (win-label (:primary-label observer))
        (loss-label (second (labels (:journal observer)))))
    (match outcome
      :win  (observe (:journal observer) residual win-label weight)
      :loss (observe (:journal observer) residual loss-label weight)))

  ;; 2. Track accuracy since last recalib (for engram gating)
  (let ((correct (= outcome :win)))
    (when (:direction prediction)
      (inc! (:recalib-total observer))
      (when correct (inc! (:recalib-wins observer))))

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

      ;; 4. Track resolved predictions
      (push-back (:resolved observer) (list (:conviction prediction) correct))
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

;; -- Learning flow summary ---------------------------------------------------
;;
;; Every candle:
;;   1. Encode thought from candle window
;;   2. noise-subspace.update(thought)       ← learns from ALL thoughts
;;   3. residual = strip-noise(thought)
;;   4. prediction = journal.predict(residual)
;;   5. Buffer (thought, prediction, MFE=0, MAE=0) in pending ring buffer
;;
;; Each pending entry, each candle:
;;   6. Track MFE (max favorable excursion) and MAE (max adverse excursion)
;;
;; At horizon drain (max-pending-age reached):
;;   7. classify-excursion(MFE, MAE) → Win or Loss
;;   8. weight = |MFE - |MAE|| — how decisive the market was
;;   9. observer.resolve(thought, prediction, outcome, weight)
;;   10. Remove from pending
;;
;; The noise subspace is the background model (every candle).
;; The journal is the foreground model (horizon drain only).
;; Weight scales by decisiveness — ambiguous trades teach softly.
;; ~50/50 Win/Loss in a random walk. Deviations are signal.

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

;; -- Transparency -------------------------------------------------------------
;;
;; The prediction and the explanation are the same operation.
;; predict(thought) → (label, cosine) for each label.
;; cosine(discriminant, atom) → which facts drove the prediction.
;; Same vector. Same cosine. Same algebra.
;; The glass box. Nothing to explain because nothing is hidden.

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
