;; broker.wat — Broker struct + interface
;; Depends on: enums, distances, scalar-accumulator, paper-entry,
;;             engram-gate, simulation

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require paper-entry)
(require engram-gate)

;; ── PropagationFacts — what the broker returns for the post to apply ──
(struct propagation-facts
  [market-idx : usize]
  [exit-idx : usize]
  [direction : Direction]
  [composed-thought : Vector]
  [optimal : Distances]
  [weight : f64])

;; ── Resolution — what a broker produces when a paper resolves ─────────
(struct resolution
  [broker-slot-idx : usize]
  [composed-thought : Vector]
  [direction : Direction]
  [outcome : Outcome]
  [amount : f64]
  [optimal-distances : Distances])

;; ── Broker — the accountability primitive ─────────────────────────────
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
  (broker
    observers
    slot-idx
    exit-count
    (make-reckoner (format "broker-{}" slot-idx) dims recalib-interval
      (Discrete (list "Grace" "Violence")))
    (online-subspace dims 8)              ; noise-subspace
    0.0 0.0 0                            ; cumulative-grace, violence, trade-count
    (deque)                               ; papers — empty deque
    scalar-accums
    (online-subspace dims 4)              ; good-state-subspace
    0 0 0))                              ; recalib-wins, total, last-recalib-count

;; ── strip-noise — anomalous component for the broker ──────────────────
(define (broker-strip-noise [b : Broker]
                            [thought : Vector])
  : Vector
  (update (:noise-subspace b) thought)
  (anomalous-component (:noise-subspace b) thought))

;; ── propose — noise update, strip noise, predict Grace/Violence ───────
(define (propose [b : Broker]
                 [composed : Vector])
  : Prediction
  (let ((cleaned (broker-strip-noise b composed)))
    (predict (:reckoner b) cleaned)))

;; ── edge — how much edge? ─────────────────────────────────────────────
;; Reads from the reckoner's internal curve.
;; 0.0 = no edge. The treasury funds proportionally.
(define (edge [b : Broker])
  : f64
  (let ((min-proof-samples 100))
    (if (not (proven? (:reckoner b) min-proof-samples))
      0.0
      (let ((pred (predict (:reckoner b) (zeros))))
        (match pred
          ((Discrete _ conviction)
            (edge-at (:reckoner b) conviction))
          (_ 0.0))))))

;; ── register-paper — create a paper entry ─────────────────────────────
;; Every candle, every broker. The fast learning stream.
(define (register-paper [b : Broker]
                        [composed : Vector]
                        [entry-price : f64]
                        [distances : Distances])
  (let ((paper (make-paper-entry composed entry-price distances))
        (max-papers 100))
    ;; Cap the deque
    (when (>= (len (:papers b)) max-papers)
      (pop-front (:papers b)))
    (push-back (:papers b) paper)))

