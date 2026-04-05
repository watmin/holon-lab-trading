;; -- enterprise.wat -- the four-step candle loop --------------------------------
;;
;; One candle. Four steps. Sequential. Reality first.
;; The parallelism is WITHIN Step 2 (par_iter with collect).
;; Steps are sequential. The CSP is in the collect().

(require core/primitives)
(require market/observer)
(require exit/observer)
(require exit/pair)

;; -- The treasury ---------------------------------------------------------------
;; Three flat vecs. N×M. Pre-allocated. Disjoint slots. Mutex-free.
;; Index: i = market_idx * M + exit_idx

(struct treasury
  registry      ; Vec<TupleJournal>       — N×M closures, permanent
  proposals     ; Vec<Option<Proposal>>   — N×M, cleared every candle
  trades        ; Vec<Option<Trade>>      — N×M, insert/remove
  ;; Accounting
  assets        ; asset balances, deployed/available
  equity        ; total value
  peak-equity)  ; high water mark

(define (treasury-index market-idx exit-idx m)
  "Flat index into N×M vecs. The index IS the pair identity."
  (+ (* market-idx m) exit-idx))

(define (get-or-create-journal treasury market-idx exit-idx)
  "O(1) lookup. The journal exists from startup — pre-allocated."
  (nth (:registry treasury) (treasury-index market-idx exit-idx (:m treasury))))

;; -- Step 1: RESOLVE ------------------------------------------------------------
;; Reality first. Money before thoughts.
;; Close triggered trades. Accounting. Propagate through tuple journals.

(define (step-resolve treasury current-price)
  "Iterate active trades. Check triggers. Settle what fired."
  (for-each-some (:trades treasury)
    (lambda (i trade)
      (when (triggered? trade current-price)
        ;; 1. Execute the swap
        (let ((result (settle trade (:assets treasury))))
          ;; 2. Update balance sheet
          (apply-settlement (:assets treasury) result)
          ;; 3. Compute Grace/Violence
          (let ((outcome (classify-outcome result))
                (closes  (price-history trade))
                (journal (nth (:registry treasury) i)))
            ;; 4. One call. The closure does the rest.
            (propagate journal outcome closes (:entry-price trade))
            ;; 5. Remove from active
            (set! (nth (:trades treasury) i) false)))))))

;; -- Step 2: COMPUTE + DISPATCH -------------------------------------------------
;; Market observers encode (parallel). Exit observers compose + propose (sequential).
;; The treasury is mutated during dispatch — journals looked up, proposals inserted.
;;
;; Returns: [(market-label, market-thought), ...] for Step 3.

(define (step-compute-dispatch treasury market-observers exit-observers candle)
  "Parallel encode, sequential dispatch. Returns fresh thoughts."

  ;; Phase A: parallel market encoding
  (let ((thoughts (pmap (lambda (obs)
                          (observe-candle obs (:candle-window candle) (:vm candle)))
                        market-observers)))

    ;; Phase B: sequential dispatch into treasury
    (for-each-indexed market-observers
      (lambda (mi market-obs)
        (let ((thought (nth thoughts mi)))
          (for-each-indexed exit-observers
            (lambda (ei exit-obs)
              (let* ((i       (treasury-index mi ei (len exit-observers)))
                     (journal (nth (:registry treasury) i))
                     ;; Exit observer composes: market thought + judgment facts
                     (composed (compose exit-obs thought candle))
                     ;; Query the learned stop
                     (distance (recommended-distance (:learned-stop journal) composed)))

                ;; Register paper entry on the journal
                (register-paper journal composed candle)

                ;; Propose if conditions met
                (when (and (funded? journal)
                           (> (:conviction (predict (:journal journal) composed)) 0.2)
                           (not (default-distance? (:learned-stop journal) distance)))
                  (set! (nth (:proposals treasury) i)
                        (proposal :composed composed
                                  :direction (:direction thought)
                                  :distance distance
                                  :conviction (:conviction thought))))))))))

    ;; Return the fresh thoughts for Step 3
    thoughts))

;; -- Step 3: PROCESS ------------------------------------------------------------
;; Update active trade triggers with fresh thoughts.
;; Tick paper entries. Resolve papers → learning.

(define (step-process treasury market-observers exit-observers thoughts current-price)
  "Use fresh thoughts to manage active trades and paper entries."

  ;; Active trades: update triggers
  (for-each-some (:trades treasury)
    (lambda (i trade)
      (let* ((mi (market-idx-from i (len exit-observers)))
             (ei (exit-idx-from i (len exit-observers)))
             (thought (nth thoughts mi))
             (exit-obs (nth exit-observers ei))
             (composed (compose exit-obs thought current-price))
             (journal  (nth (:registry treasury) i))
             (distance (recommended-distance (:learned-stop journal) composed)))
        ;; Adjust the trailing stop from the learned distance
        (adjust-trigger trade distance current-price))))

  ;; Paper entries: tick all journals' papers
  (for-each (:registry treasury)
    (lambda (journal)
      (tick-papers journal current-price))))

;; -- Step 4: COLLECT + FUND ----------------------------------------------------
;; Evaluate proposals. Fund or reject. Drain proposals vec.

(define (step-collect-fund treasury)
  "Iterate proposals. Fund the proven ones. Clear the vec."
  (for-each-some (:proposals treasury)
    (lambda (i proposal)
      (let ((journal (nth (:registry treasury) i)))
        (when (and (funded? journal)
                   (capital-available? treasury (:direction proposal))
                   (risk-allows? treasury))
          ;; Fund: execute the swap, insert into active trades
          (let ((trade (open-trade treasury proposal)))
            (set! (nth (:trades treasury) i) trade))))
      ;; Clear the proposal slot regardless
      (set! (nth (:proposals treasury) i) false))))

;; -- The candle loop ------------------------------------------------------------
;; Four steps. Sequential. Reality first. The parallelism is inside Step 2.

(define (on-candle treasury market-observers exit-observers candle)
  "One candle. Four steps."
  (let ((current-price (:close candle)))

    ;; Step 1: RESOLVE — close triggered trades, settle, propagate
    (step-resolve treasury current-price)

    ;; Step 2: COMPUTE + DISPATCH — encode, compose, propose
    (let ((thoughts (step-compute-dispatch treasury market-observers exit-observers candle)))

      ;; Step 3: PROCESS — update triggers, tick papers
      (step-process treasury market-observers exit-observers thoughts current-price))

    ;; Step 4: COLLECT + FUND — evaluate proposals, fund or reject
    (step-collect-fund treasury)))

;; -- Ownership summary ----------------------------------------------------------
;;
;; Treasury owns:
;;   registry[N×M]    — tuple journal closures (permanent)
;;   proposals[N×M]   — Option<Proposal> (cleared every candle)
;;   trades[N×M]      — Option<Trade> (insert/remove)
;;   assets           — balances, deployed/available
;;
;; Each TupleJournal closure owns:
;;   journal          — Grace/Violence labels
;;   learned_stop     — nearest neighbor regression
;;   scalar_accums    — per-magic-number f64 accumulators
;;   papers           — paper entries for this pair
;;   track_record     — cumulative grace/violence
;;
;; Market observers own:
;;   their own journal (direction Win/Loss)
;;   their own noise subspace
;;   their own window sampler
;;
;; Exit observers own:
;;   their judgment vocabulary (volatility, structure, timing)
;;   nothing else — they are stateless encoders that compose
;;
;; The desk is gone. The treasury IS the desk.
;; The manager is gone. The tuple journal IS the manager.
