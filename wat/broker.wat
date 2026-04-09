;; broker.wat — Broker struct + interface, Resolution, PropagationFacts
;; Depends on: enums, reckoner, scalar-accumulator, distances, paper-entry,
;;             engram-gate, log-entry, thought-encoder
;; The accountability primitive. Binds a set of observers as a team.

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require paper-entry)
(require engram-gate)
(require log-entry)
(require thought-encoder)

;; Resolution — what a broker produces when a paper resolves.
;; Facts, not mutations. Collected from parallel tick, applied sequentially.
(struct resolution
  [broker-slot-idx : usize]    ; which broker produced this
  [composed-thought : Vector]  ; the thought that was tested
  [direction : Direction]      ; :up or :down
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value
  [optimal-distances : Distances]) ; hindsight optimal

(define (make-resolution [slot : usize] [thought : Vector] [dir : Direction]
                         [outcome : Outcome] [amt : f64] [optimal : Distances])
  : Resolution
  (resolution slot thought dir outcome amt optimal))

;; PropagationFacts — what the broker returns for the post to apply.
;; Values up, not effects down.
(struct propagation-facts
  [market-idx : usize]           ; which market observer should learn
  [exit-idx : usize]             ; which exit observer should learn
  [direction : Direction]        ; for the market observer
  [composed-thought : Vector]    ; for both observers
  [optimal : Distances]          ; for the exit observer
  [weight : f64])                ; for both observers

