;; -- thought.wat -- Layer 0: candle -> thoughts via vocabulary ---------------
;;
;; The thought layer transforms raw candle data into hyperdimensional vectors.
;; ThoughtVocab holds pre-allocated atoms. ThoughtEncoder renders facts into
;; geometry. encode_view dispatches by expert profile.
;;
;; Modules return Fact data. The encoder renders to geometry. No wrappers.

(require core/primitives)
(require core/structural)
(require vocab)
(require std/facts)

;; -- Atom groups ------------------------------------------------------------

;; Six atom groups, pre-allocated at startup:
;;   indicator-atoms   — close, sma20, rsi, atr, etc. (~90 atoms)
;;   direction-atoms   — up, down, flat
;;   zone-atoms        — overbought, oversold, squeeze, etc. (~100 atoms)
;;   predicate-atoms   — above, below, crosses-above, touches, etc.
;;   segment-atoms     — beginning, ending
;;   calendar-atoms    — hour-of-day, day-of-week, session names

;; -- ThoughtVocab -----------------------------------------------------------

(struct thought-vocab
  atoms                  ; (map string Vector) — name -> pre-allocated atom vector
  dims)                  ; usize

; rune:gaze(phantom) — get-vector is not in the wat language
; rune:gaze(phantom) — dimensions is not in the wat language
(define (new-thought-vocab vm)
  "Pre-allocate all atom vectors from the VectorManager."
  (thought-vocab
    :atoms (fold (lambda (m group)
                   (fold (lambda (m name) (assoc m name (get-vector vm name)))
                         m group))
                 {} all-atom-groups)
    :dims (dimensions vm)))

; rune:gaze(phantom) — vocab-get is not in the wat language
(define (vocab-get vocab name)
  "Look up an atom vector by name. Panics on unknown atom."
  (get (:atoms vocab) name))

;; -- ThoughtResult ----------------------------------------------------------

(struct thought-result
  thought                ; Vector — bundled thought vector
  fact-labels)           ; (list string) — human-readable labels for debugging

;; -- ThoughtEncoder ---------------------------------------------------------

(struct thought-encoder
  vocab                  ; ThoughtVocab
  scalar-enc             ; ScalarEncoder
  fact-cache)            ; (map string Vector) — pre-computed fact vectors

;; The fact cache pre-computes:
;;   - comparison facts: (pred a b) for all COMPARISON_PAIRS * 6 predicates
;;   - fibonacci facts: (pred close fib-level) for 5 levels * 3 predicates
;;   - zone facts: (at indicator zone) for all STREAM_ZONE_CHECKS
;;   - rsi-sma facts: (pred rsi rsi-sma) for 4 predicates
;;   - session facts: (at-session session) for 4 sessions

; rune:gaze(phantom) — new-scalar-encoder is not in the wat language
; rune:gaze(phantom) — build-fact-cache is not in the wat language
(define (new-thought-encoder vocab)
  "Pre-compute the fact cache."
  (thought-encoder :vocab vocab
                   :scalar-enc (new-scalar-encoder (dims vocab))
                   :fact-cache (build-fact-cache vocab)))

; rune:gaze(phantom) — unzip is not in the wat language
(define (fact-codebook encoder)
  "Return (labels, vectors) pairs for all cached facts. Used for discriminant decoding."
  (unzip (:fact-cache encoder)))

;; -- Fact rendering pipeline ------------------------------------------------

;; The ONE method that turns any vocab module's output into geometry.
;; Modules return Fact data. This renders it.

;; Fact variants:
;;   Zone        { indicator, zone }       -> lookup (at indicator zone) in cache
;;   Comparison  { predicate, a, b }       -> lookup (pred a b) in cache
;;   Scalar      { indicator, value, scale } -> bind(atom(indicator), encode-linear(value, scale))
;;   Bare        { label }                 -> lookup in cache, or raw atom

