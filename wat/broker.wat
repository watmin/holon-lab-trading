;; ── broker.wat ──────────────────────────────────────────────────────
;;
;; The accountability primitive. Binds one market observer + one exit
;; observer. N×M brokers total. Holds papers. Propagates resolved
;; outcomes to every observer in the set. Measures Grace or Violence.
;; The broker's identity IS the set of observer names it closes over.
;; Depends on: Reckoner :discrete, OnlineSubspace, ScalarAccumulator,
;;             PaperEntry, Distances, enums, engram-gate.

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require engram-gate)
(require paper-entry)
(require simulation)

;; ── Resolution — what a broker produces when a paper resolves ──────
;; Facts, not mutations. Collected from parallel tick, applied sequentially.
;; A paper has two sides (buy and sell). Each side resolves independently.
;; Each resolved side produces one Resolution with its own direction.

(struct resolution
  [broker-slot-idx : usize]           ; which broker produced this
  [composed-thought : Vector]          ; the thought that was tested
  [direction : Direction]              ; :up or :down — matches the side tested
  [outcome : Outcome]                  ; :grace or :violence
  [amount : f64]                       ; how much value
  [optimal-distances : Distances])     ; hindsight optimal

;; ── PropagationFacts — what the broker returns for observer learning ─

(struct propagation-facts
  [market-idx : usize]                ; which market observer should learn
  [exit-idx : usize]                  ; which exit observer should learn
  [direction : Direction]              ; for the market observer
  [composed-thought : Vector]          ; for both observers
  [optimal : Distances]                ; for the exit observer
  [weight : f64])                      ; for both observers

;; ── Broker struct ───────────────────────────────────────────────────

