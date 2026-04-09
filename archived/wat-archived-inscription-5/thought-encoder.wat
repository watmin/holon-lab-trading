;; thought-encoder.wat — ThoughtAST enum, ThoughtEncoder struct + encode
;; Depends on: vocabulary (conceptually), primitives
;; The vocabulary produces ASTs. The ThoughtEncoder evaluates them.

(require primitives)

;; ── ThoughtAST — what the vocabulary speaks ────────────────────────
;; Cheap data. No vectors. No 10,000-dim computation.
;; The calls to bind and encode are deferred.
(enum thought-ast
  (Atom name)                           ; dictionary lookup
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees

;; ── ThoughtEncoder ─────────────────────────────────────────────────
;; Two kinds of memory:
;; Atoms: a dictionary. Finite. Known at startup. Pre-computed. Never evicted.
;; Compositions: a cache. Infinite. Optimistic. Self-evicting.
(struct thought-encoder
  [atoms : Map<String, Vector>]          ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>]) ; optimistic, self-evicting

(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  (thought-encoder
    (map-of)    ; atoms populated on first access
    (map-of)))  ; compositions start empty

;; Look up an atom vector. Deterministic — same name, same vector.
(define (lookup-atom [atoms : Map<String, Vector>] [name : String])
  : Vector
  (get atoms name (atom name)))  ; fallback to generating from the name

;; ── encode — the recursive evaluator ──────────────────────────────
;; On cache hit: return the vector and an empty misses list.
;; On cache miss: compute the vector, return it AND the (ast, vector)
;; pair in the misses list. The encode function NEVER writes to the cache.
;; Values up, not queues down.
(define (encode [encoder : ThoughtEncoder] [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    ;; Check composition cache first
    (when-let ((cache-hit (get (:compositions encoder) ast)))
      (list cache-hit no-misses))

    ;; Cache miss — compute and record
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

      ;; Return result + record this node as a miss
      (list result (cons (list ast result) misses)))))
