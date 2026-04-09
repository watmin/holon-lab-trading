;; broker.wat — Broker struct + interface
;; Depends on: enums, distances, scalar-accumulator, paper-entry, settlement, log-entry, engram-gate

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require paper-entry)
(require settlement)
(require log-entry)
(require engram-gate)

;; PropagationFacts — what the broker returns for the post to apply.
;; Values up, not effects down.
(struct propagation-facts
  [market-idx : usize]
  [exit-idx : usize]
  [direction : Direction]
  [composed-thought : Vector]
  [optimal : Distances]
  [weight : f64])

(struct broker
  [observer-names : Vec<String>]
  [slot-idx : usize]
  [exit-count : usize]
  ;; Accountability
  [reckoner : Reckoner]
  [noise-subspace : OnlineSubspace]
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers
  [papers : VecDeque<PaperEntry>]
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
    observers slot-idx exit-count
    (make-reckoner "accountability" dims recalib-interval
                   (Discrete '("Grace" "Violence")))
    (online-subspace dims 8)
    0.0 0.0 0         ; cumulative-grace, cumulative-violence, trade-count
    (deque)            ; papers
    scalar-accums
    (online-subspace dims 4)  ; good-state-subspace
    0 0 0))            ; recalib-wins, recalib-total, last-recalib-count

;; Propose: noise update, strip noise, predict Grace/Violence.
(define (propose [broker : Broker] [composed : Vector])
  : Prediction
  (update (:noise-subspace broker) composed)
  (let ((stripped (anomalous-component (:noise-subspace broker) composed)))
    (predict (:reckoner broker) stripped)))

;; Edge: how much edge? Reads from the reckoner's internal curve.
(define (edge [broker : Broker])
  : f64
  (let ((pred (predict (:reckoner broker) (zeros))))
    (let ((conviction (match pred
                        ((Discrete scores conv) conv)
                        ((Continuous v e) 0.0))))
      (if (proven? (:reckoner broker) 50)
        (edge-at (:reckoner broker) conviction)
        0.0))))

;; Register a paper entry — every candle, every broker.
(define (register-paper [broker : Broker] [composed : Vector]
                        [entry-price : f64] [entry-atr : f64]
                        [distances : Distances])
  ;; Cap papers at 100
  (when (> (len (:papers broker)) 100)
    (pop-front (:papers broker)))
  (push-back (:papers broker)
    (make-paper-entry composed entry-price entry-atr distances)))

;; Tick all papers against current price. Resolve completed ones.
;; Returns (Vec<Resolution>, Vec<LogEntry>).
(define (tick-papers [broker : Broker] [current-price : f64])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((resolutions '())
        (logs '())
        (slot (:slot-idx broker)))
    ;; Tick each paper
    (for-each (lambda (paper)
      ;; Update buy side
      (when (not (:buy-resolved paper))
        (when (> current-price (:buy-extreme paper))
          (set! paper :buy-extreme current-price)
          (set! paper :buy-trail-stop (* current-price (- 1.0 (:trail (:distances paper))))))
        (when (<= current-price (:buy-trail-stop paper))
          (set! paper :buy-resolved true)))
      ;; Update sell side
      (when (not (:sell-resolved paper))
        (when (< current-price (:sell-extreme paper))
          (set! paper :sell-extreme current-price)
          (set! paper :sell-trail-stop (* current-price (+ 1.0 (:trail (:distances paper))))))
        (when (>= current-price (:sell-trail-stop paper))
          (set! paper :sell-resolved true))))
      (:papers broker))

    ;; Collect resolved papers
    (let ((new-papers (deque))
          (all-resolutions '())
          (all-logs '()))
      (for-each (lambda (paper)
        (if (and (:buy-resolved paper) (:sell-resolved paper))
          ;; Both sides resolved — produce resolutions
          (let ((entry (:entry-price paper))
                ;; Buy side resolution
                (buy-pnl (/ (- (:buy-extreme paper) entry) entry))
                (buy-optimal-trail (/ (- (:buy-extreme paper) entry) entry))
                ;; Sell side resolution
                (sell-pnl (/ (- entry (:sell-extreme paper)) entry))
                (sell-optimal-trail (/ (- entry (:sell-extreme paper)) entry))
                ;; Optimal distances from paper extremes (MFE/MAE approximation)
                (buy-optimal (make-distances
                               (max buy-optimal-trail 0.001)
                               (max (/ (- entry (:sell-extreme paper)) entry) 0.001)
                               (max buy-optimal-trail 0.001)
                               (max (* buy-optimal-trail 1.5) 0.001)))
                (sell-optimal (make-distances
                                (max sell-optimal-trail 0.001)
                                (max (/ (- (:buy-extreme paper) entry) entry) 0.001)
                                (max sell-optimal-trail 0.001)
                                (max (* sell-optimal-trail 1.5) 0.001)))
                ;; Buy side: price went up then retraced → direction :up
                (buy-outcome (if (> buy-pnl 0.0) :grace :violence))
                (sell-outcome (if (> sell-pnl 0.0) :grace :violence)))
            ;; Emit resolutions for both sides
            (set! all-resolutions (append all-resolutions
              (list
                (make-resolution slot (:composed-thought paper) :up buy-outcome
                                 (abs buy-pnl) buy-optimal)
                (make-resolution slot (:composed-thought paper) :down sell-outcome
                                 (abs sell-pnl) sell-optimal))))
            (set! all-logs (append all-logs
              (list
                (PaperResolved slot buy-outcome buy-optimal)
                (PaperResolved slot sell-outcome sell-optimal)))))
          ;; Not resolved — keep it
          (push-back new-papers paper)))
        (:papers broker))
      (set! broker :papers new-papers)
      (list all-resolutions all-logs))))

;; Propagate a resolved outcome through the broker.
;; The broker learns its OWN lessons. Returns what the observers need.
(define (propagate [broker : Broker] [thought : Vector]
                   [outcome : Outcome] [weight : f64]
                   [direction : Direction] [optimal : Distances])
  : (Vec<LogEntry>, PropagationFacts)
  (let ((slot (:slot-idx broker))
        (label (match outcome (:grace "Grace") (:violence "Violence"))))
    ;; Broker learns Grace/Violence
    (observe (:reckoner broker) thought label weight)

    ;; Update track record
    (match outcome
      (:grace
        (set! broker :cumulative-grace (+ (:cumulative-grace broker) weight)))
      (:violence
        (set! broker :cumulative-violence (+ (:cumulative-violence broker) weight))))
    (inc! broker :trade-count)

    ;; Feed the reckoner's internal curve
    (let ((pred (predict (:reckoner broker) thought))
          (conviction (match pred
                        ((Discrete scores conv) conv)
                        ((Continuous v e) 0.0)))
          (correct? (= outcome :grace)))
      (resolve (:reckoner broker) conviction correct?))

    ;; Engram gating
    (let (((accepted new-wins new-total new-last)
            (check-engram-gate (:reckoner broker) (:good-state-subspace broker)
                               (:recalib-wins broker) (:recalib-total broker)
                               (:last-recalib-count broker) outcome)))
      (set! broker :recalib-wins new-wins)
      (set! broker :recalib-total new-total)
      (set! broker :last-recalib-count new-last))

    ;; Feed scalar accumulators with optimal distances
    (when (> (length (:scalar-accums broker)) 0)
      (observe-scalar (nth (:scalar-accums broker) 0) (:trail optimal) outcome weight)
      (observe-scalar (nth (:scalar-accums broker) 1) (:stop optimal) outcome weight)
      (observe-scalar (nth (:scalar-accums broker) 2) (:tp optimal) outcome weight)
      (observe-scalar (nth (:scalar-accums broker) 3) (:runner-trail optimal) outcome weight))

    ;; Derive market-idx and exit-idx from slot-idx
    (let ((market-idx (/ slot (:exit-count broker)))
          (exit-idx (mod slot (:exit-count broker))))
      (list
        (list (Propagated slot 2))  ; 2 observers updated (market + exit)
        (propagation-facts market-idx exit-idx direction thought optimal weight)))))

;; Paper count — how many active papers.
(define (paper-count [broker : Broker])
  : usize
  (len (:papers broker)))
