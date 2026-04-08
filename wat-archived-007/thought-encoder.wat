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

(require primitives)
(require enums)    ; ThoughtAST

;; ── ThoughtEncoder — evaluates ASTs into vectors ────────────────────

(struct thought-encoder
  [atoms : Map<String, Vector>]                   ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>])  ; optimistic, self-evicting

;; Constructor: takes a VectorManager, pre-populates atom dictionary.
(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  ;; Atoms are pre-allocated from the VectorManager.
  ;; The set is closed — every atom name used by the vocabulary
  ;; is known at startup.
  (make-thought-encoder
    (map-of)  ; atoms — populated by pre-warming
    (make-lru-cache)))

;; ── encode — the one function ───────────────────────────────────────
;;
;; Recursive. Cache at every node. The cache key IS the AST node —
;; its structure is its identity. Same structure, same vector.

(define (encode [encoder : ThoughtEncoder]
                [ast : ThoughtAST]
                [miss-queue : Vec<(ThoughtAST, Vector)>])
  : Vector
  ;; On cache hit: return immediately. On miss: compute, queue, return.
  ;; The encode function NEVER writes to the cache. The parallel phase
  ;; queues misses. The enterprise drains between steps.
  (or (lookup (:compositions encoder) ast)        ; cache hit → done
      (let ((result
              (match ast
                ((Atom name)
                  (lookup-atom (:atoms encoder) name))

                ((Linear name value scale)
                  (bind (encode encoder (Atom name) miss-queue)
                        (encode-linear value scale)))

                ((Log name value)
                  (bind (encode encoder (Atom name) miss-queue)
                        (encode-log value)))

                ((Circular name value period)
                  (bind (encode encoder (Atom name) miss-queue)
                        (encode-circular value period)))

                ((Bind left right)
                  (bind (encode encoder left miss-queue)
                        (encode encoder right miss-queue)))

                ((Bundle children)
                  (apply bundle
                    (map (lambda (c) (encode encoder c miss-queue)) children))))))

        (push! miss-queue (list ast result))      ; queue the miss
        result)))

;; ── lookup-atom — dictionary access ─────────────────────────────────
;;
;; The atom dictionary is pre-populated. Missing atoms are an error
;; in the vocabulary — the set is closed.

(define (lookup-atom [atoms : Map<String, Vector>]
                     [name : String])
  : Vector
  (get atoms name))
