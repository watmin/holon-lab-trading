;; thought-encoder.wat — ThoughtAST enum, ThoughtEncoder struct + encode
;; Depends on: vocabulary (conceptually)
;; The vocabulary produces ASTs. The ThoughtEncoder evaluates them.

(require primitives)

;; ── ThoughtAST — what the vocabulary speaks ────────────────────────
(enum thought-ast
  (Atom name)                           ; dictionary lookup
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees

;; ── ThoughtEncoder — evaluates ASTs into vectors ───────────────────
(struct thought-encoder
  [atoms : Map<String, Vector>]                    ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>])   ; optimistic, self-evicting

(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  ;; Pre-compute all atom vectors from a known vocabulary
  (let ((atom-names '("rsi" "williams-r" "cci-magnitude" "cci-direction" "cci"
                      "mfi" "roc-1" "roc-3" "roc-6" "roc-12"
                      "obv-slope" "volume-accel" "vwap-distance"
                      "hurst" "autocorrelation" "adx"
                      "kama-er" "choppiness" "dfa-alpha" "variance-ratio"
                      "entropy-rate" "aroon-up" "aroon-down" "fractal-dim"
                      "rsi-divergence-bull" "rsi-divergence-bear"
                      "cloud-position" "cloud-thickness" "tk-cross-delta" "tk-spread"
                      "stoch-k" "stoch-d" "stoch-kd-spread" "stoch-cross-delta"
                      "range-pos-12" "range-pos-24" "range-pos-48"
                      "fib-distance-12" "fib-distance-24" "fib-distance-48"
                      "kelt-pos" "bb-pos" "squeeze" "bb-breakout-upper" "bb-breakout-lower"
                      "bb-width"
                      "close-sma20" "close-sma50" "close-sma200"
                      "sma20-sma50" "sma50-sma200"
                      "macd" "macd-signal" "macd-hist"
                      "di-spread"
                      "range-ratio" "gap" "consecutive-up" "consecutive-down"
                      "tf-1h-ret" "tf-1h-body" "tf-1h-range-pos"
                      "tf-4h-ret" "tf-4h-body" "tf-4h-range-pos"
                      "tf-agreement"
                      "minute" "hour" "day-of-week" "day-of-month" "month-of-year"
                      ;; Exit vocab atoms
                      "atr-ratio" "atr-roc-6" "atr-roc-12"
                      "trend-consistency-6" "trend-consistency-12" "trend-consistency-24"
                      "divergence"
                      "close-delta" "rsi-delta"
                      "macd-hist-change" "now" "3-ago"
                      ;; Edge atom
                      "market-edge"))
        (atoms-map (fold (lambda (m name)
                     (assoc m name (get-vector vm name)))
                   (map-of) atom-names)))
    (thought-encoder atoms-map (map-of))))

;; ── lookup-atom — dictionary lookup (always succeeds) ──────────────
(define (lookup-atom [atoms : Map<String, Vector>] [name : String])
  : Vector
  (get atoms name))

;; ── encode — recursive AST evaluation with caching ─────────────────
;; Returns (Vector, Vec<(ThoughtAST, Vector)>) — the result and cache misses.
;; The encode function NEVER writes to the cache. Values up.
(define (encode [encoder : ThoughtEncoder] [ast : ThoughtAST])
  : (Vector Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    ;; Check cache first
    (let ((cache-hit (get (:compositions encoder) ast)))
      (if (not (= cache-hit None))
        (list cache-hit no-misses)
        ;; Cache miss — compute
        (let (((result misses)
                (match ast
                  ((Atom name)
                    (list (lookup-atom (:atoms encoder) name) '()))

                  ((Linear name value scale)
                    (let (((atom-vec atom-misses) (encode encoder (Atom name))))
                      (list (bind atom-vec (encode-linear value scale))
                            atom-misses)))

                  ((Log name value)
                    (let (((atom-vec atom-misses) (encode encoder (Atom name))))
                      (list (bind atom-vec (encode-log value))
                            atom-misses)))

                  ((Circular name value period)
                    (let (((atom-vec atom-misses) (encode encoder (Atom name))))
                      (list (bind atom-vec (encode-circular value period))
                            atom-misses)))

                  ((Bind left right)
                    (let (((l-vec l-misses) (encode encoder left))
                          ((r-vec r-misses) (encode encoder right)))
                      (list (bind l-vec r-vec)
                            (append l-misses r-misses))))

                  ((Bundle children)
                    (let ((pairs (map (lambda (c) (encode encoder c)) children)))
                      (list (apply bundle (map first pairs))
                            (apply append (map second pairs))))))))

          (list result (cons (list ast result) misses)))))))
