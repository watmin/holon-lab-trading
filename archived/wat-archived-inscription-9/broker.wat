;; broker.wat — Broker struct + interface (Resolution + PropagationFacts)
;; Depends on: reckoner, scalar-accumulator, enums, distances, paper-entry, engram-gate

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require paper-entry)
(require engram-gate)

;; ── Resolution — what a broker produces when a paper resolves ──────
(struct resolution
  [broker-slot-idx : usize]
  [composed-thought : Vector]
  [direction : Direction]              ; :up or :down
  [outcome : Outcome]                  ; :grace or :violence
  [amount : f64]
  [optimal-distances : Distances])

;; ── PropagationFacts — what the broker returns for observers ───────
(struct propagation-facts
  [market-idx : usize]
  [exit-idx : usize]
  [direction : Direction]
  [composed-thought : Vector]
  [optimal : Distances]
  [weight : f64])

;; ── Broker ─────────────────────────────────────────────────────────

(struct broker
  [observer-names : Vec<String>]
  [slot-idx : usize]
  [exit-count : usize]
  ;; Accountability
  [reckoner : Reckoner]                ; :discrete — Grace/Violence
  [noise-subspace : OnlineSubspace]
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers
  [papers : VecDeque<PaperEntry>]      ; capped
  ;; Scalar learning
  [scalar-accums : Vec<ScalarAccumulator>]
  ;; Engram gating
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
  (broker
    observers slot-idx exit-count
    (make-reckoner (format "broker-{}" slot-idx) dims recalib-interval
      (Discrete (list "Grace" "Violence")))
    (online-subspace dims 8)
    0.0 0.0 0
    (deque)
    scalar-accums
    (online-subspace dims 4)
    0 0 0))

;; Strip noise from the broker's perspective
(define (broker-strip-noise [b : Broker] [thought : Vector])
  : Vector
  (anomalous-component (:noise-subspace b) thought))

;; Propose: noise update → strip noise → predict Grace/Violence
(define (propose [b : Broker] [composed : Vector])
  : (Broker Prediction)
  (begin
    (update (:noise-subspace b) composed)
    (let ((stripped (broker-strip-noise b composed))
          (pred (predict (:reckoner b) stripped)))
      (list b pred))))

;; Edge: how much edge does this broker have?
(define (broker-edge [b : Broker])
  : f64
  (let ((pred (predict (:reckoner b) (zeros))))
    (let ((conviction (match pred
                        ((Discrete scores conv) conv)
                        ((Continuous v e) 0.0))))
      (if (proven? (:reckoner b) 50)
        (edge-at (:reckoner b) conviction)
        0.0))))

;; Register a paper entry
(define (register-paper [b : Broker]
                        [composed : Vector]
                        [entry-price : f64]
                        [distances : Distances])
  : Broker
  (let ((paper (make-paper-entry composed entry-price distances))
        (new-papers (push-back (:papers b) paper))
        ;; Cap papers at 100
        (capped (if (> (len new-papers) 100)
                  (second (pop-front new-papers))
                  new-papers)))
    (update b :papers capped)))

