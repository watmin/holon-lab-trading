;; -- enterprise.wat -- the four-step candle loop --------------------------------
;;
;; One candle. Four steps. Sequential. Reality first.
;; The parallelism is WITHIN Step 2 (par_iter with collect).
;; Steps are sequential. The CSP is in the collect().
;;
;; The desk is gone. The enterprise IS the desk.
;; The manager is gone. The tuple journal IS the manager.

(require core/primitives)
(require market/observer)       ; encode-thought, resolve (direction learning)
(require exit/observer)         ; encode-exit-facts, compose (exit learning)
(require tuple-journal)         ; register-paper, tick-papers, propose, funded?, propagate
(require position)              ; triggered?, classify-outcome, adjust-trigger, open-trade
(require candle)                ; tick (indicator-bank)
(require window-sampler)        ; sample

;; -- The enterprise ---------------------------------------------------------------
;; Owns the data pipeline, observers, and the N×M registry.
;; N market observers × M exit observers = N×M tuple journals.
;; Index: slot-idx = market-idx * M + exit-idx

(struct enterprise
  ;; Data pipeline
  indicator-bank       ; streaming indicator state machine
  candle-window        ; VecDeque<Candle>, bounded at max-window-size
  max-window-size      ; capacity (2016)

  ;; Observers — both are learned
  market-observers     ; Vec<MarketObserver> — predict direction, learn Win/Loss
  exit-observers       ; Vec<ExitObserver>   — predict exit distance, learn to maximize residue

  ;; Candle counter
  encode-count

  ;; Treasury — holds capital, executes swaps, settles trades
  treasury             ; Treasury — holds capital, executes swaps, settles trades

  ;; N×M registry — pre-allocated, disjoint slots, mutex-free
  registry             ; Vec<TupleJournal>       — closures over (market, exit), permanent
  proposals            ; Vec<Option<Proposal>>   — cleared every candle
  trades               ; Vec<Option<Trade>>      — insert/remove
  trade-thoughts       ; Vec<Option<Vector>>     — stashed at entry for resolution

  ;; Logging
  pending-logs)        ; Vec<LogEntry>, flushed in batch by the binary

;; -- Market observers -------------------------------------------------------------
;; A market observer perceives direction from candle data.
;; It has a window sampler, a lens, and a journal.
;; It encodes candles into thought vectors. It predicts direction.
;; It learns Win/Loss from trade and paper resolutions via propagate.
;; The generalist is just another lens. No special treatment.

;; -- Exit observers ---------------------------------------------------------------
;; An exit observer learns exit strategy — how to maximize residue.
;; It has a judgment vocabulary (volatility, structure, timing).
;; It composes market thoughts with its own judgment facts.
;; It learns optimal distances from trade and paper resolutions via propagate.
;; The LearnedStop IS its brain — it lives on the tuple journal,
;; which is the closure over (market-observer, exit-observer).
;; ExitGeneralist = all three vocabularies.

(define (enterprise-index market-idx exit-idx exit-count)
  "Flat index into N×M vecs. The index IS the pair identity."
  (+ (* market-idx exit-count) exit-idx))

;; -- Step 1: RESOLVE ------------------------------------------------------------
;; Reality first. Money before thoughts.
;; Close triggered trades. Propagate through tuple journals.
;; Propagate routes to BOTH observers: market learns direction, exit learns distance.

(define (step-resolve enterprise current-price candle-window)
  "Iterate active trades. Check triggers. Settle what fired."
  (for-each (range (len (:trades enterprise)))
    (lambda (slot-idx)
      (when-let ((trade (nth (:trades enterprise) slot-idx)))
        (when (triggered? trade current-price)
          (let* ((outcome (classify-outcome trade current-price))
                 (closes  (find-closes-from-entry candle-window trade))
                 (journal (nth (:registry enterprise) slot-idx))
                 (optimal (compute-optimal-distance closes (:entry-price trade))))

            ;; Propagate through the closure — routes to both observers
            (when-let ((thought (nth (:trade-thoughts enterprise) slot-idx)))
              (propagate journal thought outcome optimal))

            ;; Settle through treasury — execute swap, update balances
            (settle (:treasury enterprise) trade outcome)

            ;; Clear the slot
            (set! (nth (:trades enterprise) slot-idx) none)
            (set! (nth (:trade-thoughts enterprise) slot-idx) none)))))))

