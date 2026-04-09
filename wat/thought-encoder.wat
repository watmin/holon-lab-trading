;; thought-encoder.wat — ThoughtAST enum, ThoughtEncoder struct + encode
;; Depends on: vocabulary (conceptually), primitives

(require primitives)

;; The AST — what the vocabulary speaks. Data, not execution.
(enum thought-ast
  (Atom name)                           ; dictionary lookup
  (Linear name value scale)             ; bind(atom, encode-linear)
  (Log name value)                      ; bind(atom, encode-log)
  (Circular name value period)          ; bind(atom, encode-circular)
  (Bind left right)                     ; composition of two sub-trees
  (Bundle children))                    ; superposition of sub-trees

;; The ThoughtEncoder — evaluates ASTs into vectors with caching.
;; atoms: finite, pre-computed, permanent.
;; compositions: optimistic LRU cache, self-evicting.
(struct thought-encoder
  [atoms : Map<String, Vector>]
  [compositions : LruCache<ThoughtAST, Vector>])

(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  ;; Pre-compute all known atom vectors from the VectorManager
  (thought-encoder (map-of) (map-of)))

;; Look up an atom vector from the dictionary.
(define (lookup-atom [atoms : Map<String, Vector>] [name : String])
  : Vector
  (match (get atoms name)
    ((Some v) v)
    (None (atom name))))  ; fallback to primitive atom generation

;; Encode a ThoughtAST into a Vector.
;; Returns (Vector, Vec<(ThoughtAST, Vector)>) — the vector and cache misses.
;; On cache hit: return the vector and empty misses.
;; On cache miss: compute the vector, return it AND the (ast, vector) in misses.
;; The encode function NEVER writes to the cache. Values up.
(define (encode [encoder : ThoughtEncoder] [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    ;; Check composition cache first
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

          ;; Record this computation as a miss for the cache
          (list result (cons (list ast result) misses)))))))
