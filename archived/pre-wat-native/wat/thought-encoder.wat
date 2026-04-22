;; ── thought-encoder.wat ──────────────────────────────────────────
;;
;; The vocabulary produces ASTs — WHAT to think. The ThoughtEncoder
;; evaluates them — HOW to think efficiently. Walks the AST bottom-up,
;; checking its memory at every node. Minimum computation.
;;
;; Two kinds of memory:
;;   Atoms: a dictionary. Finite. Known at startup. Pre-computed. Never evicted.
;;   Compositions: a cache. Optimistic. Use if we have it. Compute if we don't.
;;
;; The encode function NEVER writes to the cache. Misses are returned as
;; values — the enterprise collects them and inserts between candles.
;; Values up, not queues down.
;;
;; Depends on: VectorManager, ScalarEncoder (from holon-rs).

(require primitives)

;; ── AST — the language the vocabulary speaks ────────────────────

(enum thought-ast
  (Atom name)                           ; dictionary lookup — always succeeds
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees

;; ── round-to — cache key quantization ───────────────────────────
;; Used by vocabulary modules at emission time — the ThoughtAST
;; carries the rounded value. The cache key IS the exact AST.
;; The rounding happens at emission, not evaluation.

(define (round-to [v : f64] [digits : u32])
  : f64
  (let ((factor (expt 10 digits)))
    (/ (round (* v factor)) factor)))

;; ── ThoughtEncoder struct ───────────────────────────────────────

(struct thought-encoder
  [atoms : Map<String, Vector>]                  ; finite, pre-computed, permanent
  [compositions : Map<ThoughtAST, Vector>]       ; optimistic cache (LRU moved to EncoderService)
  [scalar-encoder : ScalarEncoder]               ; encodes Linear/Log/Circular nodes
  [vm : VectorManager])                          ; atom allocation, deterministic

;; ── Constructor ─────────────────────────────────────────────────

(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  (let ((dims (dimensions vm)))
    (make-thought-encoder
      (map-of)                          ; atoms — populated at startup via register-atom
      (map-with-capacity 4096)          ; compositions — one candle's working set
      (make-scalar-encoder dims)        ; scalar encoder
      vm)))                             ; vector manager

;; ── Encode — recursive, cache at every node ─────────────────────
;; Returns (Vector, Vec<(ThoughtAST, Vector)>).
;; On cache hit: return the vector and empty misses.
;; On cache miss: compute, return vector AND the (ast, vector) pair
;; in the misses list. The caller collects all misses.

(define (encode [encoder : ThoughtEncoder] [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    ;; Check the composition cache first
    (when-let ((cache-hit (get (:compositions encoder) ast)))
      (list cache-hit no-misses))

    ;; Cache miss — evaluate the AST node
    (let (((result misses)
            (match ast
              ((Atom name)
                (list (get (:atoms encoder) name) '()))

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

      ;; Return result AND record this miss for later insertion
      (list result (cons (list ast result) misses)))))

;; ── IncrementalBundle ───────────────────────────────────────────
;; Maintains running sums across candles. Optimization, not cognition.
;; Can be reconstructed from one full encode.
;;
;; The algebra: bundle = threshold(Σ vectors). If fact k changes from
;; old to new, sums_new = sums - old + new. threshold(sums_new) ==
;; bundle(all current facts). Proven bit-identical. Integer addition
;; is commutative and associative.
;;
;; Invariant: round-to at vocab emission is load-bearing for the AST diff.
;; Quantized floats compare reliably. Remove round-to and this degrades
;; to full recompute (correct, but no savings).

(struct incremental-bundle
  [sums : Vec<i32>]                     ; running element-wise sums. threshold(sums) == bundle(all facts)
  [last-facts : Map<ThoughtAST, Vector>] ; previous candle's facts: AST → its evaluated vector
  [dims : usize]                        ; dimensions
  [initialized : bool])                 ; whether we've done at least one full encode

(define (make-incremental-bundle [dims : usize])
  : IncrementalBundle
  (make-incremental-bundle
    (vec-of 0i32 dims)                  ; sums — zeroed
    (map-of)                            ; last-facts — empty
    dims
    false))

;; Encode facts incrementally. Returns (thought-vector, cache-misses).
;;
;; First candle: full encode, populate sums and last-facts.
;; Subsequent candles: diff against last-facts, patch sums, threshold.
;;
;; Uses the ThoughtEncoder to evaluate individual changed facts (benefiting
;; from the composition cache). The sums buffer avoids re-summing unchanged facts.

(define (incremental-encode [ib : IncrementalBundle]
                            [new-facts : Vec<ThoughtAST>]
                            [encoder : ThoughtEncoder])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (if (not (:initialized ib))
    ;; First candle — full encode from scratch
    (full-encode ib new-facts encoder)

    ;; Subsequent candles — diff and patch
    (let ((new-set (set-of new-facts))
          (all-misses '())
          (new-last-facts (map-with-capacity (length new-facts))))

      ;; REMOVED: in last-facts but not in new-facts — subtract from sums
      (for-each ((old-ast old-vec) (:last-facts ib))
        (when (not (contains? new-set old-ast))
          (subtract-from-sums! (:sums ib) old-vec)))

      ;; For each new fact: check if it existed last candle
      (for-each (fact new-facts)
        (if-let ((old-vec (get (:last-facts ib) fact)))
          ;; UNCHANGED — zero work. sums already has this contribution.
          (insert! new-last-facts fact old-vec)
          ;; CHANGED or ADDED — encode, add to sums
          (let (((new-vec misses) (encode encoder fact)))
            (extend! all-misses misses)
            (add-to-sums! (:sums ib) new-vec)
            (insert! new-last-facts fact new-vec))))

      (set! (:last-facts ib) new-last-facts)
      (list (threshold (:sums ib) (:dims ib)) all-misses))))

;; First candle: full encode from scratch.
(define (full-encode [ib : IncrementalBundle]
                     [facts : Vec<ThoughtAST>]
                     [encoder : ThoughtEncoder])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (zero! (:sums ib))
  (clear! (:last-facts ib))
  (let ((all-misses '()))
    (for-each (fact facts)
      (let (((vec misses) (encode encoder fact)))
        (extend! all-misses misses)
        (add-to-sums! (:sums ib) vec)
        (insert! (:last-facts ib) fact vec)))
    (set! (:initialized ib) true)
    (list (threshold (:sums ib) (:dims ib)) all-misses)))

;; Apply sign threshold to sums, producing the bundled vector.
(define (threshold [sums : Vec<i32>] [dims : usize])
  : Vector
  (let ((out (zeros dims)))
    (for-each (i (range dims))
      (set! (ref out i)
        (cond ((> (ref sums i) 0)  1)
              ((< (ref sums i) 0) -1)
              (else                 0))))
    out))
