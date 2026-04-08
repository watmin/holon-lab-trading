; thought-encoder.wat — ThoughtEncoder struct + encode
;
; Depends on: enums (ThoughtAST)
;
; The vocabulary produces ThoughtASTs — data, not execution.
; The ThoughtEncoder evaluates them — HOW to think efficiently.
; It walks the AST bottom-up, checking its memory at every node.
; The minimum computation happens.
;
; Two kinds of memory:
;   Atoms: a dictionary. Finite. Pre-computed. Never evicted.
;   Compositions: a cache. Optimistic. Self-evicting.
;
; The cache is eventually-consistent: encode returns misses as values.
; During parallel encoding, nobody writes. Between candles, the enterprise
; collects all misses and inserts them. Miss on candle N, hit on N+1.
; Values up, not queues down.

(require primitives)
(require enums)    ; ThoughtAST

; ── ThoughtEncoder — evaluates ASTs into vectors ────────────────────

(struct thought-encoder
  [atoms : Map<String, Vector>]                   ; finite, pre-computed, permanent
  [compositions : LruCache<ThoughtAST, Vector>])  ; optimistic, self-evicting
;; LruCache is an opaque host type (Rust: lru::LruCache). make-lru-cache
;; constructs it. Access via (get cache key) → value or None.

; Constructor: takes a VectorManager, pre-populates atom dictionary.
(define (make-thought-encoder [vm : VectorManager])
  : ThoughtEncoder
  ; Atoms are pre-allocated from the VectorManager.
  ; The set is closed — every atom name used by the vocabulary
  ; is known at startup.
  (make-thought-encoder
    (map-of)  ; atoms — populated by pre-warming
    (make-lru-cache)))

; ── encode — the one function ───────────────────────────────────────
;
; Recursive. Cache at every node. The cache key IS the AST node —
; its structure is its identity. Same structure, same vector.
;
; Returns (Vector, Vec<(ThoughtAST, Vector)>) — the vector AND cache misses.
; On cache hit: return (vector, empty-list). On miss: compute, return (vector, misses).
; The encode function NEVER writes to the cache. Values up, not queues down.

(define (encode [encoder : ThoughtEncoder]
                [ast : ThoughtAST])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (if (get (:compositions encoder) ast)            ; cache hit → (vector, empty)
      (values (get (:compositions encoder) ast) '())
      (let-values (((result misses)
              (match ast
                ((Atom name)
                  (values (lookup-atom (:atoms encoder) name) '()))

                ((Linear name value scale)
                  (let-values (((atom-vec atom-misses) (encode encoder (Atom name))))
                    (values (bind atom-vec (encode-linear value scale))
                            atom-misses)))

                ((Log name value)
                  (let-values (((atom-vec atom-misses) (encode encoder (Atom name))))
                    (values (bind atom-vec (encode-log value))
                            atom-misses)))

                ((Circular name value period)
                  (let-values (((atom-vec atom-misses) (encode encoder (Atom name))))
                    (values (bind atom-vec (encode-circular value period))
                            atom-misses)))

                ((Bind left right)
                  (let-values (((l-vec l-misses) (encode encoder left))
                               ((r-vec r-misses) (encode encoder right)))
                    (values (bind l-vec r-vec)
                            (append l-misses r-misses))))

                ((Bundle children)
                  (let ((pairs (map (lambda (c) (encode encoder c)) children)))
                    (values (apply bundle (map first pairs))
                            (apply append (map second pairs))))))))

        (values result (cons (list ast result) misses)))))

; ── lookup-atom — dictionary access ─────────────────────────────────
;
; The atom dictionary is pre-populated. Missing atoms are an error
; in the vocabulary — the set is closed.

(define (lookup-atom [atoms : Map<String, Vector>]
                     [name : String])
  : Vector
  (get atoms name))