;; ── tick-papers — advance all papers, resolve completed ───────────────
;; Returns resolution facts and PaperResolved log entries.
(define (tick-papers [b : Broker]
                     [current-price : f64])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((resolutions '())
        (log-entries '())
        (slot (:slot-idx b)))
    ;; Tick each paper
    (for-each (lambda (paper)
      ;; Update buy side
      (when (not (:buy-resolved paper))
        ;; Buy extreme tracks the highest price
        (when (> current-price (:buy-extreme paper))
          (set! paper :buy-extreme current-price)
          ;; Update trailing stop
          (let ((new-stop (* (:buy-extreme paper) (- 1.0 (:trail (:distances paper))))))
            (set! paper :buy-trail-stop (max (:buy-trail-stop paper) new-stop))))
        ;; Check if buy trail stop fires
        (when (<= current-price (:buy-trail-stop paper))
          (set! paper :buy-resolved true)))
      ;; Update sell side
      (when (not (:sell-resolved paper))
        ;; Sell extreme tracks the lowest price
        (when (< current-price (:sell-extreme paper))
          (set! paper :sell-extreme current-price)
          ;; Update trailing stop
          (let ((new-stop (* (:sell-extreme paper) (+ 1.0 (:trail (:distances paper))))))
            (set! paper :sell-trail-stop (min (:sell-trail-stop paper) new-stop))))
        ;; Check if sell trail stop fires
        (when (>= current-price (:sell-trail-stop paper))
          (set! paper :sell-resolved true)))
      ;; Check if this paper produced a resolution
      (when (and (:buy-resolved paper) (not (:sell-resolved paper)))
        ;; Buy side resolved — price rose then retraced. Direction: :up.
        ;; Derive optimal from tracked extremes (MFE/MAE approximation)
        (let ((mfe-buy (/ (- (:buy-extreme paper) (:entry-price paper))
                          (:entry-price paper)))
              (mae-buy (/ (- (:entry-price paper)
                            (min (:entry-price paper) current-price))
                          (:entry-price paper)))
              (residue (- mfe-buy mae-buy))
              (outcome (if (> residue 0.0) :grace :violence))
              (amount (abs residue))
              (optimal (distances
                         (max 0.002 (* mfe-buy 0.5))  ; trail
                         (max 0.002 mae-buy)            ; stop
                         (max 0.002 mfe-buy)            ; tp
                         (max 0.002 (* mfe-buy 0.7))))) ; runner-trail
          (push! resolutions (resolution slot (:composed-thought paper) :up outcome amount optimal))
          (push! log-entries (PaperResolved slot outcome optimal))))
      (when (and (:sell-resolved paper) (not (:buy-resolved paper)))
        ;; Sell side resolved — price fell then retraced. Direction: :down.
        (let ((mfe-sell (/ (- (:entry-price paper) (:sell-extreme paper))
                           (:entry-price paper)))
              (mae-sell (/ (- (max (:entry-price paper) current-price)
                              (:entry-price paper))
                           (:entry-price paper)))
              (residue (- mfe-sell mae-sell))
              (outcome (if (> residue 0.0) :grace :violence))
              (amount (abs residue))
              (optimal (distances
                         (max 0.002 (* mfe-sell 0.5))
                         (max 0.002 mae-sell)
                         (max 0.002 mfe-sell)
                         (max 0.002 (* mfe-sell 0.7)))))
          (push! resolutions (resolution slot (:composed-thought paper) :down outcome amount optimal))
          (push! log-entries (PaperResolved slot outcome optimal)))))
      (:papers b))
    ;; Remove fully resolved papers (both sides done)
    (set! b :papers
      (filter (lambda (p) (not (and (:buy-resolved p) (:sell-resolved p))))
              (:papers b)))
    (list resolutions log-entries)))

;; ── propagate — learn from a resolved outcome ─────────────────────────
;; Returns: (Vec<LogEntry>, PropagationFacts)
;; The broker learns its OWN lessons. Returns what the observers need.
(define (propagate [b : Broker]
                   [thought : Vector]
                   [outcome : Outcome]
                   [weight : f64]
                   [direction : Direction]
                   [optimal : Distances])
  : (Vec<LogEntry>, PropagationFacts)
  (let ((label (match outcome (:grace "Grace") (:violence "Violence")))
        (slot (:slot-idx b))
        (market-idx (/ slot (:exit-count b)))
        (exit-idx (mod slot (:exit-count b))))
    ;; Reckoner learns Grace/Violence
    (observe (:reckoner b) thought label weight)
    ;; Track record
    (match outcome
      (:grace (set! b :cumulative-grace (+ (:cumulative-grace b) weight)))
      (:violence (set! b :cumulative-violence (+ (:cumulative-violence b) weight))))
    (inc! b :trade-count)
    ;; Feed the curve — was the prediction correct?
    (let ((pred (predict (:reckoner b) thought)))
      (match pred
        ((Discrete scores conviction)
          (let ((grace-score (fold-left (lambda (best s)
                               (if (= (first s) "Grace") (second s) best))
                             0.0 scores))
                (violence-score (fold-left (lambda (best s)
                                  (if (= (first s) "Violence") (second s) best))
                                0.0 scores))
                (predicted-grace? (>= grace-score violence-score))
                (actual-grace? (match outcome (:grace true) (:violence false)))
                (correct? (= predicted-grace? actual-grace?)))
            (resolve (:reckoner b) conviction correct?)
            ;; Engram gating
            (let (((new-gss new-rw new-rt new-lrc _gate)
                    (check-engram-gate
                      (:good-state-subspace b)
                      (:recalib-wins b)
                      (:recalib-total b)
                      (:last-recalib-count b)
                      (:reckoner b)
                      correct?)))
              (set! b :good-state-subspace new-gss)
              (set! b :recalib-wins new-rw)
              (set! b :recalib-total new-rt)
              (set! b :last-recalib-count new-lrc))))
        (_ (begin))))
    ;; Scalar accumulators learn from optimal distances
    (when (> (length (:scalar-accums b)) 0)
      (observe-scalar (nth (:scalar-accums b) 0) (:trail optimal) outcome weight)
      (observe-scalar (nth (:scalar-accums b) 1) (:stop optimal) outcome weight)
      (observe-scalar (nth (:scalar-accums b) 2) (:tp optimal) outcome weight)
      (observe-scalar (nth (:scalar-accums b) 3) (:runner-trail optimal) outcome weight))
    ;; Return log entries and propagation facts
    (let ((observers-updated 2)  ; market + exit
          (log-entries (list (Propagated slot observers-updated)))
          (facts (propagation-facts
                   market-idx exit-idx direction
                   thought optimal weight)))
      (list log-entries facts))))

;; ── paper-count ───────────────────────────────────────────────────────
(define (paper-count [b : Broker])
  : usize
  (len (:papers b)))
