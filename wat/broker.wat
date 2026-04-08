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
; Message protocol: prediction (Grace/Violence) + funding (the edge).

(require primitives)
(require enums)               ; Outcome, Direction, Prediction, reckoner-config
(require distances)           ; Distances
(require scalar-accumulator)  ; ScalarAccumulator, observe-scalar
(require paper-entry)         ; PaperEntry, make-paper-entry, tick-paper, fully-resolved?
(require market-observer)     ; MarketObserver, resolve
(require exit-observer)       ; ExitObserver, observe-distances

;; ── Resolution — what a broker produces when a paper resolves ───────────
;; Facts, not mutations. Collected from parallel tick, applied sequentially.

(struct resolution
  [broker-slot-idx : usize]    ; which broker produced this
  [composed-thought : Vector]  ; the thought that was tested
  [direction : Direction]      ; :up or :down — the side that resolved
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value
  [optimal-distances : Distances]) ; hindsight optimal

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

;; ── funding — how much edge? ────────────────────────────────────────────
;;
;; The curve reads the broker's accuracy at its typical conviction level.
;; 0.0 = no edge. The treasury funds proportionally.

(define (funding [brkr : Broker])
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
;; Returns resolution facts. The broker knows its slot index and its
;; observer indices — it doesn't need them passed in except slot-idx
;; for the resolution struct.

(define (tick-papers [brkr : Broker]
                     [current-price : f64]
                     [slot-idx : usize])
  : Vec<Resolution>
  (let* ((resolutions (list))
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
                           (make-resolution slot-idx
                                            (:composed-thought ticked)
                                            :up
                                            buy-outcome
                                            (abs buy-pnl)
                                            buy-optimal)))
                       ;; Sell side resolution
                       (let* ((sell-pnl (paper-pnl ticked :down))
                              (sell-outcome (if (>= sell-pnl 0.0) :grace :violence))
                              (sell-optimal (compute-optimal-distances-paper ticked :down)))
                         (push! resolutions
                           (make-resolution slot-idx
                                            (:composed-thought ticked)
                                            :down
                                            sell-outcome
                                            (abs sell-pnl)
                                            sell-optimal)))
                       None)   ; drop the resolved paper
                     (Some ticked))))  ; keep unresolved paper
             (:papers brkr))))

    ;; Replace papers with the surviving ones
    (set! (:papers brkr) (deque new-papers))
    resolutions))

;; ── compute-optimal-distances-paper — hindsight for a paper side ────────
;;
;; Given a resolved paper and a direction, compute what the optimal
;; trail distance would have been. The paper's price extremes tell us
;; the maximum favorable excursion and maximum adverse excursion.

(define (compute-optimal-distances-paper [paper : PaperEntry]
                                         [direction : Direction])
  : Distances
  (let* ((entry (:entry-price paper))
         ;; MFE = how far price moved favorably before retracing
         ;; MAE = how far price moved adversely
         (mfe (match direction
                (:up   (/ (- (:buy-extreme paper) entry) entry))
                (:down (/ (- entry (:sell-extreme paper)) entry))))
         ;; Optimal trail: tight enough to capture most of MFE
         ;; but not so tight it exits prematurely. Heuristic: half the MFE.
         (optimal-trail (max 0.002 (* mfe 0.5)))
         ;; Optimal stop: just beyond the MAE
         (mae (match direction
                (:up   (/ (- entry (:sell-extreme paper)) entry))
                (:down (/ (- (:buy-extreme paper) entry) entry))))
         (optimal-stop (max 0.005 (* mae 1.1)))
         ;; Optimal TP: at the MFE
         (optimal-tp (max 0.005 mfe))
         ;; Optimal runner trail: wider than trail — house money
         (optimal-runner (max 0.005 (* mfe 0.75))))
    (make-distances optimal-trail optimal-stop optimal-tp optimal-runner)))

;; ── propagate — fan out resolved outcomes ───────────────────────────────
;;
;; Routes:
;;   Grace/Violence + thought + weight -> broker's own reckoner
;;   direction + thought + weight -> market observer via resolve
;;   optimal distances + composed thought + weight -> exit observer via observe-distances
;;
;; The post passes its observer vecs — the broker uses its frozen indices
;; to reach the right observers.

(define (propagate [brkr : Broker]
                   [thought : Vector]
                   [outcome : Outcome]
                   [weight : f64]
                   [direction : Direction]
                   [optimal : Distances]
                   [market-observers : Vec<MarketObserver>]
                   [exit-observers : Vec<ExitObserver>])

  ;; 1. Grace/Violence to self — the broker's own reckoner learns
  (let* ((label (match outcome
                  (:grace    "Grace")
                  (:violence "Violence")))
         ;; Strip noise before learning
         (_ (update (:noise-subspace brkr) thought))
         (denoised (anomalous-component (:noise-subspace brkr) thought)))
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

    ;; 4. Engram gating — check for recalibration
    (let ((current-recalib (recalib-count (:reckoner brkr))))
      (when (> current-recalib (:last-recalib-count brkr))
        (if (= outcome :grace)
            (inc! (:recalib-wins brkr))
            (begin))
        (inc! (:recalib-total brkr))
        ;; Snapshot discriminant if good accuracy
        (when (and (> (:recalib-total brkr) 0)
                   (> (/ (+ (:recalib-wins brkr) 0.0)
                         (+ (:recalib-total brkr) 0.0))
                      0.55))
          (let ((disc (discriminant (:reckoner brkr) "Grace")))
            (when-let ((d (Some disc)))
              (update (:good-state-subspace brkr) d))))
        (set! (:recalib-wins brkr) 0)
        (set! (:recalib-total brkr) 0)
        (set! (:last-recalib-count brkr) current-recalib)))

    ;; 5. Direction -> market observer via resolve
    (let ((mkt-obs (nth market-observers (:market-idx brkr))))
      (resolve mkt-obs thought direction weight))

    ;; 6. Optimal distances -> exit observer via observe-distances
    (let ((exit-obs (nth exit-observers (:exit-idx brkr))))
      (observe-distances exit-obs thought optimal weight))

    ;; 7. Scalar accumulators learn the optimal distances
    ;;    Each distance feeds its corresponding accumulator.
    (observe-scalar (nth (:scalar-accums brkr) 0)
                    (:trail optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 1)
                    (:stop optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 2)
                    (:tp optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums brkr) 3)
                    (:runner-trail optimal) outcome weight)))

;; ── paper-count ─────────────────────────────────────────────────────────

(define (paper-count [brkr : Broker])
  : usize
  (len (:papers brkr)))