;; The Broker struct.
(struct broker
  [observer-names : Vec<String>]       ; the identity
  [slot-idx : usize]                   ; position in the N×M grid
  [exit-count : usize]                 ; M — for deriving market-idx and exit-idx
  ;; Accountability
  [reckoner : Reckoner]                ; :discrete — Grace/Violence
  [noise-subspace : OnlineSubspace]
  [curve : Curve]
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers — the fast learning stream
  [papers : VecDeque<PaperEntry>]      ; capped
  ;; Scalar learning
  [scalar-accums : Vec<ScalarAccumulator>]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

(define (make-broker [observers : Vec<String>] [slot-idx : usize]
                     [exit-count : usize] [dims : usize]
                     [recalib-interval : usize]
                     [scalar-accums : Vec<ScalarAccumulator>])
  : Broker
  (broker
    observers
    slot-idx
    exit-count
    (make-reckoner (Discrete dims recalib-interval '("Grace" "Violence")))
    (online-subspace dims 8)           ; noise background
    (make-curve)                        ; curve
    0.0                                 ; cumulative-grace
    0.0                                 ; cumulative-violence
    0                                   ; trade-count
    (deque)                             ; papers
    scalar-accums
    (online-subspace dims 4)           ; engram good-state
    0                                   ; recalib-wins
    0                                   ; recalib-total
    0))                                 ; last-recalib-count

;; Derive market-idx and exit-idx from slot-idx.
(define (market-idx [b : Broker])
  : usize
  (/ (:slot-idx b) (:exit-count b)))

(define (exit-idx [b : Broker])
  : usize
  (mod (:slot-idx b) (:exit-count b)))

;; Strip noise — the anomalous component IS the signal.
(define (broker-strip-noise [b : Broker] [thought : Vector])
  : Vector
  (update (:noise-subspace b) thought)
  (anomalous-component (:noise-subspace b) thought))

;; Propose — noise update, strip noise, predict Grace/Violence.
(define (propose [b : Broker] [composed : Vector])
  : Prediction
  (let ((stripped (broker-strip-noise b composed)))
    (predict (:reckoner b) stripped)))

;; Edge — how much edge? The curve reads accuracy at typical conviction.
;; 0.0 = no edge.
(define (edge [b : Broker])
  : f64
  (if (not (proven? (:curve b) 50))
    0.0
    (let ((pred (predict (:reckoner b) (zeros))))
      (match pred
        ((Discrete _ c) (edge-at (:curve b) c))
        ((Continuous _ _) 0.0)))))

;; Register a paper entry — every candle, every broker.
(define (register-paper [b : Broker] [composed : Vector]
                        [entry-price : f64] [entry-atr : f64]
                        [dist : Distances])
  ;; Cap papers — remove oldest if at capacity
  (when (> (len (:papers b)) 100)
    (pop-front (:papers b)))
  (push-back (:papers b) (make-paper-entry composed entry-price entry-atr dist)))

;; Tick all papers, resolve completed.
;; Returns: (Vec<Resolution>, Vec<LogEntry>)
(define (tick-papers [b : Broker] [current-price : f64])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((resolutions '())
        (logs '()))
    (for-each (lambda (pe)
      ;; Tick both sides
      (tick-paper pe current-price)
      ;; Check if both sides resolved
      (when (paper-resolved? pe)
        (let ((entry (:entry-price pe))
              (optimal (paper-optimal-distances pe)))
          ;; Buy side resolution
          (let ((buy-pnl (/ (- (:buy-extreme pe) entry) entry))
                (buy-outcome (if (> buy-pnl 0.0) :grace :violence)))
            (push! resolutions
              (make-resolution (:slot-idx b) (:composed-thought pe)
                :up buy-outcome (abs buy-pnl) optimal)))
          ;; Sell side resolution
          (let ((sell-pnl (/ (- entry (:sell-extreme pe)) entry))
                (sell-outcome (if (> sell-pnl 0.0) :grace :violence)))
            (push! resolutions
              (make-resolution (:slot-idx b) (:composed-thought pe)
                :down sell-outcome (abs sell-pnl) optimal)))
          ;; Log entry
          (let ((net-outcome (if (> (+ (/ (- (:buy-extreme pe) entry) entry)
                                       (/ (- entry (:sell-extreme pe)) entry)) 0.0)
                               :grace :violence)))
            (push! logs (PaperResolved (:slot-idx b) net-outcome optimal))))))
      (:papers b))
    ;; Remove resolved papers
    (set! (:papers b)
      (filter (lambda (pe) (not (paper-resolved? pe))) (:papers b)))
    (list resolutions logs)))

;; Propagate — the broker learns its OWN lessons and RETURNS what the
;; observers need. Values up, not effects down.
(define (propagate [b : Broker] [thought : Vector] [outcome : Outcome]
                   [weight : f64] [direction : Direction]
                   [optimal : Distances])
  : (Vec<LogEntry>, PropagationFacts)
  ;; Broker's own learning
  (let ((label (match outcome (:grace "Grace") (:violence "Violence"))))
    ;; Observe Grace/Violence
    (observe (:reckoner b) thought label weight)
    ;; Track record
    (match outcome
      (:grace   (set! (:cumulative-grace b) (+ (:cumulative-grace b) weight)))
      (:violence (set! (:cumulative-violence b) (+ (:cumulative-violence b) weight))))
    (inc! (:trade-count b))
    ;; Curve: record prediction accuracy
    (let ((pred (predict (:reckoner b) thought))
          (conviction (match pred
                        ((Discrete _ c) c)
                        ((Continuous _ _) 0.0)))
          (correct (match outcome (:grace true) (:violence false))))
      (record-prediction (:curve b) conviction correct))
    ;; Scalar accumulators: learn optimal distances
    (for-each (lambda (i)
      (let ((accum (nth (:scalar-accums b) i))
            (val (match i
                   (0 (:trail optimal))
                   (1 (:stop optimal))
                   (2 (:tp optimal))
                   (3 (:runner-trail optimal)))))
        (observe-scalar accum val outcome weight)))
      (range 0 4))
    ;; Engram gate
    (let (((w t) (engram-gate-record
                   (match outcome (:grace true) (:violence false))
                   (:recalib-wins b) (:recalib-total b))))
      (set! (:recalib-wins b) w)
      (set! (:recalib-total b) t)
      (let (((ok sub w2 t2 rc)
              (check-engram-gate
                (:reckoner b) (:good-state-subspace b)
                (:recalib-wins b) (:recalib-total b)
                (:last-recalib-count b) 0.55)))
        (set! (:good-state-subspace b) sub)
        (set! (:recalib-wins b) w2)
        (set! (:recalib-total b) t2)
        (set! (:last-recalib-count b) rc)))
    ;; Return PropagationFacts for the post to apply
    (let ((m-idx (market-idx b))
          (e-idx (exit-idx b))
          (log-entries (list (Propagated (:slot-idx b) (len (:observer-names b))))))
      (list log-entries
            (propagation-facts m-idx e-idx direction thought optimal weight)))))

;; Paper count
(define (paper-count [b : Broker])
  : usize
  (len (:papers b)))
