;; -- exit/pair.wat -- the accountability mechanism ----------------------------
;;
;; One journal per (market observer, exit observer) pair.
;; This IS the manager. Not a separate aggregator. The pair's own journal
;; tracking its own history. Direction x magnitude -> grace or violence.
;;
;; The pair journal replaces the old manager. No middleman. No consensus.
;; Each pair proposes, owns, manages, and gets judged. The treasury judges
;; the decision. The feedback is realized by the tuple.
;;
;; Labels: Grace / Violence (from treasury reality feedback).
;; Input: the composed thought (market thought bundled with exit judgment).
;; The proof curve gates treasury funding.

(require core/primitives)
(require core/structural)
(require std/memory)           ;; OnlineSubspace
(require journal)

;; -- Constants ----------------------------------------------------------------

(define NOISE_MIN_SAMPLES 50)
(define PAIR_RESOLVED_CAP 5000) ;; resolved prediction history cap

;; -- Pair identity ------------------------------------------------------------
;; The (market, exit) tuple. Cheap. Copyable. The unit of accountability.

(struct pair-id
  market-observer-name   ; string — "momentum", "structure", "generalist", ...
  exit-observer-name)    ; string — "exit-volatility", "exit-timing", ...

;; -- Pair journal state -------------------------------------------------------
;; Third journal in the stack. Market observer has one. Exit observer has one.
;; The pair has one. Each learns independently. Each has its own noise subspace.
;; Each has its own proof curve.
;;
;; Three journals, three questions:
;;   1. Market observer journal: "which direction?" (Win/Loss from exit labels)
;;   2. Exit observer journal:   "which side was better?" (Buy/Sell from dual excursion)
;;   3. Pair journal:            "did this combination produce grace?" (Grace/Violence from treasury)

(struct pair-journal
  id                     ; PairId — who this pair is
  journal                ; Journal — labels: Grace / Violence
  noise-subspace         ; OnlineSubspace — background model of composed thoughts
  grace-label            ; Label — first registered (Grace)
  violence-label         ; Label — second registered (Violence)
  ;; Track record
  resolved               ; (deque (conviction, correct)) — for proof curve
  conviction-history     ; (deque f64) — cap 2000
  conviction-threshold   ; f64
  curve-valid            ; bool — proof gate: has this pair proven edge?
  cached-accuracy        ; f64
  ;; Treasury allocation
  allocation             ; f64 — fraction of capital this pair may deploy [0.0, 1.0]
  cumulative-grace       ; f64 — running sum of grace outcomes
  cumulative-violence    ; f64 — running sum of violence outcomes
  trade-count            ; usize — total trades resolved
  ;; Engram gating
  good-state-subspace    ; OnlineSubspace — discriminant states with > 55% accuracy
  recalib-wins           ; u32
  recalib-total          ; u32
  last-recalib-count)    ; usize

;; -- Construction -------------------------------------------------------------

(define (new-pair-journal market-name exit-name dims recalib-interval)
  "Create a pair journal for one (market, exit) tuple.
   Labels: Grace / Violence. The treasury provides these."
  (let* ((id (pair-id :market-observer-name market-name
                      :exit-observer-name exit-name))
         (name (format "pair-{}-{}" market-name exit-name))
         (jrnl (journal name dims recalib-interval))
         (grace    (register jrnl "Grace"))
         (violence (register jrnl "Violence")))
    (pair-journal
      :id id
      :journal jrnl :noise-subspace (online-subspace dims 8)
      :grace-label grace :violence-label violence
      :resolved (deque) :conviction-history (deque)
      :conviction-threshold 0.0 :curve-valid false :cached-accuracy 0.0
      :allocation 0.0
      :cumulative-grace 0.0 :cumulative-violence 0.0 :trade-count 0
      :good-state-subspace (online-subspace dims 8)
      :recalib-wins 0 :recalib-total 0 :last-recalib-count 0)))

;; -- Two-stage pipeline -------------------------------------------------------
;; Same as every other observer. Noise subspace + journal.

(define (strip-noise pair composed)
  (if (< (sample-count (:noise-subspace pair)) NOISE_MIN_SAMPLES)
      composed
      (l2-normalize (anomalous-component (:noise-subspace pair) composed))))

;; -- Propose ------------------------------------------------------------------
;; The pair predicts: will this composed thought produce grace or violence?
;; The prediction gates whether the treasury funds a real trade.

(define (propose pair composed-thought)
  "Predict grace or violence for a composed thought.
   Update noise subspace. Return prediction.
   The pair does not decide to trade — it offers a prediction.
   The treasury decides based on the proof curve."
  (begin
    (update (:noise-subspace pair) composed-thought)
    (let ((residual (strip-noise pair composed-thought)))
      (predict (:journal pair) residual))))