;; -- Step 2: COMPUTE + DISPATCH -------------------------------------------------
;; Market observers encode (parallel). Exit observers compose + propose (sequential).
;; Returns: fresh market thought vectors for Step 3.
;;
;; Exit facts are computed ONCE per candle per lens, reused across all market observers.

(define (step-compute-dispatch enterprise candle ctx)
  "Parallel encode, sequential dispatch. Returns fresh thoughts."

  ;; Phase A: parallel market encoding
  (let ((thoughts (pmap (lambda (obs)
                          (let ((w (sample (:window-sampler obs) (:encode-count enterprise)))
                                (slice (window-slice (:candle-window enterprise) w)))
                            (encode-thought obs slice ctx)))
                        (:market-observers enterprise)))

        ;; Pre-compute exit fact vectors: one per exit lens, reused across markets
        (exit-fact-vecs (map (lambda (exit-obs)
                              (encode-exit-facts exit-obs candle ctx))
                            (:exit-observers enterprise))))

    ;; Phase B: sequential dispatch into registry
    (for-each (range (len (:market-observers enterprise)))
      (lambda (market-idx)
        (let ((thought (nth thoughts market-idx)))
          (for-each (range (len (:exit-observers enterprise)))
            (lambda (exit-idx)
              (let* ((slot-idx  (enterprise-index market-idx exit-idx
                                  (len (:exit-observers enterprise))))
                     (journal   (nth (:registry enterprise) slot-idx))
                     (exit-obs  (nth (:exit-observers enterprise) exit-idx))
                     (exit-facts (nth exit-fact-vecs exit-idx))
                     ;; Compose: bundle market thought with exit facts
                     (composed  (bundle thought exit-facts))
                     ;; Query the exit observer — ONCE per slot per candle
                     (distance  (recommended-distance exit-obs composed)))

                ;; Register paper entry — every candle, every pair
                (register-paper journal composed candle distance)

                ;; Propose if conditions met
                (when (and (funded? journal)
                           (> (:conviction (propose journal composed)) 0.2)
                           (can-propose? exit-obs composed))
                  (set! (nth (:proposals enterprise) slot-idx)
                        (proposal :composed composed
                                  :direction (:direction (propose journal composed)))))))))))

    ;; Return the fresh thoughts for Step 3
    thoughts))

;; -- Step 3: PROCESS ------------------------------------------------------------
;; Update active trade triggers with fresh thoughts.
;; Tick paper entries. Resolved papers → propagate to both observers.

(define (step-process enterprise thoughts current-price)
  "Use fresh thoughts to manage active trades and paper entries."

  ;; Active trades: query the tuple journal's learned stop for the trigger distance
  (for-each (range (len (:trades enterprise)))
    (lambda (slot-idx)
      (when-let ((trade (nth (:trades enterprise) slot-idx)))
        (let* ((market-idx (quotient slot-idx (len (:exit-observers enterprise))))
               (exit-idx   (remainder slot-idx (len (:exit-observers enterprise))))
               (exit-obs   (nth (:exit-observers enterprise) exit-idx))
               (thought    (nth thoughts market-idx))
               (distance   (recommended-distance exit-obs thought)))
          (adjust-trigger trade distance current-price)))))

  ;; Paper entries: tick all journals' papers
  ;; Resolved papers propagate to both observers — the fast learning stream
  (for-each (range (len (:registry enterprise)))
    (lambda (slot-idx)
      (let ((journal (nth (:registry enterprise) slot-idx)))
        (tick-papers journal current-price)))))

;; -- Step 4: COLLECT + FUND ----------------------------------------------------
;; Evaluate proposals. Fund or reject. Drain proposals vec.

