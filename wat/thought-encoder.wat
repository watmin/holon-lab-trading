;; ── thought-encoder.wat ──────────────────────────────────────────
;;
;; The vocabulary produces ASTs — WHAT to think. The ThoughtEncoder
;; evaluates them — HOW to think efficiently. Walks the AST bottom-up,
;; checking its memory at every node. Minimum computation.
;;
;; Two kinds of memory:
;;   Atoms: a dictionary. Finite. Known at startup. Pre-computed. Never evicted.
;;   Compositions: a cache. Optimistic. Use if we have it. Compute if we don't.
;;     Evict when memory says so.
;;
;; The encode function NEVER writes to the cache. Misses are returned as
;; values — the enterprise collects them and inserts between candles.
;; Values up, not queues down.
;;
;; Depends on: VectorManager (from holon-rs).

(require primitives)

;; ── AST — the language the vocabulary speaks ────────────────────

(enum thought-ast
  (Atom name)                           ; dictionary lookup — always succeeds
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees

;; ── ThoughtEncoder struct ───────────────────────────────────────

(struct thought-encoder
  [atoms : Map<String, Vector>]                  ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>]) ; optimistic, self-evicting

;; ── Constructor ─────────────────────────────────────────────────

(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  (make-thought-encoder
    (map-of)           ; atoms — populated at startup by registering all atom names
    (lru-cache 4096))) ; compositions — capacity chosen for one candle's working set

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