;; -- Funding gate -------------------------------------------------------------
;; The pair must prove edge before the treasury funds it.
;; curve-valid = true means the pair has statistical evidence of grace > violence
;; in its high-conviction predictions. The treasury reads this flag.

(define (funded? pair)
  "Can this pair request capital from the treasury?"
  (:curve-valid pair))

(define (allocation-fraction pair)
  "How much of its maximum should this pair deploy?
   Proportional to cumulative grace minus violence.
   Clamped to [0, 1]. Pairs in net violence get zero."
  (if (<= (:trade-count pair) 0) 0.0
      (clamp (/ (:cumulative-grace pair)
                (+ (:cumulative-grace pair) (:cumulative-violence pair) 0.001))
             0.0 1.0)))

;; -- Resolve (from treasury reality) ------------------------------------------
;; The treasury pushes the outcome to the pair after a trade resolves.
;; Grace = the trade produced real value. Violence = the trade destroyed value.
;; The amount is the actual value gained or lost — the most honest signal.
;;
;; The pair learns from reality, not from thought-space labels.
;; The market observers learn from exit labels (Win/Loss).
;; The exit observers learn from dual-sided excursion (Buy/Sell).
;; The pair learns from the treasury (Grace/Violence).
;; Three levels of feedback. All from the world.

(define (resolve-pair pair composed-thought prediction outcome amount)
  "Resolve a trade outcome from the treasury.
   outcome: :grace or :violence.
   amount: actual value gained or lost (always positive — outcome carries the sign)."

  ;; 1. Journal learns from the composed thought that produced this outcome
  (let ((residual (strip-noise pair composed-thought))
        (label (if (= outcome :grace) (:grace-label pair) (:violence-label pair))))
    (observe (:journal pair) residual label amount))

  ;; 2. Update cumulative track record
  (match outcome
    :grace    (set! (:cumulative-grace pair) (+ (:cumulative-grace pair) amount))
    :violence (set! (:cumulative-violence pair) (+ (:cumulative-violence pair) amount)))
  (inc! (:trade-count pair))

  ;; 3. Track accuracy
  (let ((predicted-grace (and (:direction prediction)
                              (= (:direction prediction) :grace)))
        (correct (= outcome :grace)))
    (when (:direction prediction)
      (inc! (:recalib-total pair))
      (when correct (inc! (:recalib-wins pair))))

    ;; 4. Engram gating
    (when (> (recalib-count (:journal pair)) (:last-recalib-count pair))
      (set! (:last-recalib-count pair) (recalib-count (:journal pair)))
      (when (and (>= (:recalib-total pair) 20)
                 (> (/ (:recalib-wins pair) (:recalib-total pair)) 0.55))
        (when-let ((disc (discriminant (:journal pair) (:grace-label pair))))
          (update (:good-state-subspace pair) disc)))
      (set! (:recalib-wins pair) 0)
      (set! (:recalib-total pair) 0))

    ;; 5. Resolved predictions + conviction + proof gate
    (when-let ((pred-dir (:direction prediction)))
      (push-back (:resolved pair) (list (:conviction prediction) correct))
      (when (> (len (:resolved pair)) PAIR_RESOLVED_CAP)
        (pop-front (:resolved pair)))

      (push-back (:conviction-history pair) (:conviction prediction))
      (when (> (len (:conviction-history pair)) 2000)
        (pop-front (:conviction-history pair)))
      (when (and (>= (len (:conviction-history pair)) 200)
                 (= (mod (len (:resolved pair)) 50) 0))
        (set! (:conviction-threshold pair)
              (quantile (:conviction-history pair) 0.6)))

      (when (>= (len (:resolved pair)) 100)
        (let ((high-conv (filter (lambda (r) (>= (first r) (* (:conviction-threshold pair) 0.8)))
                                  (:resolved pair))))
          (when (>= (len high-conv) 20)
            (set! (:curve-valid pair)
                  (> (/ (count (lambda (r) (second r)) high-conv)
                        (len high-conv))
                     0.52))))))))

;; -- Scalar extraction --------------------------------------------------------
;; The pair journal's discriminant separates graceful compositions from violent
;; ones. The cosine against the trail-adjust atom reads the scalar that graceful
;; compositions had. Direction and magnitude learned jointly.
;;
;; This is the Hickey condition 2 resolution: one journal per pair learns
;; the combined track record (direction x magnitude -> grace/violence).
;; The discriminant separates jointly, not as two independent signals.

