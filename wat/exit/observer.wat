;; -- exit/observer.wat -- judgment over market thoughts ----------------------
;;
;; The exit observer asks a different question than the market observer.
;; Market observer: "which direction?"
;; Exit observer:   "given these market thoughts, which side was better?"
;;
;; Same template. Same two-stage pipeline. Different vocabulary domain.
;; Receives market thought vectors — does not encode from candles.
;; Binds its own judgment facts to each market thought, judges independently.
;; Labels: Buy / Sell (which side experienced more grace).
;;
;; Resolution: dual-sided excursion. Both sides played. Both sides tracked.
;; The market fills in all four cells. No prediction decides the label.

(require core/primitives)
(require core/structural)
(require std/memory)           ;; OnlineSubspace
(require journal)
(require window-sampler)

;; -- Constants ----------------------------------------------------------------

(define NOISE_MIN_SAMPLES 50)  ;; minimum noise observations before subspace activates

;; -- Lens (enum) --------------------------------------------------------------
;; Each exit observer has a judgment lens — what it looks for in the environment.
;; Not "which way?" but "is now a good time, and how much room?"

(enum exit-lens :volatility :structure :timing :exit-generalist)

;; -- Dual-sided excursion -----------------------------------------------------
;; The honest label. Both sides played from the same candle.
;; No prediction decides which direction to measure.
;;
;; Four floats per entry. Updated every candle as prices evolve.
;; Resolution: when BOTH sides' trailing stops fire organically.
;; No horizon. No age limit. The market resolves both sides.

(struct dual-excursion
  buy-mfe                ; max upward move from entry (positive)
  buy-mae                ; max downward move from entry (negative)
  sell-mfe               ; max downward move from entry (positive, inverted)
  sell-mae               ; max upward move from entry (negative, inverted)
  ;; Trailing stop state — one per side
  buy-extreme            ; best rate in buy direction
  buy-trail-stop         ; trailing stop level for buy side
  sell-extreme           ; best rate in sell direction
  sell-trail-stop        ; trailing stop level for sell side
  ;; Resolution flags
  buy-resolved           ; bool — buy side's stop or TP fired
  sell-resolved          ; bool — sell side's stop or TP fired
  buy-exit-reason        ; :trailing-stop | :take-profit | absent
  sell-exit-reason       ; :trailing-stop | :take-profit | absent
  ;; Entry context
  entry-rate             ; rate at entry candle
  entry-atr)             ; ATR at entry candle — scales stops

;; -- Pending exit entry -------------------------------------------------------
;; One per market thought per candle, buffered for resolution.

(struct exit-pending
  candle-idx
  market-observer-name   ; which market observer produced this thought
  market-thought         ; Vector — the market observer's encoded thought (passthrough)
  composed-thought       ; Vector — market thought bundled with exit judgment facts
  prediction             ; Prediction — exit observer's Buy/Sell prediction at entry
  excursion              ; DualExcursion — both sides tracked
  evicted)               ; bool — buffer safety valve fired before resolution

;; -- Crutches -----------------------------------------------------------------
;; k_stop, k_tp, k_trail are magic numbers. The trailing stop and take-profit
;; parameters that determine when each side resolves. They are better than a
;; horizon timer — the market's movement triggers resolution, not a clock —
;; but they are still parameters we chose, not parameters the machine learned.
;;
;; The buffer max-size is an implicit horizon and must be honest about that.
;; Entries that exceed max-size are evicted without labeling. No learning from
;; silence. The buffer is the system's definition of a learnable event.
;;
;; Future work: learn the multipliers retroactively. After both sides resolve,
;; the optimal k_trail is computable from hindsight. The exit observer learns
;; the mapping from market state to optimal parameters via scalar encoding:
;;   (bind (atom "optimal-trail") (encode-log optimal-k))
;; The scalar rides the discriminant. Prediction and explanation are one operation.

(define K_STOP 2.0)           ;; stop distance = K_STOP * ATR (crutch)
(define K_TP   3.0)           ;; take-profit distance = K_TP * ATR (crutch)
(define K_TRAIL 1.5)          ;; trailing stop distance = K_TRAIL * ATR (crutch)
(define BUFFER_MAX_SIZE 2000) ;; safety valve — evict without labeling (crutch)

;; -- State --------------------------------------------------------------------