(struct broker
  [observer-names : Vec<String>]       ; the identity. e.g. ("momentum" "volatility").
                                       ; Diagnostic identity for the ledger.
  [slot-idx : usize]                   ; position in the N×M grid. THE identity.
  [exit-count : usize]                 ; M — needed to derive market-idx and exit-idx:
                                       ; market-idx = slot-idx / exit-count
                                       ; exit-idx   = slot-idx mod exit-count
  ;; Accountability
  [reckoner : Reckoner]                ; :discrete — Grace/Violence
  [noise-subspace : OnlineSubspace]
  ;; The reckoner carries its own curve. resolve() feeds it. edge-at() reads it.
  ;; No separate curve field.
  ;; Track record
  [cumulative-grace : f64]
  [cumulative-violence : f64]
  [trade-count : usize]
  ;; Papers — the fast learning stream
  [papers : VecDeque<PaperEntry>]      ; capped
  ;; Scalar learning — two accumulators: trail-distance, stop-distance
  [scalar-accums : Vec<ScalarAccumulator>]
  ;; Engram gating
  [good-state-subspace : OnlineSubspace]
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

;; ── Interface ───────────────────────────────────────────────────────

(define (make-broker [observers : Vec<String>]
                     [slot-idx : usize]
                     [exit-count : usize]
                     [dims : usize]
                     [recalib-interval : usize]
                     [scalar-accums : Vec<ScalarAccumulator>])
  : Broker
  ;; noise-subspace: 8 principal components. good-state-subspace: 4 components.
  ;; Same k values as MarketObserver — same mechanism, same dimensionality needs.
  (broker
    observers
    slot-idx
    exit-count
    (reckoner "accountability" dims recalib-interval
              (Discrete '("Grace" "Violence")))
    (online-subspace dims 8)           ; noise-subspace
    0.0                                ; cumulative-grace
    0.0                                ; cumulative-violence
    0                                  ; trade-count
    (deque)                            ; papers
    scalar-accums
    (online-subspace dims 4)           ; good-state-subspace
    0                                  ; recalib-wins
    0                                  ; recalib-total
    0))                                ; last-recalib-count

(define (propose [broker : Broker]
                 [composed : Vector])
  : Prediction
  ;; Noise update → strip noise → predict Grace/Violence.
  (begin
    (update (:noise-subspace broker) composed)
    (let ((clean (anomalous-component (:noise-subspace broker) composed)))
      (predict (:reckoner broker) clean))))

(define (edge [broker : Broker])
  : f64
  ;; How much edge? Reads from the reckoner's internal curve.
  ;; 0.0 = no edge. The treasury funds proportionally.
  (let ((pred (predict (:reckoner broker) (zeros))))
    (match pred
      ((Discrete _ conviction)
        (edge-at (:reckoner broker) conviction)))))

(define (register-paper [broker : Broker]
                        [composed : Vector]
                        [entry-price : f64]
                        [distances : Distances])
  ;; Create a paper entry — every candle, every broker.
  (push-back (:papers broker)
             (make-paper-entry composed entry-price distances)))

(define (tick-papers [broker : Broker]
                     [current-price : f64])
  : (Vec<Resolution> Vec<LogEntry>)
  ;; Tick all papers, resolve completed. Returns resolution facts and
  ;; PaperResolved log entries.
  ;; Paper optimal-distances: papers derive optimal distances from their
  ;; tracked extremes (MFE/MAE) — a simpler approximation than full replay.
  (let ((resolutions (list))
        (logs (list))
        (remaining (deque)))
    (for-each
      (lambda (paper)
        (let ((ticked (tick-paper paper current-price)))
          (if (and (:buy-resolved ticked) (:sell-resolved ticked))
              ;; Both sides resolved — produce resolutions
              (let* ((entry (:entry-price ticked))
                     ;; Buy side: price rose then retraced → direction :up
                     (buy-excursion (/ (- (:buy-extreme ticked) entry) entry))
                     (sell-excursion (/ (- entry (:sell-extreme ticked)) entry))
                     ;; Derive optimal distances from tracked extremes
                     (optimal (compute-optimal-distances
                                entry
                                (:buy-extreme ticked)
                                (:sell-extreme ticked)))
                     ;; Buy side resolution
                     (buy-amount buy-excursion)
                     (buy-outcome (if (> buy-excursion
                                         (:trail (:distances ticked)))
                                      :grace :violence))
                     ;; Sell side resolution
                     (sell-amount sell-excursion)
                     (sell-outcome (if (> sell-excursion
                                          (:trail (:distances ticked)))
                                       :grace :violence)))
                (push! resolutions
                       (make-resolution (:slot-idx broker)
                                        (:composed-thought ticked)
                                        :up buy-outcome buy-amount optimal))
                (push! resolutions
                       (make-resolution (:slot-idx broker)
                                        (:composed-thought ticked)
                                        :down sell-outcome sell-amount optimal))
                (push! logs (PaperResolved (:slot-idx broker)
                                           buy-outcome optimal))
                (push! logs (PaperResolved (:slot-idx broker)
                                           sell-outcome optimal)))
              ;; Not fully resolved — keep it
              (push-back remaining ticked))))
      (:papers broker))
    (set! broker :papers remaining)
    (list resolutions logs)))

(define (propagate [broker : Broker]
                   [thought : Vector]
                   [outcome : Outcome]
                   [weight : f64]
                   [direction : Direction]
                   [optimal : Distances])
  : (Vec<LogEntry> PropagationFacts)
  ;; The broker learns its OWN lessons (reckoner + its internal curve,
  ;; engram, track record, scalars). It RETURNS what the observers need —
  ;; the post applies the facts to its own observers. Values up, not
  ;; effects down.
  (let ((logs (list))
        ;; Derive observer indices from slot-idx
        (market-idx (/ (:slot-idx broker) (:exit-count broker)))
        (exit-idx   (mod (:slot-idx broker) (:exit-count broker))))
    ;; 1. Reckoner learns Grace/Violence
    (observe (:reckoner broker) thought outcome weight)
    ;; 2. Feed the internal curve
    (let* ((pred (predict (:reckoner broker) thought))
           (conviction (match pred ((Discrete _ c) c)))
           (correct? (match outcome
                       (:grace true)
                       (:violence false))))
      (resolve (:reckoner broker) conviction correct?))
    ;; 3. Track record
    (match outcome
      (:grace    (set! broker :cumulative-grace
                       (+ (:cumulative-grace broker) weight)))
      (:violence (set! broker :cumulative-violence
                       (+ (:cumulative-violence broker) weight))))
    (inc! broker :trade-count)
    ;; 4. Scalar accumulators learn — trail and stop distances
    (observe-scalar (nth (:scalar-accums broker) 0)
                    (:trail optimal) outcome weight)
    (observe-scalar (nth (:scalar-accums broker) 1)
                    (:stop optimal) outcome weight)
    ;; 5. Engram gate
    (let ((gate-state (check-engram-gate
                        (:reckoner broker)
                        (:good-state-subspace broker)
                        (engram-gate-state
                          (:recalib-wins broker)
                          (:recalib-total broker)
                          (:last-recalib-count broker))
                        500   ; recalib-interval — from ctx
                        0.55)))
      (set! broker :recalib-wins (:recalib-wins gate-state))
      (set! broker :recalib-total (:recalib-total gate-state))
      (set! broker :last-recalib-count (:last-recalib-count gate-state)))
    ;; Return: log entries + propagation facts for the post
    (push! logs (Propagated (:slot-idx broker) 2))
    (list logs
          (make-propagation-facts market-idx exit-idx direction
                                  thought optimal weight))))

(define (paper-count [broker : Broker])
  : usize
  (len (:papers broker)))
