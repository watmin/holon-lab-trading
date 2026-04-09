;; broker.wat — the accountability primitive
;;
;; Depends on: enums (Outcome, Direction, Prediction),
;;             distances (Distances), scalar-accumulator,
;;             paper-entry, log-entry, engram-gate
;;
;; Binds one market observer + one exit observer. N x M brokers total.
;; Holds papers. Propagates resolved outcomes — returns PropagationFacts
;; as values. The post applies them to its observers. Values up.
;;
;; propagate does NOT take observer vecs. Returns (Vec<LogEntry>, PropagationFacts).

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require paper-entry)
(require log-entry)
(require engram-gate)

;; ── Resolution — what a broker produces when a paper resolves ──────
;; Facts, not mutations. Collected from parallel tick, applied sequentially.

(struct resolution
  [broker-slot-idx : usize]      ; which broker produced this
  [composed-thought : Vector]    ; the thought that was tested
  [direction : Direction]        ; :up or :down
  [outcome : Outcome]            ; :grace or :violence
  [amount : f64]                 ; how much value
  [optimal-distances : Distances]) ; hindsight optimal

;; ── PropagationFacts — what propagate returns for the post ─────────

(struct propagation-facts
  [market-idx : usize]           ; which market observer should learn
  [exit-idx : usize]             ; which exit observer should learn
  [direction : Direction]        ; for the market observer
  [composed-thought : Vector]    ; for both observers
  [optimal : Distances]          ; for the exit observer
  [weight : f64])                ; for both observers

;; ── Broker ─────────────────────────────────────────────────────────

