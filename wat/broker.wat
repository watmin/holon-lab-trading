;; broker.wat — Broker struct + interface
;; Depends on: enums.wat, scalar-accumulator.wat, engram-gate.wat,
;;             paper-entry.wat, distances.wat, thought-encoder.wat

(require primitives)
(require enums)
(require scalar-accumulator)
(require engram-gate)
(require paper-entry)
(require distances)

;; ── PropagationFacts ───────────────────────────────────────────────
;; Values up — what the observers need to learn from this resolution.

(struct propagation-facts
  [market-idx : usize]
  [exit-idx : usize]
  [direction : Direction]
  [composed-thought : Vector]
  [optimal : Distances]
  [weight : f64])

;; ── Resolution ─────────────────────────────────────────────────────
;; What a broker produces when a paper resolves.

(struct resolution
  [broker-slot-idx : usize]
  [composed-thought : Vector]
  [direction : Direction]
  [outcome : Outcome]
  [amount : f64]
  [optimal-distances : Distances])

;; ── Broker ─────────────────────────────────────────────────────────

(struct broker
  [observer-names : Vec<String>]
  [slot-idx : usize]
  [exit-count : usize]
  [reckoner : Reckoner]
  [noise-subspace : OnlineSubspace]
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  [papers : VecDeque<PaperEntry>]
  [scalar-accums : Vec<ScalarAccumulator>]
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

(define (make-broker [observers : Vec<String>]
                     [slot-idx : usize]
                     [exit-count : usize]
                     [dims : usize]
                     [recalib-interval : usize]
                     [scalar-accums : Vec<ScalarAccumulator>])
  : Broker
  (let ((rk (make-reckoner (format "broker-{}" slot-idx)
              dims recalib-interval (Discrete '("Grace" "Violence")))))
    (broker
      observers slot-idx exit-count
      rk
      (online-subspace dims 8)     ; noise
      0.0 0.0 0                    ; track record
      (deque)                      ; papers
      scalar-accums
      (online-subspace dims 4)     ; good-state
      0 0 0)))                     ; engram tracking

;; ── strip-noise — broker's noise removal ───────────────────────────

(define (broker-strip-noise [b : Broker] [thought : Vector])
  : Vector
  (update (:noise-subspace b) thought)
  (anomalous-component (:noise-subspace b) thought))

;; ── propose — predict Grace/Violence from composed thought ─────────

(define (propose [b : Broker] [composed : Vector])
  : Prediction
  (let ((cleaned (broker-strip-noise b composed)))
    (predict (:reckoner b) cleaned)))

;; ── edge — how much edge does this broker have? ────────────────────

(define (broker-edge [b : Broker])
  : f64
  (let ((pred (predict (:reckoner b) (zeros)))
        (conviction (match pred
                      ((Discrete scores conv) conv)
                      ((Continuous val exp) 0.0)))
        (min-samples 100))
    (if (proven? (:reckoner b) min-samples)
      (edge-at (:reckoner b) conviction)
      0.0)))

;; ── register-paper — create a paper entry ──────────────────────────

(define (register-paper [b : Broker]
                        [composed : Vector]
                        [entry-price : f64]
                        [entry-atr : f64]
                        [distances : Distances])
  (let ((paper (make-paper-entry composed entry-price entry-atr distances))
        (max-papers 100))
    ;; Cap the papers deque
    (when (>= (length (:papers b)) max-papers)
      (pop-front (:papers b)))
    (push-back (:papers b) paper)))

;; ── tick-papers — tick all papers, resolve completed ───────────────
;; Returns: (Vec<Resolution>, Vec<LogEntry>)

(define (tick-papers [b : Broker] [current-price : f64])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((resolutions '())
        (logs '())
        (remaining (deque)))
    (for-each (lambda (paper)
      (let ((both-done (tick-paper paper current-price)))
        (if both-done
          ;; Paper fully resolved — produce resolutions for each side
          (let ((entry (:entry-price paper))
                (thought (:composed-thought paper)))
            ;; Buy side resolution
            (let ((buy-pnl (/ (- (:buy-extreme paper) entry) entry))
                  (buy-outcome (if (> buy-pnl 0.0) :grace :violence))
                  (buy-optimal (paper-optimal-buy-distances paper)))
              (set! resolutions (append resolutions
                (list (resolution (:slot-idx b) thought :up
                        buy-outcome (abs buy-pnl) buy-optimal))))
              (set! logs (append logs
                (list (PaperResolved (:slot-idx b) buy-outcome buy-optimal)))))
            ;; Sell side resolution
            (let ((sell-pnl (/ (- entry (:sell-extreme paper)) entry))
                  (sell-outcome (if (> sell-pnl 0.0) :grace :violence))
                  (sell-optimal (paper-optimal-sell-distances paper)))
              (set! resolutions (append resolutions
                (list (resolution (:slot-idx b) thought :down
                        sell-outcome (abs sell-pnl) sell-optimal))))
              (set! logs (append logs
                (list (PaperResolved (:slot-idx b) sell-outcome sell-optimal))))))
          ;; Paper still active — keep it
          (push-back remaining paper))))
      (:papers b))
    (set! b :papers remaining)
    (list resolutions logs)))

;; ── propagate — learn from outcomes, return what observers need ────
;; Values up, not effects down.

(define (propagate [b : Broker]
                   [thought : Vector]
                   [outcome : Outcome]
                   [weight : f64]
                   [direction : Direction]
                   [optimal : Distances])
  : (Vec<LogEntry>, PropagationFacts)
  (let ((label (match outcome (:grace "Grace") (:violence "Violence"))))
    ;; Teach the broker's own reckoner
    (observe (:reckoner b) thought label weight)

    ;; Feed the reckoner's internal curve
    (let ((pred (predict (:reckoner b) thought))
          (conviction (match pred
                        ((Discrete scores conv) conv)
                        ((Continuous val exp) 0.0)))
          (correct? (= outcome :grace)))
      (resolve (:reckoner b) conviction correct?))

    ;; Update track record
    (match outcome
      (:grace
        (set! b :cumulative-grace (+ (:cumulative-grace b) weight)))
      (:violence
        (set! b :cumulative-violence (+ (:cumulative-violence b) weight))))
    (set! b :trade-count (+ (:trade-count b) 1))

    ;; Scalar accumulators learn from optimal distances
    (observe-scalar (nth (:scalar-accums b) 0) (:trail optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums b) 1) (:stop optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums b) 2) (:tp optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums b) 3) (:runner-trail optimal) outcome weight)

    ;; Engram gating
    (let ((accuracy-threshold 0.55))
      (check-engram-gate
        (:reckoner b)
        (:good-state-subspace b)
        (:recalib-wins b)
        (:recalib-total b)
        (:last-recalib-count b)
        outcome
        accuracy-threshold
        "Grace"))

    ;; Build propagation facts — the post applies these to its observers
    (let ((market-idx (/ (:slot-idx b) (:exit-count b)))
          (exit-idx (mod (:slot-idx b) (:exit-count b)))
          (facts (propagation-facts market-idx exit-idx
                   direction thought optimal weight))
          (n-observers (length (:observer-names b)))
          (log (Propagated (:slot-idx b) n-observers)))
      (list (list log) facts))))

;; ── paper-count ────────────────────────────────────────────────────

(define (paper-count [b : Broker])
  : usize
  (length (:papers b)))