; rune:gaze(phantom) — cache-get is not in the wat language
(define (encode-facts encoder module-facts facts owned-facts labels)
  "Render vocab module facts into vectors."
  (for-each (lambda (fact)
    (match fact
      (zone ind z)       (push! facts (cache-get (format "(at ~a ~a)" ind z)))
      (comparison p a b) (push! facts (cache-get (format "(~a ~a ~a)" p a b)))
      (scalar ind v s)   (push! owned-facts (bind (vocab-get ind) (encode-linear v s)))
      (bare label)       (push! facts (or (cache-get label) (vocab-get label)))))
    module-facts))

;; -- Fact composition helpers -----------------------------------------------

;; Binary predicate: (pred a b) -> bind(V("pred"), bind(V("a"), V("b")))
(define (fact-binary vocab pred a b)
  (bind (vocab-get vocab pred) (bind (vocab-get vocab a) (vocab-get vocab b))))

;; Temporal binding: (since fact N) -> bind(fact_vec, position_vector(N))
; rune:gaze(phantom) — get-position-vector is not in the wat language
(define (fact-since vm fact n)
  (bind fact (get-position-vector vm n)))

;; -- encode_view dispatch ---------------------------------------------------

;; The main entry point. Selects which eval methods to run based on profile.
;; "full" = all methods (generalist). Named profiles select subsets.

(define (encode-view encoder candles vm expert)
  "Encode a window of candles through the expert's vocabulary lens."
  ; rune:gaze(phantom) — member? is not in the wat language
  (let ((is (lambda (profiles) (or (= expert "full") (member? expert profiles)))))

    ;; SHARED: comparisons (momentum + structure only)
    (when (is '("momentum" "structure"))
      (eval-comparisons ...))

    ;; EXCLUSIVE: momentum — oscillators, crosses, divergence
    (when (is '("momentum"))
      (eval-rsi-sma ...)
      (eval-stochastic ...)
      (eval-momentum ...)        ; CCI, ROC
      (eval-divergence ...)
      (eval-oscillators-module ...))  ; vocab/oscillators

    ;; EXCLUSIVE: structure — segments, levels, channels, cloud, fibs
    (when (is '("structure"))
      (eval-segment-narrative ...)
      (eval-range-position ...)
      (eval-ichimoku ...)
      (eval-fibonacci ...)
      (eval-keltner ...)
      (eval-timeframe-structure ...)) ; vocab/timeframe

    ;; EXCLUSIVE: volume — participation, flow
    (when (is '("volume"))
      (eval-volume-confirmation ...)
      (eval-volume-analysis ...)
      (eval-price-action ...)
      (eval-flow-module ...))         ; vocab/flow

    ;; EXCLUSIVE: narrative — calendar, temporal lookback
    (when (is '("narrative"))
      (eval-temporal ...)
      (eval-calendar ...)
      (eval-timeframe-narrative ...)) ; vocab/timeframe

    ;; EXCLUSIVE: regime — market character
    (when (is '("regime"))
      (eval-regime-module ...)
      (eval-persistence-module ...))  ; vocab/persistence

    ;; Bundle all facts into one thought vector
    (thought-result
      ; rune:gaze(phantom) — zeros is not in the wat language
      :thought (if (empty? all-facts) (zeros dims) (bundle all-facts))
      :fact-labels labels)))

;; -- Comparison predicates --------------------------------------------------

;; COMPARISON_PAIRS: 29 indicator pairs checked for above/below/crosses/touches/bounces.
;; Uses prev candle for cross detection.
;; Touches threshold: within 10% of ATR.
;; Bounces threshold: within 20% of ATR AND prev was farther.

;; -- Segment narrative (PELT) -----------------------------------------------

;; 17 streams segmented via PELT changepoint detection.
;; Segments have direction (up/down) and temporal binding (since N).
;; Beginning/ending zone qualifiers at segment boundaries.

;; -- What the thought layer does NOT do -------------------------------------
;; - Does NOT learn (that's the Journal)
;; - Does NOT predict (that's the Observer's journal)
;; - Does NOT decide trades (that's downstream)
;; - Does NOT see other experts' thoughts (experts are independent)
;; - It encodes. It renders. It bundles. That's all.
