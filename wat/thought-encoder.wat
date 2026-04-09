;; thought-encoder.wat — ThoughtAST enum, ThoughtEncoder struct + encode
;; Depends on: vocabulary (conceptually), primitives

(require primitives)

;; ── ThoughtAST — the deferred fact ─────────────────────────────────
;; The vocabulary produces trees of this. Cheap. No vectors.
;; The ThoughtEncoder evaluates them.

(enum thought-ast
  (Atom name)                            ; dictionary lookup
  (Linear name value scale)              ; bind(atom, encode-linear)
  (Log name value)                       ; bind(atom, encode-log)
  (Circular name value period)           ; bind(atom, encode-circular)
  (Bind left right)                      ; composition of two sub-trees
  (Bundle children))                     ; superposition of sub-trees

;; ── ThoughtEncoder ─────────────────────────────────────────────────
;; Two kinds of memory: atoms (finite, permanent) and compositions
;; (optimistic cache, self-evicting).

(struct thought-encoder
  [atoms : Map<String, Vector>]
  [compositions : LruCache<ThoughtAST, Vector>])

(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  (thought-encoder (map-of) (map-of)))

;; ── encode — recursive AST evaluation with caching ─────────────────
;; On cache hit: return the vector and an empty misses list.
;; On cache miss: compute the vector, return it AND the (ast, vector)
;; pair in the misses list. The caller collects all misses.
;; The encode function NEVER writes to the cache. Values up.

(define (encode [encoder : ThoughtEncoder] [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    ;; Check composition cache first
    (when-let ((cache-hit (get (:compositions encoder) ast)))
      (list cache-hit no-misses))

    ;; Cache miss — compute
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

      ;; Return result + this node as a miss (for cache insertion later)
      (list result (cons (list ast result) misses)))))
