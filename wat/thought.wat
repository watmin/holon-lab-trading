;; -- thought.wat -- Layer 0: candle -> thoughts via vocabulary ---------------
;;
;; The thought layer transforms raw candle data into hyperdimensional vectors.
;; ThoughtVocab holds pre-allocated atoms. ThoughtEncoder weaves facts into
;; geometry. encode-thought dispatches by lens.
;;
;; Modules return Fact data. The encoder weaves to geometry. No wrappers.

(require core/primitives)
(require core/structural)
(require vocab)
(require facts)

;; -- Atom groups ------------------------------------------------------------
;;
;; The atoms are defined by the vocab leaves. Each leaf declares what it uses:
;;   stochastic.wat → stoch-k, stoch-d, stoch-overbought, stoch-oversold
;;   regime.wat     → kama-er, efficient-trend, chop, dfa-alpha, ...
;;   flow.wat       → vwap, mfi, buy-pressure, volume-spike, ...
;;   (and so on for all 12 leaves)
;;
;; Six groups emerge from the leaves:
;;   indicator-atoms   — the names vocab modules read from candles
;;   direction-atoms   — up, down, flat
;;   zone-atoms        — the zone names vocab modules emit
;;   predicate-atoms   — above, below, crosses-above, touches, bounces-off
;;   segment-atoms     — beginning, ending
;;   calendar-atoms    — hour-of-day, day-of-week, session names
;;
;; In wat, (atom name) is deterministic — same name, same vector.
;; The Rust pre-allocates these into a VectorManager for O(1) lookup.
;; The leaves ARE the specification. The groups are derived, not declared.

;; -- ThoughtVocab -----------------------------------------------------------

(struct thought-vocab
  atoms                  ; (map string Vector) — name -> pre-allocated atom vector
  dims)                  ; usize

;; get-vector: deterministic atom allocation. Same name → same vector.
;; In wat, this IS (atom name). The VectorManager is the Rust cache
;; that makes atom allocation O(1) after the first call.
(define (get-vector vm name) (atom name))
(define (dimensions vm) (:dims vm))

(define (new-thought-vocab vm)
  "Pre-allocate all atom vectors from the VectorManager."
  ;; all-atom-groups: derived from the vocab leaves + segment/calendar atoms.
  ;; The Rust enumerates them for pre-allocation. The wat derives them from the leaves.
  (thought-vocab
    :atoms (fold (lambda (m group)
                   (fold (lambda (m name) (assoc m name (get-vector vm name)))
                         m group))
                 {} all-atom-groups)
    :dims (dimensions vm)))

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

;; ── Fact generation tables ─────────────────────────────────────────
;; These tables are the source of truth. Scry verifies Rust matches.
;; The cross-product of tables × predicates produces ~235 cached facts.

(define COMPARISON_PAIRS
  '(;; Original 9
    ("close" "sma20") ("close" "sma50") ("close" "sma200")
    ("close" "bb-upper") ("close" "bb-lower")
    ("sma20" "sma50") ("sma50" "sma200")
    ("macd-line" "macd-signal") ("dmi-plus" "dmi-minus")
    ;; Cross-candle (5)
    ("high" "prev-high") ("low" "prev-low")
    ("open" "prev-close") ("close" "prev-close") ("close" "prev-open")
    ;; OHLC vs structure (7)
    ("open" "sma20") ("open" "sma50") ("open" "sma200")
    ("open" "bb-upper") ("open" "bb-lower")
    ("high" "bb-upper") ("low" "bb-lower")
    ;; Intra-candle (5)
    ("close" "open")
    ("upper-wick" "candle-body") ("lower-wick" "candle-body")
    ("upper-wick" "lower-wick") ("candle-range" "atr")
    ;; Additional structure (3)
    ("candle-body" "candle-range") ("high" "sma200") ("low" "sma200")
    ;; Ichimoku (7)
    ("close" "tenkan-sen") ("close" "kijun-sen")
    ("close" "cloud-top") ("close" "cloud-bottom")
    ("tenkan-sen" "kijun-sen")
    ("close" "senkou-span-a") ("close" "senkou-span-b")
    ;; Stochastic (1)
    ("stoch-k" "stoch-d")
    ;; Keltner (3)
    ("close" "keltner-upper") ("close" "keltner-lower")
    ("bb-upper" "keltner-upper")))