(struct exit-observer
  lens                   ; exit-lens enum — which judgment vocabulary
  journal                ; Journal — labels: Buy / Sell
  noise-subspace         ; OnlineSubspace — learns texture of composed thoughts
  resolved               ; (deque (conviction, correct)) — resolved predictions
  good-state-subspace    ; OnlineSubspace — engram of discriminant states > 55% accuracy
  recalib-wins           ; u32
  recalib-total          ; u32
  last-recalib-count     ; usize
  window-sampler         ; WindowSampler — each exit observer discovers its own scale
  conviction-history     ; (deque f64) — cap 2000
  conviction-threshold   ; f64 — dynamic quantile threshold
  primary-label          ; Label — Buy (first registered)
  curve-valid            ; bool — proof gate: has this observer proven judgment edge?
  cached-accuracy        ; f64
  ;; Exit-specific: pending entries per market observer
  pending                ; (deque ExitPending) — the buffer. Both sides live here.
  pending-count)         ; usize — active (non-evicted) entries

;; Two OnlineSubspace instances, same pattern as market observer:
;;   noise-subspace:      operates on COMPOSED thought vectors. Learns from ALL compositions.
;;                        Background model. Strips noise before journal sees it.
;;   good-state-subspace: operates on DISCRIMINANT vectors. Learns what good journal states look like.

;; -- Construction -------------------------------------------------------------

(define (new-exit-observer lens dims recalib-interval seed)
  "Create an exit observer with Buy/Sell labels.
   Same template as market observer. Different question."
  (let ((jrnl (journal (format "exit-{}" lens) dims recalib-interval))
        (buy-label  (register jrnl "Buy"))
        (sell-label (register jrnl "Sell")))
    (exit-observer
      :lens lens
      :journal jrnl :primary-label buy-label
      :noise-subspace (online-subspace dims 8)
      :resolved (deque) :good-state-subspace (online-subspace dims 8)
      :recalib-wins 0 :recalib-total 0 :last-recalib-count 0
      :window-sampler (window-sampler seed 12 2016)
      :conviction-history (deque) :conviction-threshold 0.0
      :curve-valid false :cached-accuracy 0.0
      :pending (deque) :pending-count 0)))

;; -- Judgment vocabulary ------------------------------------------------------
;;
;; The exit observer binds its own facts to each market thought.
;; These facts describe whether the environment is favorable for ANY entry,
;; regardless of direction. Not "which way?" but "is now a good time?"
;;
;; Each exit lens sees a subset. The exit generalist sees all.

(define (encode-volatility-facts atr-now atr-slow squeeze-pct)
  "Volatility judge: is the environment stable enough to trade?"
  (list
    (bind (atom "atr-regime")      (encode-log atr-now))
    (bind (atom "atr-ratio")       (encode-log (/ atr-now atr-slow)))
    (bind (atom "squeeze-state")   (encode-linear (clamp squeeze-pct 0.0 1.0) 1.0))))

(define (encode-structure-facts trend-consistency adx support-resistance-quality)
  "Structure judge: is the structure clear enough to exploit?"
  (list
    (bind (atom "trend-consistency") (encode-linear (clamp trend-consistency 0.0 1.0) 1.0))
    (bind (atom "adx-strength")      (encode-log (max adx 1.0)))
    (bind (atom "structure-quality")  (encode-linear (clamp support-resistance-quality 0.0 1.0) 1.0))))

(define (encode-timing-facts momentum-state reversal-strength bars-since-cross)
  "Timing judge: is the timing right for entry?"
  (list
    (bind (atom "momentum-state")    (encode-linear (clamp momentum-state 0.0 1.0) 1.0))
    (bind (atom "reversal-strength") (encode-log (max reversal-strength 0.01)))
    (bind (atom "bars-since-cross")  (encode-log (max bars-since-cross 1)))))

;; -- Composition --------------------------------------------------------------
;; The exit observer receives a market thought vector and binds its judgment.
;; The composed thought is what the journal sees.

(define (compose exit-obs market-thought judgment-facts)
  "Bundle market thought with exit judgment facts.
   The market thought passes THROUGH. The exit observer judges it."
  (apply bundle (cons market-thought judgment-facts)))

;; -- Two-stage pipeline -------------------------------------------------------
;; Identical to market observer. Noise subspace + journal.

(define (strip-noise exit-obs thought)
  "Subtract noise manifold, L2-normalize the residual."
  (if (< (sample-count (:noise-subspace exit-obs)) NOISE_MIN_SAMPLES)
      thought
      (l2-normalize (anomalous-component (:noise-subspace exit-obs) thought))))

(define (residual-norm exit-obs thought)
  "How much signal remains after noise subtraction."
  (if (< (sample-count (:noise-subspace exit-obs)) NOISE_MIN_SAMPLES)
      1.0
      (l2-norm (anomalous-component (:noise-subspace exit-obs) thought))))