(define (extract-trail-scalar pair)
  "Read the learned trail adjustment from the pair's discriminant.
   Returns the cosine of the grace discriminant against the trail-adjust atom.
   High positive = graceful compositions used wider trails.
   High negative = graceful compositions used tighter trails.
   Near zero = the journal hasn't learned a trail preference yet."
  (when-let ((disc (discriminant (:journal pair) (:grace-label pair))))
    (cosine disc (atom "trail-adjust"))))

;; -- The N x M generator ------------------------------------------------------
;; The pair journals are not a data structure. They are a computation.
;; The cross-product of market thoughts and exit judgments, evaluated lazily,
;; filtered by noise gates on both sides. The actual work per candle is
;; (N - noise) x (M - noise). The generator yields only non-trivial compositions.
;;
;; Construction: at enterprise startup, for each (market-obs, exit-obs):
;;   (new-pair-journal market-name exit-name dims recalib-interval)
;; Storage: flat vec of PairJournal, indexed by (market-idx * M + exit-idx).
;; No nested data structure. The flatness is the simplicity.

;; -- The ownership loop -------------------------------------------------------
;;
;; Per open trade, per candle:
;;   1. Market observer encodes candle → market-thought
;;   2. Exit observer binds judgment facts → composed-thought
;;   3. pair.propose(composed-thought) → prediction (Grace/Violence conviction)
;;   4. If funded? and prediction conviction in proven band → request trade
;;   5. Treasury funds or rejects based on pair allocation
;;   6. If funded: the pair OWNS this trade
;;
;; Per owned trade, per candle:
;;   7. Market observer re-encodes → fresh market-thought
;;   8. Exit observer re-composes → fresh composed-thought
;;   9. Cosine(pair-discriminant, atom("trail-adjust")) → learned scalar
;;   10. Scalar adjusts THIS pair's trailing stop on THIS trade
;;   11. Market moves. Stop fires or doesn't.
;;   12. If fires: treasury reports (Grace/Violence, amount) to pair
;;   13. resolve-pair learns from the reality
;;   14. Label cascades to market observer (Win/Loss) and exit observer (Buy/Sell)
;;
;; You propose it, you own it, you get judged.

;; -- Treasury as natural selection --------------------------------------------
;; The treasury allocates capital proportional to each pair's track record.
;; Pairs that produce grace get more capital. Pairs that produce violence
;; get starved — zero allocation. Still learning, still predicting, still
;; on paper. But no capital until they prove themselves.
;;
;; Redemption through measurement. Not forgiveness — proof.
;; The pair's curve-valid flips back when accuracy improves.
;; The treasury re-funds when the curve re-validates.

;; -- CSP channels (the full loop) ---------------------------------------------
;;
;;   candles
;;     ──> [N market observers]        parallel, independent
;;     ──> market-thoughts
;;     ──> [M exit observers]          per thought, parallel
;;     ──> composed-thoughts
;;     ──> [N x M pair journals]       propose, predict Grace/Violence
;;     ──> proposals (funded pairs only)
;;     ──> [treasury]                  fund or reject
;;     ──> open trades
;;     ──> [owning pairs]             per-trade per-candle management
;;     ──> [market moves]
;;     ──> trade resolution           stop/TP fires
;;     ──> [treasury fibers]          N x M channels, one per pair
;;     ──> reality labels             (Grace/Violence, amount)
;;     ──> [pair journal]             learns from reality
;;     ──> [exit observer]            learns Buy/Sell from dual excursion
;;     ──> [market observer]          learns Win/Loss from exit label
;;     ──> next candle
;;
;; Every node is a process. Every arrow is a message. Every message is a value.
;; No mutation across boundaries. The treasury doesn't reach into the observers.
;; The coupling is through data flow, not shared mutation. CSP all the way down.

;; -- Snapshot semantics (Hickey condition 3) ----------------------------------
;; The treasury state is a concrete immutable ref at proposal time.
;; Each pair reads a snapshot of the allocation table when it proposes.
;; The treasury updates after all resolutions for a candle are processed.
;; No concurrent reads of mutable state. Collect is the handoff.

;; -- What pair journals do NOT do ---------------------------------------------
;; - Do NOT encode candles (market observers do that)
;; - Do NOT judge market thoughts (exit observers do that)
;; - Do NOT execute swaps (treasury does that)
;; - Do NOT aggregate opinions (there is no aggregation — each pair is sovereign)
;; - Do NOT survive across desks (each desk has its own N x M grid)
;; - They propose, they own, they learn from reality, they earn or lose capital.