;; Tick all papers, resolve completed ones
(define (tick-papers [b : Broker] [current-price : f64])
  : (Broker Vec<Resolution> Vec<LogEntry>)
  (let ((slot (:slot-idx b))
        (results
          (fold (lambda (state paper)
                  (let (((kept resolutions logs) state)
                        (ticked (tick-paper paper current-price)))
                    (if (paper-resolved? ticked)
                      ;; Paper is done — produce resolutions for each side
                      (let ((entry (:entry-price ticked))
                            (thought (:composed-thought ticked))
                            (dists (:distances ticked))
                            ;; Buy side resolution
                            (buy-pnl (/ (- (:buy-trail-stop ticked) entry) entry))
                            (buy-outcome (if (> buy-pnl 0.0) :grace :violence))
                            (buy-optimal (make-distances
                                           (/ (- (:buy-extreme ticked) entry) entry)
                                           (:stop dists) (:tp dists) (:runner-trail dists)))
                            (buy-res (resolution slot thought :up buy-outcome
                                       (abs buy-pnl) buy-optimal))
                            ;; Sell side resolution
                            (sell-pnl (/ (- entry (:sell-trail-stop ticked)) entry))
                            (sell-outcome (if (> sell-pnl 0.0) :grace :violence))
                            (sell-optimal (make-distances
                                            (/ (- entry (:sell-extreme ticked)) entry)
                                            (:stop dists) (:tp dists) (:runner-trail dists)))
                            (sell-res (resolution slot thought :down sell-outcome
                                        (abs sell-pnl) sell-optimal))
                            ;; Log entries
                            (buy-log (PaperResolved slot buy-outcome buy-optimal))
                            (sell-log (PaperResolved slot sell-outcome sell-optimal)))
                        (list kept
                              (append resolutions (list buy-res sell-res))
                              (append logs (list buy-log sell-log))))
                      ;; Paper still running — keep it
                      (list (append kept (list ticked)) resolutions logs))))
                (list '() '() '())
                (rb-to-list (:papers b)))))  ;; iterate over papers
    (let (((kept resolutions logs) results))
      (list (update b :papers (fold push-back (deque) kept))
            resolutions logs))))

;; Paper count
(define (paper-count [b : Broker])
  : usize
  (len (:papers b)))

;; Propagate a resolved outcome through the broker
;; Returns (LogEntry list, PropagationFacts)
(define (broker-propagate [b : Broker]
                          [thought : Vector]
                          [outcome : Outcome]
                          [weight : f64]
                          [direction : Direction]
                          [optimal : Distances])
  : (Broker Vec<LogEntry> PropagationFacts)
  (let ((stripped (broker-strip-noise b thought))
        ;; Learn Grace/Violence
        (label (match outcome (:grace "Grace") (:violence "Violence")))
        (_ (observe (:reckoner b) stripped label weight))
        ;; Feed the curve
        (pred (predict (:reckoner b) stripped))
        (conviction (match pred
                      ((Discrete scores conv) conv)
                      ((Continuous v e) 0.0)))
        (correct (match outcome (:grace true) (:violence false)))
        (_ (resolve (:reckoner b) conviction correct))
        ;; Update track record
        (new-grace (match outcome
                     (:grace (+ (:cumulative-grace b) weight))
                     (:violence (:cumulative-grace b))))
        (new-violence (match outcome
                        (:violence (+ (:cumulative-violence b) weight))
                        (:grace (:cumulative-violence b))))
        ;; Update scalar accumulators
        (new-accums (map (lambda (pair)
                      (let (((acc dist-val) pair))
                        (observe-scalar acc dist-val outcome weight)))
                    (list
                      (list (nth (:scalar-accums b) 0) (:trail optimal))
                      (list (nth (:scalar-accums b) 1) (:stop optimal))
                      (list (nth (:scalar-accums b) 2) (:tp optimal))
                      (list (nth (:scalar-accums b) 3) (:runner-trail optimal)))))
        ;; Engram gate
        ((new-gs new-rw new-rt new-lrc)
          (check-engram-gate (:reckoner b)
            (:good-state-subspace b) (:recalib-wins b)
            (:recalib-total b) (:last-recalib-count b) outcome))
        ;; Derive market-idx and exit-idx from slot-idx
        (market-idx (/ (:slot-idx b) (:exit-count b)))
        (exit-idx (mod (:slot-idx b) (:exit-count b)))
        ;; Propagation facts for the observers
        (facts (propagation-facts market-idx exit-idx direction
                 thought optimal weight))
        ;; Log entry
        (log (Propagated (:slot-idx b) 2))
        ;; Updated broker
        (updated (update b
                   :cumulative-grace new-grace
                   :cumulative-violence new-violence
                   :trade-count (+ (:trade-count b) 1)
                   :scalar-accums new-accums
                   :good-state-subspace new-gs
                   :recalib-wins new-rw
                   :recalib-total new-rt
                   :last-recalib-count new-lrc)))
    (list updated (list log) facts)))