(struct broker
  [observer-names : Vec<String>]          ; the identity
  [slot-idx : usize]                      ; position in the N x M grid
  [exit-count : usize]                    ; M — for deriving market-idx, exit-idx
  ;; Accountability
  [reckoner : Reckoner]                   ; :discrete — Grace/Violence
  [noise-subspace : OnlineSubspace]
  [curve : Curve]
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers — the fast learning stream
  [papers : VecDeque<PaperEntry>]         ; capped
  ;; Scalar learning
  [scalar-accums : Vec<ScalarAccumulator>]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

;; ── Constructor ────────────────────────────────────────────────────

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
    (make-reckoner (Discrete dims recalib-interval '("Grace" "Violence")))
    (online-subspace dims 8)               ; noise-subspace
    (make-curve)                            ; curve
    0.0                                     ; cumulative-grace
    0.0                                     ; cumulative-violence
    0                                       ; trade-count
    (deque)                                 ; papers — empty VecDeque
    scalar-accums
    (online-subspace dims 4)               ; good-state-subspace
    0                                       ; recalib-wins
    0                                       ; recalib-total
    0))                                     ; last-recalib-count

;; ── propose ────────────────────────────────────────────────────────
;; noise update -> strip noise -> predict Grace/Violence

(define (propose [brkr : Broker] [composed : Vector])
  : Prediction
  (begin
    (update (:noise-subspace brkr) composed)
    (let ((cleaned (difference composed
                               (anomalous-component (:noise-subspace brkr) composed))))
      (predict (:reckoner brkr) cleaned))))

;; ── edge ───────────────────────────────────────────────────────────
;; How much edge? The curve's accuracy at the typical conviction level.

(define (edge [brkr : Broker])
  : f64
  (if (proven? (:curve brkr) 30)
    (let* ((pred (predict (:reckoner brkr) (zeros)))
           (conviction (match pred
                         ((Discrete _ c) c)
                         ((Continuous _ _) 0.0))))
      (edge-at (:curve brkr) conviction))
    0.0))

;; ── register-paper ─────────────────────────────────────────────────
;; Create a paper entry — every candle, every broker.

(define (register-paper [brkr : Broker]
                        [composed : Vector]
                        [entry-price : f64]
                        [entry-atr : f64]
                        [distances : Distances])
  (let ((paper (make-paper-entry composed entry-price entry-atr distances)))
    (push-back (:papers brkr) paper)
    ;; Cap papers at 100
    (when (> (len (:papers brkr)) 100)
      (pop-front (:papers brkr)))))

;; ── tick-papers ────────────────────────────────────────────────────
;; Tick all papers, resolve completed ones.
;; Returns: (Vec<Resolution>, Vec<LogEntry>)
;; Papers derive optimal-distances from tracked extremes (MFE/MAE).

(define (tick-papers [brkr : Broker] [current-price : f64])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let ((resolutions '())
        (logs '()))
    ;; Tick each paper
    (for-each (lambda (paper)
                (tick-paper paper current-price))
              (:papers brkr))
    ;; Collect resolutions from fully resolved papers
    (let ((resolved-papers (filter fully-resolved? (:papers brkr))))
      (for-each
        (lambda (paper)
          ;; Each side produces a resolution
          ;; Buy side -> direction :up
          (let (((buy-pnl buy-outcome) (paper-pnl paper :up))
                (optimal-buy (make-distances
                               ;; Approximate optimal from tracked extremes
                               (/ (- (:buy-extreme paper) (:entry-price paper))
                                  (:entry-price paper))
                               (:stop (:distances paper))
                               (/ (- (:buy-extreme paper) (:entry-price paper))
                                  (:entry-price paper))
                               (/ (- (:buy-extreme paper) (:entry-price paper))
                                  (:entry-price paper)))))
            (push! resolutions
              (resolution (:slot-idx brkr)
                          (:composed-thought paper)
                          :up
                          buy-outcome
                          (abs buy-pnl)
                          optimal-buy))
            (push! logs
              (PaperResolved (:slot-idx brkr) buy-outcome optimal-buy)))
          ;; Sell side -> direction :down
          (let (((sell-pnl sell-outcome) (paper-pnl paper :down))
                (optimal-sell (make-distances
                                (/ (- (:entry-price paper) (:sell-extreme paper))
                                   (:entry-price paper))
                                (:stop (:distances paper))
                                (/ (- (:entry-price paper) (:sell-extreme paper))
                                   (:entry-price paper))
                                (/ (- (:entry-price paper) (:sell-extreme paper))
                                   (:entry-price paper)))))
            (push! resolutions
              (resolution (:slot-idx brkr)
                          (:composed-thought paper)
                          :down
                          sell-outcome
                          (abs sell-pnl)
                          optimal-sell))
            (push! logs
              (PaperResolved (:slot-idx brkr) sell-outcome optimal-sell))))
        resolved-papers)
      ;; Remove resolved papers
      (set! (:papers brkr)
            (filter (lambda (p) (not (fully-resolved? p))) (:papers brkr))))
    (list resolutions logs)))

;; ── propagate ──────────────────────────────────────────────────────
;; The broker learns its OWN lessons. Returns PropagationFacts for the
;; post to apply to observers. Values up, not effects down.
;; Does NOT take observer vecs.

(define (propagate [brkr : Broker]
                   [thought : Vector]
                   [outcome : Outcome]
                   [weight : f64]
                   [direction : Direction]
                   [optimal : Distances])
  : (Vec<LogEntry>, PropagationFacts)
  (let ((label (match outcome (:grace "Grace") (:violence "Violence"))))
    ;; Broker's own reckoner learns Grace/Violence
    (observe (:reckoner brkr) thought label weight)
    ;; Curve records the prediction
    (let* ((pred (predict (:reckoner brkr) thought))
           (conviction (match pred
                         ((Discrete _ c) c)
                         ((Continuous _ _) 0.0)))
           (correct (= outcome :grace)))
      (record-prediction (:curve brkr) conviction correct))
    ;; Track record
    (match outcome
      (:grace    (begin
                   (set! (:cumulative-grace brkr)
                         (+ (:cumulative-grace brkr) weight))
                   (inc! (:trade-count brkr))))
      (:violence (begin
                   (set! (:cumulative-violence brkr)
                         (+ (:cumulative-violence brkr) weight))
                   (inc! (:trade-count brkr)))))
    ;; Scalar accumulators learn optimal distances
    (observe-scalar (nth (:scalar-accums brkr) 0) (:trail optimal)       outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 1) (:stop optimal)        outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 2) (:tp optimal)          outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 3) (:runner-trail optimal) outcome weight)
    ;; Engram gating
    (let (((new-wins new-total new-last)
            (check-engram-gate
              (:reckoner brkr)
              (:good-state-subspace brkr)
              (:recalib-wins brkr)
              (:recalib-total brkr)
              (:last-recalib-count brkr)
              outcome
              "Grace")))
      (set! (:recalib-wins brkr) new-wins)
      (set! (:recalib-total brkr) new-total)
      (set! (:last-recalib-count brkr) new-last))
    ;; Build PropagationFacts for the post
    (let ((market-idx (/ (:slot-idx brkr) (:exit-count brkr)))
          (exit-idx   (mod (:slot-idx brkr) (:exit-count brkr)))
          (logs (list (Propagated (:slot-idx brkr)
                                  (len (:observer-names brkr)))))
          (facts (propagation-facts
                   market-idx
                   exit-idx
                   direction
                   thought
                   optimal
                   weight)))
      (list logs facts))))

;; ── paper-count ────────────────────────────────────────────────────

(define (paper-count [brkr : Broker])
  : usize
  (len (:papers brkr)))