;; -- Observe ------------------------------------------------------------------
;; Per market observer, per candle: compose, update noise, predict, buffer.

(define (judge-thought exit-obs market-observer-name market-thought
                       judgment-facts candle-idx entry-rate entry-atr)
  "The full exit observer pipeline for one market thought.
   Compose → update noise subspace → strip noise → predict → buffer."
  (let* ((composed (compose exit-obs market-thought judgment-facts))
         ;; Noise subspace sees every composition
         (_ (update (:noise-subspace exit-obs) composed))
         ;; Journal sees the residual
         (residual (strip-noise exit-obs composed))
         (prediction (predict (:journal exit-obs) residual))
         ;; Initialize dual excursion — both sides start at zero
         (excursion (new-dual-excursion entry-rate entry-atr)))
    ;; Buffer for resolution
    (push-back (:pending exit-obs)
      (exit-pending
        :candle-idx candle-idx
        :market-observer-name market-observer-name
        :market-thought market-thought
        :composed-thought composed
        :prediction prediction
        :excursion excursion
        :evicted false))
    (inc! (:pending-count exit-obs))
    ;; Safety valve — evict oldest without labeling
    (when (> (:pending-count exit-obs) BUFFER_MAX_SIZE)
      (evict-oldest exit-obs))
    prediction))

;; -- Dual excursion tracking --------------------------------------------------

(define (new-dual-excursion entry-rate entry-atr)
  "Both sides start at zero. Stops computed from ATR at entry."
  (let ((buy-stop  (* entry-rate (- 1.0 (* K_STOP entry-atr))))
        (sell-stop (* entry-rate (+ 1.0 (* K_STOP entry-atr))))
        (buy-tp    (* entry-rate (+ 1.0 (* K_TP entry-atr))))
        (sell-tp   (* entry-rate (- 1.0 (* K_TP entry-atr)))))
    (dual-excursion
      :buy-mfe 0.0 :buy-mae 0.0
      :sell-mfe 0.0 :sell-mae 0.0
      :buy-extreme entry-rate :buy-trail-stop buy-stop
      :sell-extreme entry-rate :sell-trail-stop sell-stop
      :buy-resolved false :sell-resolved false
      :buy-exit-reason false :sell-exit-reason false
      :entry-rate entry-rate :entry-atr entry-atr)))

(define (tick-dual-excursion exc current-rate)
  "Update both sides with current price. Each side resolves independently.
   Buy side: rate going up is favorable.
   Sell side: rate going down is favorable (inverted)."
  (let ((entry (:entry-rate exc))
        (atr   (:entry-atr exc)))

    ;; -- Buy side --
    (when (not (:buy-resolved exc))
      (let* ((buy-move (- current-rate entry))
             (new-mfe (max (:buy-mfe exc) buy-move))
             (new-mae (min (:buy-mae exc) buy-move)))
        (set! (:buy-mfe exc) new-mfe)
        (set! (:buy-mae exc) new-mae)
        ;; Trail the buy stop upward
        (let ((new-extreme (max (:buy-extreme exc) current-rate)))
          (set! (:buy-extreme exc) new-extreme)
          (let ((trail (* new-extreme (- 1.0 (* K_TRAIL atr)))))
            (set! (:buy-trail-stop exc) (max (:buy-trail-stop exc) trail))))
        ;; Check resolution
        (cond
          ((<= current-rate (:buy-trail-stop exc))
           (set! (:buy-resolved exc) true)
           (set! (:buy-exit-reason exc) :trailing-stop))
          ((>= current-rate (* entry (+ 1.0 (* K_TP atr))))
           (set! (:buy-resolved exc) true)
           (set! (:buy-exit-reason exc) :take-profit)))))

    ;; -- Sell side --
    (when (not (:sell-resolved exc))
      (let* ((sell-move (- entry current-rate))
             (new-mfe (max (:sell-mfe exc) sell-move))
             (new-mae (min (:sell-mae exc) sell-move)))
        (set! (:sell-mfe exc) new-mfe)
        (set! (:sell-mae exc) new-mae)
        ;; Trail the sell stop downward (sell profits when rate drops)
        (let ((new-extreme (min (:sell-extreme exc) current-rate)))
          (set! (:sell-extreme exc) new-extreme)
          (let ((trail (* new-extreme (+ 1.0 (* K_TRAIL atr)))))
            (set! (:sell-trail-stop exc) (min (:sell-trail-stop exc) trail))))
        ;; Check resolution
        (cond
          ((>= current-rate (:sell-trail-stop exc))
           (set! (:sell-resolved exc) true)
           (set! (:sell-exit-reason exc) :trailing-stop))
          ((<= current-rate (* entry (- 1.0 (* K_TP atr))))
           (set! (:sell-resolved exc) true)
           (set! (:sell-exit-reason exc) :take-profit)))))))