(define (step-collect-fund enterprise current-price current-atr)
  "Iterate proposals. Fund the proven ones. Clear the vec."
  (for-each (range (len (:proposals enterprise)))
    (lambda (slot-idx)
      (when-let ((proposal (nth (:proposals enterprise) slot-idx)))
        (let ((journal (nth (:registry enterprise) slot-idx)))
          (when (and (funded? journal)
                     (not (nth (:trades enterprise) slot-idx))
                     (capital-available? (:treasury enterprise) (:direction proposal))
                     true) ; risk-allows? — always true for now, not in 007
            (let ((trade (open-trade (:treasury enterprise) proposal current-price current-atr)))
              (set! (nth (:trades enterprise) slot-idx) trade)
              (set! (nth (:trade-thoughts enterprise) slot-idx) (:composed proposal)))))
        ;; Clear the proposal slot regardless
        (set! (nth (:proposals enterprise) slot-idx) none)))))

;; -- The candle loop ------------------------------------------------------------
;; One candle. Four steps.
;; The enterprise owns the data pipeline. It ticks its own indicators.

(define (on-candle enterprise raw ctx)
  "One raw candle in. Four steps. The enterprise owns everything."

  ;; Tick indicators → produce computed candle
  (let* ((candle (tick (:indicator-bank enterprise) raw))
         (current-price (:close candle)))

    ;; Push to window, trim
    (push! (:candle-window enterprise) candle)
    (when (> (len (:candle-window enterprise)) (:max-window-size enterprise))
      (pop-front (:candle-window enterprise)))

    ;; Advance the counter
    (inc! (:encode-count enterprise))

    ;; Step 1: RESOLVE — close triggered trades, propagate to both observers
    (step-resolve enterprise current-price (:candle-window enterprise))

    ;; Step 2: COMPUTE + DISPATCH — encode, compose, propose
    (let ((thoughts (step-compute-dispatch enterprise candle ctx)))

      ;; Step 3: PROCESS — update triggers, tick papers, propagate resolved
      (step-process enterprise thoughts current-price))

    ;; Step 4: COLLECT + FUND — evaluate proposals, fund or reject
    (step-collect-fund enterprise current-price (:atr candle))))

;; -- Ownership summary ----------------------------------------------------------
;;
;; Enterprise owns:
;;   indicator-bank         — streaming indicators (stateful, one per asset)
;;   candle-window          — bounded VecDeque<Candle>
;;   market-observers[N]    — predict direction, learn Win/Loss from propagation
;;   exit-observers[M]      — predict exit distance, learn to maximize residue
;;   treasury               — holds capital, executes swaps, settles trades
;;   registry[N×M]          — tuple journal closures over (market, exit), permanent
;;   proposals[N×M]         — Option<Proposal> (cleared every candle)
;;   trades[N×M]            — Option<Trade> (insert/remove)
;;   trade-thoughts[N×M]    — Option<Vector> (stashed at entry for resolution)
;;   encode-count           — candle counter
;;   pending-logs           — log buffer, flushed by binary
;;
;; Each TupleJournal is a closure over (market-observer, exit-observer):
;;   journal                — Grace/Violence labels (the pair's accountability)
;;   noise-subspace         — the closure's own noise model
;;   scalar-accums          — per-magic-number f64 accumulators
;;   papers                 — paper entries for this pair
;;   track-record           — cumulative grace/violence
;;
;;   propagate routes to BOTH observers:
;;     market-observer.resolve(thought, Win/Loss)              — direction learning
;;     exit-observer.observe-distance(thought, optimal, weight) — exit learning
;;     track-record ← Grace/Violence                           — accountability
;;
;; Market observers own:
;;   window-sampler         — log-uniform window sampling with seed
;;   lens                   — which vocabulary subset to encode
;;   journal                — direction prediction (Win/Loss)
;;   noise-subspace         — noise model for strip-noise
;;   The generalist is just another lens. No special treatment.
;;
;; Exit observers own:
;;   lens                   — judgment vocabulary (volatility, structure, timing)
;;   learned-stop           — nearest neighbor regression (the exit observer's brain)
;;   One LearnedStop per exit observer. M instances total. Not N×M.
;;   The composed thought carries the market observer's signal in superposition.
;;   The cosine regression recovers the right distance per thought region.
;;   ExitGeneralist = all three vocabularies.
;;
;; The desk is gone. The enterprise IS the desk.
;; The manager is gone. The tuple journal IS the manager.
