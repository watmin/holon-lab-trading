; broker.wat — the accountability primitive.
;
; Depends on: Reckoner (:discrete), OnlineSubspace, Curve,
;             ScalarAccumulator, PaperEntry, Distances, Prediction,
;             Direction, Outcome, Resolution.
;
; Binds one market observer + one exit observer. N*M brokers total.
; Holds papers. Propagates resolved outcomes to every observer in the set.
; Measures Grace or Violence.
;
; The broker's identity IS the set of observer names it closes over.
; The broker does NOT own the observers — they live on the post.
; The broker knows their coordinates: indices into the post's observer vecs.
;
; propagate returns (Vec<LogEntry>, PropagationFacts). NO observer vec params.
; The post applies PropagationFacts to its observers.

(require primitives)
(require enums)               ; Outcome, Direction, Prediction, reckoner-config
(require distances)           ; Distances
(require scalar-accumulator)  ; ScalarAccumulator, observe-scalar
(require paper-entry)         ; PaperEntry, make-paper-entry, tick-paper, fully-resolved?, paper-pnl
(require engram-gate)         ; check-engram-gate

;; ── Resolution — what a broker produces when a paper resolves ───────────
;; Facts, not mutations. Collected from parallel tick, applied sequentially.

(struct resolution
  [broker-slot-idx : usize]    ; which broker produced this
  [composed-thought : Vector]  ; the thought that was tested
  [direction : Direction]      ; :up or :down — the side that resolved
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value
  [optimal-distances : Distances]) ; hindsight optimal

;; ── PropagationFacts — what the observers need to learn ─────────────────
;; The broker returns these. The post applies them to its own observers.
;; Values up, not effects down.

(struct propagation-facts
  [market-idx : usize]           ; which market observer should learn
  [exit-idx : usize]             ; which exit observer should learn
  [direction : Direction]        ; for the market observer
  [composed-thought : Vector]    ; for both observers
  [optimal : Distances]          ; for the exit observer
  [weight : f64])                ; for both observers

;; ── Struct ──────────────────────────────────────────────────────────────