(define (both-resolved? exc)
  (and (:buy-resolved exc) (:sell-resolved exc)))

;; -- Classification -----------------------------------------------------------
;; Which side experienced more grace? The label is honest because both sides
;; were played. The weight measures how decisively one side won.

(define (classify-dual-excursion exc)
  "Classify a dual-sided entry. Returns (label, weight).
   label: :buy or :sell (which side was better).
   weight: how decisively the market answered."
  (let ((buy-grace  (- (:buy-mfe exc)  (abs (:buy-mae exc))))
        (sell-grace (- (:sell-mfe exc) (abs (:sell-mae exc)))))
    (cond
      ((> buy-grace sell-grace)
       (list :buy  (max (- buy-grace sell-grace) 0.01)))
      ((> sell-grace buy-grace)
       (list :sell (max (- sell-grace buy-grace) 0.01)))
      (else
       (list :buy 0.01)))))  ;; tiebreaker — minimal weight

;; -- Resolution ---------------------------------------------------------------
;; When both sides of an entry have resolved, the exit observer learns.
;; Same resolve pattern as market observer — journal, accuracy, engram, curve.

(define (tick-pending exit-obs current-rate)
  "Tick all pending entries. Resolve any where both sides fired.
   Returns list of (market-observer-name, label, weight) for resolved entries."
  (let ((resolved-labels '()))
    (for-each
      (lambda (entry)
        (when (not (:evicted entry))
          (tick-dual-excursion (:excursion entry) current-rate)
          (when (both-resolved? (:excursion entry))
            (let* ((result (classify-dual-excursion (:excursion entry)))
                   (label  (first result))
                   (weight (second result)))
              ;; Learn from this resolution
              (resolve-exit exit-obs entry label weight)
              ;; Emit label for the market observer
              (push! resolved-labels
                (list (:market-observer-name entry) label weight))
              ;; Mark consumed
              (set! (:evicted entry) true)
              (dec! (:pending-count exit-obs))))))
      (:pending exit-obs))
    ;; Drain resolved entries from front of deque
    (while (and (not (empty? (:pending exit-obs)))
                (:evicted (first (:pending exit-obs))))
      (pop-front (:pending exit-obs)))
    resolved-labels))

(define (resolve-exit exit-obs entry label weight)
  "Resolve one entry. Learn in the journal. Track accuracy. Gate engrams."
  (let* ((residual (strip-noise exit-obs (:composed-thought entry)))
         (buy-label  (:primary-label exit-obs))
         (sell-label (second (labels (:journal exit-obs))))
         (jrnl-label (if (= label :buy) buy-label sell-label)))

    ;; 1. Journal learns
    (observe (:journal exit-obs) residual jrnl-label weight)

    ;; 2. Track accuracy
    (let ((predicted-buy (and (:direction (:prediction entry))
                              (= (:direction (:prediction entry)) :buy)))
          (correct (= (if predicted-buy :buy :sell) label)))
      (when (:direction (:prediction entry))
        (inc! (:recalib-total exit-obs))
        (when correct (inc! (:recalib-wins exit-obs))))

      ;; 3. Engram gating (same as market observer)
      (when (> (recalib-count (:journal exit-obs)) (:last-recalib-count exit-obs))
        (set! (:last-recalib-count exit-obs) (recalib-count (:journal exit-obs)))
        (when (and (>= (:recalib-total exit-obs) 20)
                   (> (/ (:recalib-wins exit-obs) (:recalib-total exit-obs)) 0.55))
          (when-let ((disc (discriminant (:journal exit-obs) (:primary-label exit-obs))))
            (update (:good-state-subspace exit-obs) disc)))
        (set! (:recalib-wins exit-obs) 0)
        (set! (:recalib-total exit-obs) 0))

      ;; 4-7. Resolved predictions, conviction, proof gate (same pattern)
      (when-let ((pred-dir (:direction (:prediction entry))))
        (push-back (:resolved exit-obs) (list (:conviction (:prediction entry)) correct))
        (when (> (len (:resolved exit-obs)) 2000)
          (pop-front (:resolved exit-obs)))

        (push-back (:conviction-history exit-obs) (:conviction (:prediction entry)))
        (when (> (len (:conviction-history exit-obs)) 2000)
          (pop-front (:conviction-history exit-obs)))
        (when (and (>= (len (:conviction-history exit-obs)) 200)
                   (= (mod (len (:resolved exit-obs)) 50) 0))
          (set! (:conviction-threshold exit-obs)
                (quantile (:conviction-history exit-obs) 0.6)))

        (when (>= (len (:resolved exit-obs)) 100)
          (let ((high-conv (filter (lambda (r) (>= (first r) (* (:conviction-threshold exit-obs) 0.8)))
                                   (:resolved exit-obs))))
            (when (>= (len high-conv) 20)
              (set! (:curve-valid exit-obs)
                    (> (/ (count (lambda (r) (second r)) high-conv)
                          (len high-conv))
                       0.52)))))))))

;; -- Eviction -----------------------------------------------------------------
;; Buffer safety valve. Entries that sit too long without both sides resolving
;; are evicted without labeling. No learning from silence.

(define (evict-oldest exit-obs)
  "Evict the oldest non-evicted entry. No label. No learning."
  (for-each
    (lambda (entry)
      (when (not (:evicted entry))
        (set! (:evicted entry) true)
        (dec! (:pending-count exit-obs))
        (return)))  ;; evict one, stop
    (:pending exit-obs)))

;; -- The exit observer's label feeds the market observers ----------------------
;;
;; The exit observer produces (label, weight) per market observer per resolved candle.
;; The desk translates this into Win/Loss per market observer based on what
;; each observer predicted at that candle:
;;
;;   exit says Buy  + observer predicted Buy  → Win,  weight from exit
;;   exit says Buy  + observer predicted Sell → Loss, weight from exit
;;   exit says Sell + observer predicted Sell → Win,  weight from exit
;;   exit says Sell + observer predicted Buy  → Loss, weight from exit
;;
;; The exit observer does not touch market observer journals directly.
;; It produces a value. The desk consumes it. Channels, not mutation.

;; -- Learning flow summary ----------------------------------------------------
;;
;; Every candle, per market observer thought:
;;   1. Market observer encodes candle → market-thought
;;   2. Exit observer encodes judgment facts from candle context
;;   3. composed = bundle(market-thought, judgment-facts...)
;;   4. noise-subspace.update(composed)
;;   5. residual = strip-noise(composed)
;;   6. prediction = journal.predict(residual)
;;   7. Buffer (composed, prediction, DualExcursion{zeros}) in pending
;;
;; Each pending entry, each candle:
;;   8. tick-dual-excursion(entry, current-rate)
;;      - buy side: track MFE/MAE, trail stop upward
;;      - sell side: track MFE/MAE, trail stop downward
;;      - each side resolves when its stop or TP fires
;;
;; When both sides resolved:
;;   9. classify-dual-excursion → Buy or Sell, weight = |buy_grace - sell_grace|
;;   10. resolve-exit(entry, label, weight) → journal learns
;;   11. Emit (market-observer-name, label, weight) to desk
;;   12. Desk translates to Win/Loss per market observer's prediction
;;
;; Buffer eviction (no resolution):
;;   13. Entry exceeds BUFFER_MAX_SIZE → evict without labeling
;;   14. No learning. The market was silent. The buffer enforces what is learnable.
;;
;; CSP channels:
;;   candles ──> [market observers] ──> market-thoughts
;;   market-thoughts ──> [exit observers] ──> composed-thoughts + predictions
;;   candle ticks ──> [pending buffer] ──> dual-excursion tracking
;;   resolved entries ──> [desk] ──> Win/Loss labels back to market observers
;;   resolved entries ──> [pair journals] ──> Grace/Violence from treasury

;; -- Transition from single-sided to dual-sided --------------------------------
;;
;; Hard switch. When an exit observer's curve-valid flips to true, the desk
;; switches from single-sided classify-excursion to dual-sided labels from
;; this exit observer. No blend. No mixing parameter. The noise subspace adapts
;; to the regime change. The journal accumulators decay old observations.
;; The architecture handles the transition. Not a parameter we tune.

;; -- What exit observers do NOT do --------------------------------------------
;; - Do NOT encode candles (they receive market thoughts)
;; - Do NOT decide trades (pair journals + treasury decide)
;; - Do NOT manage positions (the pair owns that)
;; - Do NOT see other exit observers (they are independent)
;; - Do NOT touch market observer journals (they emit labels to the desk)
;; - They judge, filter noise, learn from the residual, and offer labels.
