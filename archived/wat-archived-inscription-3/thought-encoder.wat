;; thought-encoder.wat — ThoughtEncoder struct + encode
;;
;; Depends on: enums (ThoughtAST)
;;
;; The vocabulary produces ThoughtASTs — data, not execution.
;; The ThoughtEncoder evaluates them — HOW to think efficiently.
;; It walks the AST bottom-up, checking its memory at every node.
;; The minimum computation happens.
;;
;; Two kinds of memory:
;;   Atoms: a dictionary. Finite. Pre-computed. Never evicted.
;;   Compositions: a cache. Optimistic. Self-evicting.
;;
;; encode returns (list vector misses) — uses `get` not `lookup`,
;; `when-let` for cache hit with `no-misses` and `cache-hit` names.

(require primitives)
(require enums)    ; ThoughtAST

;; ── ThoughtEncoder — evaluates ASTs into vectors ────────────────────

(struct thought-encoder
  [atoms : Map<String, Vector>]                   ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>])  ; optimistic, self-evicting

;; Constructor: takes a VectorManager, pre-populates atom dictionary.
(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  (make-thought-encoder
    (map-of)  ; atoms — populated by pre-warming
    (make-lru-cache)))

;; ── encode — the one function ───────────────────────────────────────
;;
;; Recursive. Cache at every node. The cache key IS the AST node —
;; its structure is its identity. Same structure, same vector.
;;
;; Returns: (list vector misses) where misses is Vec<(ThoughtAST, Vector)>.
;; On cache hit: return the vector and empty misses.
;; On cache miss: compute, return it AND the (ast, vector) pair in misses.
;; The encode function NEVER writes to the cache. Values up, not queues down.

(define (encode [encoder : ThoughtEncoder]
                [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((no-misses '()))
    (when-let ((cache-hit (get (:compositions encoder) ast)))
      (list cache-hit no-misses))

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

      (list result (cons (list ast result) misses)))))
