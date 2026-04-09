;; thought-encoder.wat — evaluates the vocabulary's ThoughtASTs into vectors
;;
;; Depends on: primitives (atom, bind, bundle, encode-linear, encode-log, encode-circular)
;; Lives on ctx. The one seam: composition cache updates between candles.
;;
;; The vocabulary produces ASTs — data, not execution.
;; The ThoughtEncoder evaluates them — caching at every node.
;;
;; Two kinds of memory:
;;   atoms:        Map<String, Vector>  — finite, pre-computed, permanent
;;   compositions: LruCache<ThoughtAST, Vector> — optimistic, self-evicting
;;
;; LruCache is an opaque host type — a bounded map with least-recently-used
;; eviction. Interface: (get cache key) → Option<Vector>, constructed by
;; the host at startup with a capacity. The encoder never writes to it —
;; misses flow up as values.

(require primitives)

(struct thought-encoder
  [atoms : Map<String, Vector>]
  [compositions : LruCache<ThoughtAST, Vector>])

;; encode: evaluate a ThoughtAST, return (vector, misses).
;; On cache hit: return the vector and empty misses.
;; On cache miss: compute the vector, return it AND the (ast, vector) pair.
;; The caller collects all misses. The enterprise inserts them after all
;; steps complete. Values up, not queues down.

(define (encode [encoder : ThoughtEncoder] [ast : ThoughtAST])
  : (list Vector Vec<(ThoughtAST, Vector)>)
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