(define COMPARISON_PREDICATES
  '("above" "below" "crosses-above" "crosses-below" "touches" "bounces-off"))

(define ZONE_CHECKS
  '(("rsi" "overbought") ("rsi" "oversold")
    ("rsi" "above-midline") ("rsi" "below-midline")
    ("adx" "strong-trend") ("adx" "weak-trend")
    ("dmi-plus" "strong-trend") ("dmi-plus" "weak-trend")
    ("dmi-minus" "strong-trend") ("dmi-minus" "weak-trend")
    ("macd-line" "positive") ("macd-line" "negative")
    ("macd-hist" "positive") ("macd-hist" "negative")))

(define FIBONACCI_LEVELS '("fib-236" "fib-382" "fib-500" "fib-618" "fib-786"))
(define FIBONACCI_PREDICATES '("above" "below" "touches"))

(define RSI_SMA_PREDICATES '("above" "below" "crosses-above" "crosses-below"))

(define SESSIONS '("asian-session" "european-session" "us-session" "off-hours"))

;; ── Fact cache construction ───────────────────────────────────────

(define (build-fact-cache vocab)
  "Pre-compute all static facts as vectors. Returns a map of label → Vector.
   Derived from the tables above — cross-products, not enumeration."
  (let ((cache {}))
    ;; 1. COMPARISON_PAIRS × PREDICATES → ~198 facts
    (for-each (lambda ((a b))
      (for-each (lambda (pred)
        (set! cache (assoc cache (format "({} {} {})" pred a b)
                          (bind-triple vocab pred a b))))
        COMPARISON_PREDICATES))
      COMPARISON_PAIRS)
    ;; 2. ZONE_CHECKS → 14 facts (at ind zone)
    (for-each (lambda ((ind zone))
      (set! cache (assoc cache (format "(at {} {})" ind zone)
                        (bind-triple vocab "at" ind zone))))
      ZONE_CHECKS)
    ;; 3. FIBONACCI_LEVELS × FIBONACCI_PREDICATES → 15 facts
    (for-each (lambda (fib)
      (for-each (lambda (pred)
        (set! cache (assoc cache (format "({} close {})" pred fib)
                          (bind-triple vocab pred "close" fib))))
        FIBONACCI_PREDICATES))
      FIBONACCI_LEVELS)
    ;; 4. RSI vs SMA → 4 facts
    (for-each (lambda (pred)
      (set! cache (assoc cache (format "({} rsi rsi-sma)" pred)
                        (bind-triple vocab pred "rsi" "rsi-sma"))))
      RSI_SMA_PREDICATES)
    ;; 5. SESSIONS → 4 facts
    (for-each (lambda (session)
      (set! cache (assoc cache (format "(at-session {})" session)
                        (bind-triple vocab "at-session" session session))))
      SESSIONS)
    cache))

(define (new-thought-encoder vocab)
  "Pre-compute the fact cache."
  ;; scalar-enc: Rust infrastructure — ScalarEncoder holds dims so that
  ;; encode-linear/encode-log work. In wat, these are stdlib primitives
  ;; that don't need a carrier struct. The field exists for Rust, not wat.
  (thought-encoder :vocab vocab
                   :scalar-enc (scalar-encoder (:dims vocab))
                   :fact-cache (build-fact-cache vocab)))

(define (fact-codebook encoder)
  "Return (labels, vectors) pairs for all cached facts.
   Consumed by Observer to build the discriminant that decodes thoughts."
  (unzip (:fact-cache encoder)))

;; -- Fact weaveing pipeline ------------------------------------------------

;; The ONE method that turns any vocab module's output into geometry.
;; Modules return Fact data. This weaves it.

;; Fact variants:
;;   Zone        { indicator, zone }       -> lookup (at indicator zone) in cache
;;   Comparison  { predicate, a, b }       -> lookup (pred a b) in cache
;;   Scalar      { indicator, value, scale } -> bind(atom(indicator), encode-linear(value, scale))
;;   Bare        { label }                 -> lookup in cache, or raw atom

(define (cache-get encoder label)
  "Look up a pre-computed fact vector by label string. Returns vector or absent."
  (get (:fact-cache encoder) label))

(define (encode-facts encoder module-facts facts owned-facts labels)
  "Weave vocab module facts into vectors. Pushes to facts, owned-facts, and labels."
  (let ((vocab (:vocab encoder)))
    (for-each (lambda (fact)
      (match fact
        (zone ind z)
          (let ((key (format "(at ~a ~a)" ind z)))
            (push! facts (cache-get encoder key))
            (push! labels key))
        (comparison p a b)
          (let ((key (format "(~a ~a ~a)" p a b)))
            (push! facts (cache-get encoder key))
            (push! labels key))
        (scalar ind v s)
          (begin
            (push! owned-facts (bind (vocab-get vocab ind) (encode-linear v s)))
            (push! labels (format "(~a ~a)" ind v)))
        (bare label)
          (begin
            (push! facts (or (cache-get encoder label) (vocab-get vocab label)))
            (push! labels label))))
      module-facts)))

;; -- Fact composition helpers -----------------------------------------------

;; Triple binding: the shape of relational facts.
;; bind(pred, bind(a, b)) — "pred relates a to b"
;; This is the vector-level equivalent of fact/comparison.
;; fact/comparison builds from names (calls atom).
;; bind-triple builds from pre-allocated vectors (calls vocab-get).
(define (bind-triple vocab pred a b)
  (bind (vocab-get vocab pred) (bind (vocab-get vocab a) (vocab-get vocab b))))

;; Temporal binding: (since fact N) -> bind(fact_vec, position_vector(N))
(define (get-position-vector vm n)
  "Get a deterministic position vector for index N. Used for temporal binding.
   Position vectors are orthogonal markers for 'how long ago' in the sequence."
  (get-vector vm (format "pos-~a" n)))

(define (fact-since vm fact n)
  (bind fact (get-position-vector vm n)))

;; -- encode_view dispatch ---------------------------------------------------

;; The main entry point. Selects which eval methods to run based on lens.
;; :generalist = all methods. Named lenses select subsets.
;; lens is an enum (see market/observer.wat) — the compiler guards renames.

(define (encode-thought encoder candles vm lens)
  "Encode a window of candles through a vocabulary lens.
   Each lens selects which eval functions to run.
   Eval methods are independent — pmap within each lens group.
   Vocab modules return Fact data → encode-facts weaves to geometry."
  (let ((is    (lambda (lenses) (or (= lens :generalist) (member? lens lenses))))
        (now   (last candles))
        (prev  (when (>= (len candles) 2) (nth candles (- (len candles) 2)))))

    ;; Each eval method returns (cached-facts, owned-facts) independently.
    ;; pmap within each lens group — eval methods read the same immutable
    ;; candle slice and produce disjoint fact vectors. No shared mutation.
    (let ((results
      (flatten (filter some? (list
        ;; SHARED: comparisons (momentum + structure)
        (when (is '(:momentum :structure))
          (pmap (lambda (eval-fn) (eval-fn))
            (list (lambda () (eval-comparisons encoder now prev))
                  (lambda () (eval-rsi-sma encoder candles)))))

        ;; EXCLUSIVE: momentum
        (when (is '(:momentum))
          (pmap (lambda (eval-fn) (eval-fn))
            (list (lambda () (encode-facts encoder (eval-stochastic candles)))
                  (lambda () (encode-facts encoder (eval-momentum candles)))
                  (lambda () (eval-divergence encoder candles vm))
                  (lambda () (encode-facts encoder (eval-oscillators candles))))))

        ;; EXCLUSIVE: structure — PELT is the heavy computation
        (when (is '(:structure))
          (pmap (lambda (eval-fn) (eval-fn))
            (list (lambda () (eval-segment-narrative encoder candles vm))
                  (lambda () (eval-range-position encoder candles))
                  (lambda () (encode-facts encoder (eval-ichimoku candles)))
                  (lambda () (encode-facts encoder (eval-fibonacci candles)))
                  (lambda () (encode-facts encoder (eval-keltner candles)))
                  (lambda () (encode-facts encoder (eval-timeframe-structure candles))))))

        ;; EXCLUSIVE: volume
        (when (is '(:volume))
          (pmap (lambda (eval-fn) (eval-fn))
            (list (lambda () (eval-volume-confirmation encoder candles))
                  (lambda () (eval-volume-analysis encoder candles))
                  (lambda () (encode-facts encoder (eval-price-action candles)))
                  (lambda () (eval-flow-module encoder candles)))))

        ;; EXCLUSIVE: narrative
        (when (is '(:narrative))
          (pmap (lambda (eval-fn) (eval-fn))
            (list (lambda () (eval-temporal encoder candles vm))
                  (lambda () (eval-calendar encoder now))
                  (lambda () (encode-facts encoder (eval-timeframe-narrative candles))))))

        ;; EXCLUSIVE: regime
        (when (is '(:regime))
          (pmap (lambda (eval-fn) (eval-fn))
            (list (lambda () (encode-facts encoder (eval-regime candles)))
                  (lambda () (encode-facts encoder (eval-persistence candles)))))))))))

      ;; Merge all results and bundle into one thought vector
      (let ((all-facts (fold append '() (map first results))
             (all-owned (fold append '() (map second results)))))
        (let ((refs (append all-facts all-owned)))
          (thought-result
            :thought (if (empty? refs) (zeros (dimensions encoder)) (bundle refs))))))))

;; -- Inline evals (defined here, called from encode-thought) ---------------

;; rune:assay(prose) — eval-comparisons iterates 29 indicator pairs × 6
;; predicates. The pairs table IS the spec; the iteration is Rust.
(define (eval-comparisons encoder now prev facts labels)
  "Check 29 indicator pairs for above/below/crosses/touches/bounces.
   Uses cached fact vectors. Cross detection compares current vs previous candle.
   Touches: within 10% of ATR. Bounces: within 20% AND prev was farther."
  ;; rune:assay(prose) — the 29 pairs and 6 predicates are enumerated in Rust
  ;; as COMPARISON_PAIRS × PREDICATES. Each check is a cache lookup.
  None)

(define (eval-segment-narrative encoder candles vm owned labels)
  "PELT changepoint detection on 17 indicator streams.
   Each segment gets: direction, magnitude, duration, temporal position.
   Zone qualifiers (beginning/ending) at segment boundaries."
  (let ((n (len candles)))
    (when (>= n 5)
      (for-each (lambda (stream)
        (let ((values  (map (:extractor stream) candles))
              (cps     (pelt-changepoints values (bic-penalty values)))
              (bounds  (append [0] cps [(len values)])))
          (for-each (lambda (pos seg-idx)
            ;; Segment description: bind(indicator, bind(signed-magnitude, duration))
            ;; Temporal binding: bind(position-vector, chrono-anchor)
            ;; Final: bind(description, temporal)
            (let ((desc     (bind (atom (:name stream))
                                  (bind (encode-log (abs (:change seg-idx)))
                                        (encode-log (:duration seg-idx)))))
                  (temporal (bind (get-position-vector vm pos)
                                 (encode-log (:candles-ago seg-idx)))))
              (push! owned (bind desc temporal))
              (push! labels (format "(seg ~a ~a @~a)" (:name stream) pos))))
            (range 0 (- (len bounds) 1)))))
        segment-streams))))

(define (eval-temporal encoder candles vm owned labels)
  "Temporal lookback: detect crossovers in recent history, bind to time position.
   Looks back up to 12 candles. Uses PELT segments for structural distance."
  (when (>= (len candles) 3)
    (let ((seg-map (pelt-segment-map (map (lambda (c) (ln (:close c))) candles))))
      (for-each (lambda (back)
        (let ((idx      (- (len candles) 1 back))
              (c        (nth candles idx))
              (prev     (nth candles (- idx 1)))
              (seg-dist (max 1 (- (:current seg-map) (:segment-of seg-map idx)))))
          ;; Golden/death cross: SMA50 × SMA200
          (when (and (> (:sma50 prev) 0.0) (> (:sma200 prev) 0.0))
            (when (and (< (:sma50 prev) (:sma200 prev))
                       (>= (:sma50 c) (:sma200 c)))
              (push! owned (fact-since vm
                (bind-triple (:vocab encoder) "crosses-above" "sma50" "sma200")
                seg-dist))
              (push! labels (format "(since (crosses-above sma50 sma200) ~aseg)" seg-dist)))
            (when (and (> (:sma50 prev) (:sma200 prev))
                       (<= (:sma50 c) (:sma200 c)))
              (push! owned (fact-since vm
                (bind-triple (:vocab encoder) "crosses-below" "sma50" "sma200")
                seg-dist))
              (push! labels (format "(since (crosses-below sma50 sma200) ~aseg)" seg-dist))))
          ;; MACD cross: macd-line × macd-signal
          (when (and (!= (:macd-line prev) 0.0) (!= (:macd-line c) 0.0))
            (when (and (< (:macd-line prev) (:macd-signal prev))
                       (>= (:macd-line c) (:macd-signal c)))
              (push! owned (fact-since vm
                (bind-triple (:vocab encoder) "crosses-above" "macd-line" "macd-signal")
                seg-dist))
              (push! labels (format "(since (crosses-above macd-line macd-signal) ~aseg)" seg-dist)))
            (when (and (> (:macd-line prev) (:macd-signal prev))
                       (<= (:macd-line c) (:macd-signal c)))
              (push! owned (fact-since vm
                (bind-triple (:vocab encoder) "crosses-below" "macd-line" "macd-signal")
                seg-dist))
              (push! labels (format "(since (crosses-below macd-line macd-signal) ~aseg)" seg-dist))))))
        (range 1 (+ 1 (min 12 (- (len candles) 2))))))))

;; -- What the thought layer does NOT do -------------------------------------
;; - Does NOT learn (that's the Journal)
;; - Does NOT predict (that's the Observer's journal)
;; - Does NOT decide trades (that's downstream)
;; - Does NOT see other observers' thoughts (observers are independent)
;; - It encodes. It weaves. It bundles. That's all.
