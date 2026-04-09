;; thought-encoder.wat — ThoughtAST enum, ThoughtEncoder struct + encode
;; Depends on: vocabulary (conceptually — evaluates the ASTs they produce)

(require primitives)

;; ── ThoughtAST — what the vocabulary speaks ───────────────────────────
;; A deferred fact. Data, not execution. The vocabulary produces trees of
;; this. Cheap — no vectors, no computation. The ThoughtEncoder evaluates them.
(enum thought-ast
  (Atom name)                           ; dictionary lookup
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees

;; ── ThoughtEncoder — evaluates ASTs into vectors ──────────────────────
;; Atoms: a dictionary. Finite. Known at startup. Pre-computed.
;; Compositions: a cache. Infinite. Optimistic. Self-evicting.
(struct thought-encoder
  [atoms : Map<String, Vector>]
  [compositions : LruCache<ThoughtAST, Vector>])

(define (make-thought-encoder [vector-manager : VectorManager])
  : ThoughtEncoder
  ;; Pre-compute atom vectors for all known names.
  ;; The VectorManager deterministically maps names to vectors.
  (thought-encoder
    (map-of)   ; atoms populated lazily or at startup from vocabulary names
    (map-of))) ; LRU cache for compositions

;; ── lookup-atom — dictionary lookup, always succeeds ──────────────────
(define (lookup-atom [atoms : Map<String, Vector>]
                     [name : String])
  : Vector
  (match (get atoms name)
    ((Some vec) vec)
    (None (atom name)))) ; fallback to runtime atom generation

;; ── encode — recursive AST evaluation with caching ────────────────────
;; On cache hit: return the vector and an empty misses list.
;; On cache miss: compute the vector, return it AND the (ast, vector)
;; pair in the misses list. The caller collects all misses. The enterprise
;; inserts them after all steps complete.
;; The encode function NEVER writes to the cache. Values up, not queues down.
(define (encode [encoder : ThoughtEncoder]
                [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    ;; Cache check
    (match (get (:compositions encoder) ast)
      ((Some cached)
        (list cached no-misses))
      (None
        ;; Compute
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

          ;; Return result + record the miss
          (list result (cons (list ast result) misses)))))))
