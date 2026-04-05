;; -- tuple-journal.wat -- the accountability primitive -------------------------
;;
;; One journal per tuple of observers. Today the tuple is (market, exit).
;; Tomorrow it could be (market, exit, risk). The arity doesn't matter.
;; The journal measures the tuple's accountability.
;;
;; The tuple journal IS the manager. Not a separate aggregator. Each tuple
;; proposes, owns, manages, and gets judged. The treasury judges the decision.
;; The feedback is realized by the tuple.
;;
;; Labels: Grace / Violence (from treasury reality).
;; Input: the composed thought (market thought bundled with exit judgment).
;; The proof curve gates treasury funding.
;;
;; The tuple journal is a closure over its observers.
;; propagate routes resolved outcomes to EVERY observer in the tuple.
;; The struct is the implementation. The closure is the thought.

(require core/primitives)
(require core/structural)
(require std/memory)           ;; OnlineSubspace
(require journal)
(require exit/observer)        ;; observe-distance (feeds exit observer's LearnedStop)
(require market/observer)      ;; resolve (feeds market observer's journal)

;; -- Constants ----------------------------------------------------------------

(define NOISE_MIN_SAMPLES 50)
(define RESOLVED_CAP 5000)     ;; resolved prediction history cap
(define PAPER_CAP 500)         ;; max concurrent paper entries per tuple

;; -- Paper entry --------------------------------------------------------------
;; A hypothetical trade. Every candle, every tuple gets one.
;; Papers live inside the closure. They are the fast learning stream.

(struct paper-entry
  composed-thought       ; Vector — market thought bundled with exit facts
  entry-price            ; f64 — price at paper creation
  entry-atr              ; f64 — ATR ratio at paper creation
  recommended-distance   ; f64 — what the exit observer predicted at entry
  ;; Dual excursion — both sides tracked
  buy-extreme            ; f64 — best rate in buy direction
  buy-trail-stop         ; f64 — trailing stop for buy side
  sell-extreme           ; f64 — best rate in sell direction
  sell-trail-stop        ; f64 — trailing stop for sell side
  buy-resolved           ; bool
  sell-resolved)         ; bool

;; -- Tuple journal state ------------------------------------------------------

(struct tuple-journal
  ;; Identity — who this tuple is
  market-name            ; string — "momentum", "structure", ...
  exit-name              ; string — "volatility", "timing", ...

  ;; Grace/Violence journal — the pair's accountability
  journal                ; Journal — labels: Grace / Violence
  noise-subspace         ; OnlineSubspace — background model of composed thoughts
  grace-label            ; Label
  violence-label         ; Label

  ;; Track record
  resolved               ; (deque (conviction, correct)) — for proof curve
  conviction-history     ; (deque f64) — cap 2000
  conviction-threshold   ; f64
  curve-valid            ; bool — proof gate
  cached-acc             ; f64

  ;; Cumulative accountability
  cumulative-grace       ; f64
  cumulative-violence    ; f64
  trade-count            ; usize

  ;; Papers — the fast learning stream
  papers                 ; (deque PaperEntry) — capped at PAPER_CAP

  ;; Scalar accumulators — per-magic-number f64 learning
  scalar-accums          ; Vec<ScalarAccumulator> — trail-distance, k-stop, k-tp

  ;; Engram gating
  good-state-subspace    ; OnlineSubspace
  recalib-wins           ; u32
  recalib-total          ; u32
  last-recalib-count)    ; usize

;; -- Construction -------------------------------------------------------------

(define (new-tuple-journal market-name exit-name dims recalib-interval)
  "Create a tuple journal for one (market, exit) pairing."
  (let* ((name (format "tuple-{}-{}" market-name exit-name))
         (jrnl (journal name dims recalib-interval))
         (grace    (register jrnl "Grace"))
         (violence (register jrnl "Violence")))
    (tuple-journal
      :market-name market-name :exit-name exit-name
      :journal jrnl :noise-subspace (online-subspace dims 8)
      :grace-label grace :violence-label violence
      :resolved (deque) :conviction-history (deque)
      :conviction-threshold 0.0 :curve-valid false :cached-acc 0.0
      :cumulative-grace 0.0 :cumulative-violence 0.0 :trade-count 0
      :papers (deque)
      :scalar-accums (list (new-scalar-accumulator "trail-distance")
                           (new-scalar-accumulator "k-stop")
                           (new-scalar-accumulator "k-tp"))
      :good-state-subspace (online-subspace dims 8)
      :recalib-wins 0 :recalib-total 0 :last-recalib-count 0)))

;; -- Two-stage pipeline -------------------------------------------------------

(define (strip-noise tj composed)
  (if (< (sample-count (:noise-subspace tj)) NOISE_MIN_SAMPLES)
      composed
      (l2-normalize (anomalous-component (:noise-subspace tj) composed))))

;; -- Propose ------------------------------------------------------------------
;; The tuple predicts: will this composed thought produce grace or violence?

(define (propose tj composed-thought)
  "Predict grace/violence. Update noise subspace. Return prediction."
  (update (:noise-subspace tj) composed-thought)
  (let ((residual (strip-noise tj composed-thought)))
    (predict (:journal tj) residual)))

;; -- Funding gate -------------------------------------------------------------

(define (funded? tj)
  "Has this tuple proven predictive edge?"
  (:curve-valid tj))

;; -- Register paper -----------------------------------------------------------
;; Every candle, every tuple gets a paper entry.
;; Papers are the fast learning stream — cheap hypothetical trades.

(define (register-paper tj composed-thought entry-price entry-atr k-stop distance)
  "Create a paper entry. Both sides start at entry price."
  (let ((buy-stop  (* entry-price (- 1.0 (* k-stop entry-atr))))
        (sell-stop (* entry-price (+ 1.0 (* k-stop entry-atr)))))
    (push-back (:papers tj)
      (paper-entry
        :composed-thought composed-thought
        :entry-price entry-price :entry-atr entry-atr
        :recommended-distance distance
        :buy-extreme entry-price :buy-trail-stop buy-stop
        :sell-extreme entry-price :sell-trail-stop sell-stop
        :buy-resolved false :sell-resolved false))
    ;; Cap the buffer
    (when (> (len (:papers tj)) PAPER_CAP)
      (pop-front (:papers tj)))))

;; -- Tick papers --------------------------------------------------------------
;; Tick all paper entries with current price. Resolve any where both sides fired.
;; Resolved papers feed BOTH observers via propagate.
;; Returns observations for the exit observer's LearnedStop.

(define (tick-papers tj current-price market-observer exit-observer)
  "Tick all papers. Resolve completed ones. Propagate to both observers."
  (let ((observations '()))
    (for-each (:papers tj)
      (lambda (paper)
        (when (not (and (:buy-resolved paper) (:sell-resolved paper)))
          ;; Tick buy side
          (when (not (:buy-resolved paper))
            (let ((new-extreme (max (:buy-extreme paper) current-price)))
              (set! (:buy-extreme paper) new-extreme)
              (let ((trail (* new-extreme (- 1.0 (:recommended-distance paper)))))
                (set! (:buy-trail-stop paper) (max (:buy-trail-stop paper) trail))))
            (when (<= current-price (:buy-trail-stop paper))
              (set! (:buy-resolved paper) true)))

          ;; Tick sell side
          (when (not (:sell-resolved paper))
            (let ((new-extreme (min (:sell-extreme paper) current-price)))
              (set! (:sell-extreme paper) new-extreme)
              (let ((trail (* new-extreme (+ 1.0 (:recommended-distance paper)))))
                (set! (:sell-trail-stop paper) (min (:sell-trail-stop paper) trail))))
            (when (>= current-price (:sell-trail-stop paper))
              (set! (:sell-resolved paper) true)))

          ;; Both resolved → learn
          (when (and (:buy-resolved paper) (:sell-resolved paper))
            (let* ((buy-ret  (/ (- (:buy-extreme paper) (:entry-price paper))
                                (:entry-price paper)))
                   (sell-ret (/ (- (:entry-price paper) (:sell-extreme paper))
                                (:entry-price paper)))
                   (grace    (> (max buy-ret sell-ret) 0.0))
                   (amount   (abs (max buy-ret sell-ret)))
                   (outcome  (if grace :grace :violence))
                   ;; Compute optimal distance from hindsight
                   (optimal  (compute-optimal-distance-from-paper paper)))

              ;; Propagate to both observers
              (propagate tj (:composed-thought paper) outcome amount
                         optimal market-observer exit-observer)

              ;; Collect observation for exit observer's LearnedStop
              (when optimal
                (push! observations
                  (list (:composed-thought paper)
                        (:distance optimal)
                        (:weight optimal)))))))))

    ;; Drain resolved papers from front
    (while (and (not (empty? (:papers tj)))
                (let ((p (first (:papers tj))))
                  (and (:buy-resolved p) (:sell-resolved p))))
      (pop-front (:papers tj)))

    observations))

;; -- Propagate ----------------------------------------------------------------
;; The heart of the closure. Routes resolved outcomes to EVERY observer.
;; The tuple journal doesn't predict. It measures and routes.

(define (propagate tj composed-thought outcome amount optimal
                   market-observer exit-observer)
  "Route a resolved outcome to both observers and the track record."

  ;; 1. The tuple journal learns Grace/Violence
  (let ((residual (strip-noise tj composed-thought))
        (label (if (= outcome :grace) (:grace-label tj) (:violence-label tj))))
    (observe (:journal tj) residual label amount))

  ;; 2. Update track record
  (match outcome
    :grace    (set! (:cumulative-grace tj) (+ (:cumulative-grace tj) amount))
    :violence (set! (:cumulative-violence tj) (+ (:cumulative-violence tj) amount)))
  (inc! (:trade-count tj))

  ;; 3. Route to market observer — direction learning (Win/Loss)
  (let ((win (= outcome :grace)))
    (resolve market-observer composed-thought
             (propose tj composed-thought)  ; the prediction at this thought
             (if win :win :loss) amount
             0.6 2000))  ; conviction quantile + window — config, not magic

  ;; 4. Route to exit observer — distance learning
  (when optimal
    (observe-distance exit-observer composed-thought
                      (:distance optimal) (:weight optimal)))

  ;; 5. Feed scalar accumulators
  (when optimal
    (for-each (:scalar-accums tj)
      (lambda (acc)
        (observe-scalar acc (:distance optimal) (= outcome :grace) amount))))

  ;; 6. Track accuracy + proof curve
  (let ((prediction (propose tj composed-thought))
        (correct (= outcome :grace)))
    (when (:direction prediction)
      (inc! (:recalib-total tj))
      (when correct (inc! (:recalib-wins tj))))

    ;; Engram gating
    (when (> (recalib-count (:journal tj)) (:last-recalib-count tj))
      (set! (:last-recalib-count tj) (recalib-count (:journal tj)))
      (when (and (>= (:recalib-total tj) 20)
                 (> (/ (:recalib-wins tj) (:recalib-total tj)) 0.55))
        (when-let ((disc (discriminant (:journal tj) (:grace-label tj))))
          (update (:good-state-subspace tj) disc)))
      (set! (:recalib-wins tj) 0)
      (set! (:recalib-total tj) 0))

    ;; Resolved predictions + conviction + proof gate
    (when-let ((pred-dir (:direction prediction)))
      (push-back (:resolved tj) (list (:conviction prediction) correct))
      (when (> (len (:resolved tj)) RESOLVED_CAP)
        (pop-front (:resolved tj)))

      (push-back (:conviction-history tj) (:conviction prediction))
      (when (> (len (:conviction-history tj)) 2000)
        (pop-front (:conviction-history tj)))
      (when (and (>= (len (:conviction-history tj)) 200)
                 (= (mod (len (:resolved tj)) 50) 0))
        (set! (:conviction-threshold tj)
              (quantile (:conviction-history tj) 0.6)))

      (when (>= (len (:resolved tj)) 100)
        (let ((high-conv (filter (lambda (r) (>= (first r) (* (:conviction-threshold tj) 0.8)))
                                  (:resolved tj))))
          (when (>= (len high-conv) 20)
            (set! (:curve-valid tj)
                  (> (/ (count (lambda (r) (second r)) high-conv)
                        (len high-conv))
                     0.52))))))))

;; -- Utility ------------------------------------------------------------------

(define (paper-count tj)
  (len (:papers tj)))

;; -- Ownership summary --------------------------------------------------------
;;
;; The tuple journal is a closure over its observers.
;; It does NOT own them. It references them.
;; The enterprise owns the observers. The tuple journal accesses them.
;;
;; The tuple journal owns:
;;   journal              — Grace/Violence (accountability, not prediction)
;;   noise-subspace       — background model of composed thoughts
;;   papers               — the fast learning stream (capped at PAPER_CAP)
;;   scalar-accums        — per-magic-number f64 accumulators
;;   track-record         — cumulative grace/violence
;;   proof curve          — gates proposals
;;
;; The tuple journal does NOT own:
;;   LearnedStop          — that's the exit observer's brain
;;   market journal       — that's the market observer's
;;   the observers        — they live on the enterprise
;;
;; Three learning streams flow through the tuple journal:
;;   1. Paper (fast/cheap)  — tick-papers resolves → propagate to both observers
;;   2. Live management     — treasury queries exit observer for distance each candle
;;   3. Reality (on close)  — step-resolve propagates → both observers learn
;;
;; propagate routes to:
;;   market-observer.resolve(thought, Win/Loss)               — direction learning
;;   exit-observer.observe-distance(thought, optimal, weight)  — exit learning
;;   self.journal.observe(thought, Grace/Violence)             — accountability
;;   self.track-record                                         — cumulative
;;   self.scalar-accums                                        — magic number learning