(struct broker
  [observer-names : Vec<String>]       ; the identity. e.g. ("momentum" "volatility")
  [slot-idx : usize]                   ; position in the N×M grid. THE identity.
  [exit-count : usize]                 ; M — for deriving market-idx and exit-idx
  ;; Accountability
  [reckoner : Reckoner]                ; :discrete — Grace/Violence
  [noise-subspace : OnlineSubspace]
  [curve : Curve]                      ; measures how much edge this broker has earned
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers — the fast learning stream
  [papers : VecDeque<PaperEntry>]      ; capped
  ;; Scalar learning — 4 accumulators (trail, stop, tp, runner-trail)
  [scalar-accums : Vec<ScalarAccumulator>]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

;; ── Constructor ─────────────────────────────────────────────────────────

(define (make-broker [observers : Vec<String>]
                     [slot-idx : usize]
                     [exit-count : usize]
                     [dims : usize]
                     [recalib-interval : usize]
                     [scalar-accums : Vec<ScalarAccumulator>])
  : Broker
  (make-broker
    observers
    slot-idx
    exit-count
    (make-reckoner (Discrete dims recalib-interval (list "Grace" "Violence")))
    (online-subspace dims 8)            ; noise subspace
    (make-curve)                        ; curve
    0.0                                 ; cumulative-grace
    0.0                                 ; cumulative-violence
    0                                   ; trade-count
    (deque)                             ; papers — empty
    scalar-accums
    (online-subspace dims 4)            ; good-state-subspace
    0                                   ; recalib-wins
    0                                   ; recalib-total
    0))                                 ; last-recalib-count

;; ── propose — noise update, strip noise, predict Grace/Violence ─────────

(define (propose [brkr : Broker]
                 [composed : Vector])
  : Prediction
  ;; 1. Feed the noise subspace
  (update (:noise-subspace brkr) composed)
  ;; 2. Strip noise — what remains is what's unusual
  (let ((denoised (anomalous-component (:noise-subspace brkr) composed)))
    ;; 3. Predict Grace/Violence from the denoised composed thought
    (predict (:reckoner brkr) denoised)))

;; ── edge — how much edge? ───────────────────────────────────────────────

(define (edge [brkr : Broker])
  : f64
  (if (proven? (:curve brkr) 50)
      (edge-at (:curve brkr) 0.5)
      0.0))

;; ── register-paper — create a paper entry every candle ──────────────────

(define (register-paper [brkr : Broker]
                        [composed : Vector]
                        [entry-price : f64]
                        [entry-atr : f64]
                        [distances : Distances])
  ;; Cap the deque — oldest papers fall off
  (when (>= (len (:papers brkr)) 200)
    (pop-front (:papers brkr)))
  (push-back (:papers brkr)
             (make-paper-entry composed entry-price entry-atr distances)))

;; ── tick-papers — tick all papers, resolve completed ────────────────────
;;
;; Returns: (Vec<Resolution>, Vec<LogEntry>)
;; Resolution facts and PaperResolved log entries.

(define (tick-papers [brkr : Broker]
                     [current-price : f64])
  : (Vec<Resolution>, Vec<LogEntry>)
  (let* ((resolutions (list))
         (logs (list))
         ;; Tick every paper and collect resolutions
         (new-papers
           (filter-map
             (lambda (paper)
               (let* ((ticked (tick-paper paper current-price)))
                 (if (fully-resolved? ticked)
                     ;; Paper resolved — extract learning signal for both sides
                     (begin
                       ;; Buy side resolution
                       (let* ((buy-pnl (paper-pnl ticked :up))
                              (buy-outcome (if (>= buy-pnl 0.0) :grace :violence))
                              (buy-optimal (compute-optimal-distances-paper ticked :up)))
                         (push! resolutions
                           (make-resolution (:slot-idx brkr)
                                            (:composed-thought ticked)
                                            :up
                                            buy-outcome
                                            (abs buy-pnl)
                                            buy-optimal))
                         (push! logs
                           (PaperResolved (:slot-idx brkr) buy-outcome buy-optimal)))
                       ;; Sell side resolution
                       (let* ((sell-pnl (paper-pnl ticked :down))
                              (sell-outcome (if (>= sell-pnl 0.0) :grace :violence))
                              (sell-optimal (compute-optimal-distances-paper ticked :down)))
                         (push! resolutions
                           (make-resolution (:slot-idx brkr)
                                            (:composed-thought ticked)
                                            :down
                                            sell-outcome
                                            (abs sell-pnl)
                                            sell-optimal))
                         (push! logs
                           (PaperResolved (:slot-idx brkr) sell-outcome sell-optimal)))
                       None)   ; drop the resolved paper
                     (Some ticked))))  ; keep unresolved paper
             (:papers brkr))))

    ;; Replace papers with the surviving ones
    (set! (:papers brkr) (deque new-papers))
    (list resolutions logs)))

;; ── compute-optimal-distances-paper — hindsight for a paper side ────────

(define (compute-optimal-distances-paper [paper : PaperEntry]
                                         [direction : Direction])
  : Distances
  (let* ((entry (:entry-price paper))
         (mfe (match direction
                (:up   (/ (- (:buy-extreme paper) entry) entry))
                (:down (/ (- entry (:sell-extreme paper)) entry))))
         (optimal-trail (max 0.002 (* mfe 0.5)))
         (mae (match direction
                (:up   (/ (- entry (:sell-extreme paper)) entry))
                (:down (/ (- (:buy-extreme paper) entry) entry))))
         (optimal-stop (max 0.005 (* mae 1.1)))
         (optimal-tp (max 0.005 mfe))
         (optimal-runner (max 0.005 (* mfe 0.75))))
    (make-distances optimal-trail optimal-stop optimal-tp optimal-runner)))

;; ── propagate — fan out resolved outcomes ───────────────────────────────
;;
;; Returns: (Vec<LogEntry>, PropagationFacts)
;; The broker learns its OWN lessons. It RETURNS what the observers need.
;; The post applies the facts to its own observers. Values up, not effects down.
;; NO observer vec params — the broker doesn't touch observers directly.

(define (propagate [brkr : Broker]
                   [composed-thought : Vector]
                   [outcome : Outcome]
                   [weight : f64]
                   [direction : Direction]
                   [optimal : Distances])
  : (Vec<LogEntry>, PropagationFacts)

  ;; 1. Grace/Violence to self — the broker's own reckoner learns
  (let* ((label (match outcome
                  (:grace    "Grace")
                  (:violence "Violence")))
         ;; Strip noise before learning
         (_ (update (:noise-subspace brkr) composed-thought))
         (denoised (anomalous-component (:noise-subspace brkr) composed-thought)))
    (observe (:reckoner brkr) denoised label weight)

    ;; 2. Feed the curve — was the prediction correct?
    (let* ((pred (predict (:reckoner brkr) denoised))
           (predicted-label (match pred
                              ((Discrete scores conviction)
                                (if (> (second (first scores))
                                       (second (second scores)))
                                    "Grace" "Violence"))))
           (correct (= label predicted-label)))
      (match pred
        ((Discrete scores conviction)
          (record-prediction (:curve brkr) conviction correct))))

    ;; 3. Update track record
    (match outcome
      (:grace    (set! (:cumulative-grace brkr)
                       (+ (:cumulative-grace brkr) weight)))
      (:violence (set! (:cumulative-violence brkr)
                       (+ (:cumulative-violence brkr) weight))))
    (inc! (:trade-count brkr))

    ;; 4. Engram gating — shared logic
    (let* ((gate-result (check-engram-gate
                          (:reckoner brkr)
                          (:good-state-subspace brkr)
                          (:recalib-wins brkr)
                          (:recalib-total brkr)
                          (:last-recalib-count brkr)
                          (= outcome :grace)
                          "Grace")))
      (set! (:recalib-wins brkr) (first gate-result))
      (set! (:recalib-total brkr) (second gate-result))
      (set! (:last-recalib-count brkr) (nth gate-result 2)))

    ;; 5. Scalar accumulators learn the optimal distances
    (observe-scalar (nth (:scalar-accums brkr) 0)
                    (:trail optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 1)
                    (:stop optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 2)
                    (:tp optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 3)
                    (:runner-trail optimal) outcome weight)

    ;; 6. Derive observer indices from slot-idx
    (let* ((market-idx (/ (:slot-idx brkr) (:exit-count brkr)))
           (exit-idx   (mod (:slot-idx brkr) (:exit-count brkr)))
           ;; Build propagation facts — the post will apply these
           (facts (make-propagation-facts
                    market-idx
                    exit-idx
                    direction
                    composed-thought
                    optimal
                    weight))
           ;; Log entry — observers-updated = (len (:observer-names brkr))
           (logs (list (Propagated (:slot-idx brkr)
                                   (len (:observer-names brkr))))))
      (list logs facts))))

;; ── paper-count ─────────────────────────────────────────────────────────

(define (paper-count [brkr : Broker])
  : usize
  (len (:papers brkr)))
