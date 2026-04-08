;; thought-encoder.wat — ThoughtAST enum, ThoughtEncoder struct + encode
;;
;; Depends on: vocabulary (all vocab modules produce ThoughtAST)
;;
;; The vocabulary produces ASTs — the specification of WHAT to think.
;; The ThoughtEncoder evaluates them — HOW to think efficiently.
;; It walks the AST bottom-up, checking its memory at every node.
;; The minimum computation happens.
;;
;; Two kinds of memory:
;;   Atoms: a dictionary. Finite. Pre-computed. Never evicted.
;;   Compositions: a cache. Optimistic. Self-evicting.

(require primitives)

;; ── ThoughtAST — the vocabulary's language ──────────────────────────
;;
;; Data describing a composition — not vectors, not execution.
;; The vocabulary produces trees of this. Cheap. No 10,000-dim
;; computation. Just "here is what I want to say."

(enum thought-ast
  (Atom [name : String])                          ; dictionary lookup
  (Linear [name : String] [value : f64] [scale : f64])  ; bind(atom, encode-linear)
  (Log [name : String] [value : f64])             ; bind(atom, encode-log)
  (Circular [name : String] [value : f64] [period : f64]) ; bind(atom, encode-circular)
  (Bind [left : ThoughtAST] [right : ThoughtAST]) ; composition of two sub-trees
  (Bundle [children : Vec<ThoughtAST>]))           ; superposition of sub-trees

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
                [ast : ThoughtAST])
  : Vector
  (or (lookup (:compositions encoder) ast)        ; cache hit → done
      (let ((result
              (match ast
                ((Atom name)
                  (lookup-atom (:atoms encoder) name))

                ((Linear name value scale)
                  (bind (encode encoder (Atom name))
                        (encode-linear value scale)))

                ((Log name value)
                  (bind (encode encoder (Atom name))
                        (encode-log value)))

                ((Circular name value period)
                  (bind (encode encoder (Atom name))
                        (encode-circular value period)))

                ((Bind left right)
                  (bind (encode encoder left)
                        (encode encoder right)))

                ((Bundle children)
                  (apply bundle
                    (map (lambda (c) (encode encoder c)) children))))))

        (store (:compositions encoder) ast result)
        result)))

;; ── lookup-atom — dictionary access ─────────────────────────────────
;;
;; The atom dictionary is pre-populated. Missing atoms are an error
;; in the vocabulary — the set is closed.

(define (lookup-atom [atoms : Map<String, Vector>]
                     [name : String])
  : Vector
  (get atoms name))
