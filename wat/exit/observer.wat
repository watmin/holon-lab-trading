;; -- exit/observer.wat -- judgment over market thoughts ----------------------
;;
;; The exit observer asks a different question than the market observer.
;; Market observer: "which direction?"
;; Exit observer:   "how do I maximize the residue of this trade?"
;;
;; The exit observer has a judgment vocabulary and a LearnedStop.
;; The vocabulary composes market thoughts with judgment facts.
;; The LearnedStop predicts optimal exit distance from composed thoughts.
;;
;; The LearnedStop IS the exit observer's brain.
;; recommended_distance(composed_thought) is its prediction.
;; observe(composed_thought, optimal_distance, weight) is its learning.
;;
;; One LearnedStop per exit observer. M instances. Not N×M.
;; The composed thought carries the market observer's signal in superposition.
;; The cosine-weighted regression recovers the right distance for each kind
;; of thought — the market identity is embedded in the query.

(require core/primitives)

;; -- Lens (enum) --------------------------------------------------------------
;; Each exit observer has a judgment lens — what it looks for in the environment.
;; Not "which way?" but "is now a good time, and how much room?"

(enum exit-lens :volatility :structure :timing :exit-generalist)

;; -- State --------------------------------------------------------------------
;; The exit observer wraps a LearnedStop. That is its brain.
;; It has a vocabulary. That is its identity.
;; It predicts distance. It learns from propagation.

(struct exit-observer
  lens                   ; exit-lens enum — which judgment vocabulary
  learned-stop)          ; LearnedStop — nearest neighbor regression on (thought, distance)

;; -- Construction -------------------------------------------------------------

(define (new-exit-observer lens max-pairs default-distance)
  "Create an exit observer with a fresh LearnedStop."
  (exit-observer
    :lens lens
    :learned-stop (new-learned-stop max-pairs default-distance)))

;; -- Prediction ---------------------------------------------------------------
;; The exit observer's prediction: what distance maximizes residue
;; for a composed thought like this one?

(define (recommended-distance exit-obs composed-thought)
  "Query the LearnedStop with a composed thought.
   Returns the cosine-weighted average of distances from similar thoughts.
   Returns default-distance when the LearnedStop is empty — ignorance."
  (query (:learned-stop exit-obs) composed-thought))

;; -- Learning -----------------------------------------------------------------
;; Fed by the tuple journal's propagation when papers or trades resolve.
;; The tuple journal computes optimal distance from hindsight.
;; The exit observer's LearnedStop accumulates (thought, distance, weight).

(define (observe-distance exit-obs composed-thought optimal-distance weight)
  "The exit observer learns. Fed by tuple journal propagation."
  (observe (:learned-stop exit-obs) composed-thought optimal-distance weight))

(define (experienced? exit-obs)
  "Has the exit observer accumulated any pairs? If not, it returns default."
  (> (pair-count (:learned-stop exit-obs)) 0))

;; -- Judgment vocabulary ------------------------------------------------------
;;
;; The exit observer encodes judgment facts from the candle.
;; These facts describe whether the environment is favorable for ANY entry,
;; regardless of direction. Not "which way?" but "is now a good time?"
;;
;; Each exit lens sees a subset. The exit generalist sees all.
;; The functions are pure: candle in, facts out. No state. No vectors.

(define (encode-exit-facts exit-obs candle ctx)
  "Encode judgment facts for this lens. Returns a list of fact vectors."
  (match (:lens exit-obs)
    :volatility      (encode-volatility-facts candle ctx)
    :structure       (encode-structure-facts candle ctx)
    :timing          (encode-timing-facts candle ctx)
    :exit-generalist (append (encode-volatility-facts candle ctx)
                             (encode-structure-facts candle ctx)
                             (encode-timing-facts candle ctx))))

(define (encode-volatility-facts candle ctx)
  "Volatility judge: is the environment stable enough to trade?"
  (let ((enc (lambda (name value scale)
               (bind (atom name) (encode-linear value scale)))))
    (list
      (enc "atr-regime"    (:atr-r candle) 0.1)
      (enc "atr-ratio"     (/ (:atr candle) (max (:sma20 candle) 1.0)) 0.1)
      (enc "squeeze-state" (:squeeze candle) 1.0))))

(define (encode-structure-facts candle ctx)
  "Structure judge: is the structure clear enough to exploit?"
  (let ((enc (lambda (name value scale)
               (bind (atom name) (encode-linear value scale)))))
    (list
      (enc "trend-consistency" (:adx candle) 100.0)
      (enc "structure-quality" (:bb-width candle) 0.1))))

(define (encode-timing-facts candle ctx)
  "Timing judge: is the timing right for entry?"
  (let ((enc (lambda (name value scale)
               (bind (atom name) (encode-linear value scale)))))
    (list
      (enc "momentum-state"    (:rsi candle) 100.0)
      (enc "reversal-strength" (abs (:macd-hist candle)) 0.01))))

;; -- Composition --------------------------------------------------------------
;; The exit observer receives a market thought and bundles it with judgment facts.
;; The composed thought is what the LearnedStop sees.

(define (compose exit-obs market-thought exit-fact-vecs)
  "Bundle market thought with pre-computed exit fact vectors.
   The market thought passes THROUGH. The exit observer judges it."
  (apply bundle (cons market-thought exit-fact-vecs)))

;; -- Proposal gate ------------------------------------------------------------
;; The exit observer proposes when it is experienced — when its LearnedStop
;; has accumulated enough pairs to return a meaningful distance.
;; The tuple journal's proof curve gates FUNDING. The exit observer's
;; experience gates PROPOSAL. Both must be satisfied.

(define (can-propose? exit-obs composed-thought)
  "Can this exit observer propose a trade for this thought?
   It must be experienced — the LearnedStop must have pairs."
  (experienced? exit-obs))

;; -- Learning flow ------------------------------------------------------------
;;
;; On paper resolution (in tuple journal tick-papers):
;;   1. Paper resolves — the market decided Grace or Violence
;;   2. compute-optimal-distance from hindsight price history
;;   3. propagate routes optimal distance to THIS exit observer
;;   4. observe-distance(composed-thought, optimal-distance, weight)
;;   5. The LearnedStop accumulates the pair — the exit observer got smarter
;;
;; On real trade resolution (in step-resolve):
;;   Same path. The most honest signal.
;;
;; On active trade management (in step-process):
;;   1. Market observer encodes fresh thought
;;   2. Exit observer composes with judgment facts
;;   3. recommended-distance(composed) → the exit observer's prediction
;;   4. The trailing stop adjusts to the learned distance
;;
;; The market observer's signal is IN the composed thought.
;; Different market observers produce different regions on the sphere.
;; The cosine regression naturally separates them.
;; One LearnedStop handles N market pairings through the algebra.

;; -- What the exit observer does NOT have ------------------------------------
;;
;; No journal.          It predicts distance, not direction. Not Grace/Violence.
;; No noise subspace.   The tuple journal has its own noise model.
;; No pending buffer.   Papers live on the tuple journal.
;; No DualExcursion.    Papers on the tuple journal track excursions.
;; No proof curve.      The tuple journal's proof curve gates funding.
;;                      The exit observer's experience gates proposals.
;;
;; 005 and 006 described the exit observer as a full observer with its own
;; encoding pipeline, its own journal, its own noise subspace. 007 simplified:
;; the exit observer is a regression, not a journal. The intelligence is in
;; the (thought, distance) pairs, not in a separate thought about the thought.
