;; exit-observer.wat — estimates exit distances with four continuous reckoners
;;
;; Depends on: enums (ExitLens, Prediction, ThoughtAST),
;;             distances (Distances), scalar-accumulator, ctx
;;
;; Each exit observer has FOUR continuous reckoners — one per distance
;; (trail, stop, tp, runner-trail). No noise-subspace, no curve, no
;; engram gating. The exit observer's quality is measured through the
;; BROKER's curve, not its own.
;;
;; evaluate-and-compose returns (Vector, Vec<(ThoughtAST, Vector)>).
;; recommended-distances returns (Distances, f64).

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require ctx)

(struct exit-observer
  [lens : ExitLens]                       ; which judgment vocabulary
  [trail-reckoner : Reckoner]             ; :continuous — trailing stop distance
  [stop-reckoner : Reckoner]              ; :continuous — safety stop distance
  [tp-reckoner : Reckoner]                ; :continuous — take-profit distance
  [runner-reckoner : Reckoner]            ; :continuous — runner trailing stop distance
  [default-distances : Distances])        ; the crutches, returned when empty

;; ── Constructor ────────────────────────────────────────────────────

(define (make-exit-observer [lens : ExitLens]
                            [dims : usize]
                            [recalib-interval : usize]
                            [default-trail : f64]
                            [default-stop : f64]
                            [default-tp : f64]
                            [default-runner-trail : f64])
  : ExitObserver
  (exit-observer
    lens
    (make-reckoner (Continuous dims recalib-interval default-trail))
    (make-reckoner (Continuous dims recalib-interval default-stop))
    (make-reckoner (Continuous dims recalib-interval default-tp))
    (make-reckoner (Continuous dims recalib-interval default-runner-trail))
    (make-distances default-trail default-stop default-tp default-runner-trail)))

;; ── encode-exit-facts ──────────────────────────────────────────────
;; Pure: candle -> judgment fact ASTs for this lens.

(define (encode-exit-facts [exit-obs : ExitObserver] [candle : Candle])
  : Vec<ThoughtAST>
  (match (:lens exit-obs)
    (:volatility  (encode-exit-volatility-facts candle))
    (:structure   (encode-exit-structure-facts candle))
    (:timing      (encode-exit-timing-facts candle))
    (:generalist  (append
                    (encode-exit-volatility-facts candle)
                    (encode-exit-structure-facts candle)
                    (encode-exit-timing-facts candle)))))

;; ── evaluate-and-compose ───────────────────────────────────────────
;; Two operations, honestly named:
;;   1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
;;   2. COMPOSE: bundle the evaluated exit vectors with the market thought
;; Returns: (composed-vector, cache-misses)

(define (evaluate-and-compose [exit-obs : ExitObserver]
                              [market-thought : Vector]
                              [exit-fact-asts : Vec<ThoughtAST>]
                              [ctx : Ctx])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let* (;; Encode each exit fact AST, collecting misses
         (pairs (map (lambda (ast) (encode (:thought-encoder ctx) ast))
                     exit-fact-asts))
         (exit-vecs (map first pairs))
         (all-misses (apply append (map second pairs)))
         ;; Compose: bundle market thought with all exit fact vectors
         (composed (apply bundle (cons market-thought exit-vecs))))
    (list composed all-misses)))

;; ── recommended-distances ──────────────────────────────────────────
;; Returns: (Distances, experience-f64)
;; The cascade per magic number:
;;   experienced? -> predict (contextual)
;;   has-data? -> extract-scalar (global per-pair)
;;   else -> default (crutch)

(define (recommended-distances [exit-obs : ExitObserver]
                               [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>])
  : (Distances, f64)
  (let* ((defaults (:default-distances exit-obs))
         ;; Per-distance cascade
         (trail-val (cascade-distance (:trail-reckoner exit-obs)
                                       composed
                                       (nth broker-accums 0)
                                       (:trail defaults)))
         (stop-val  (cascade-distance (:stop-reckoner exit-obs)
                                       composed
                                       (nth broker-accums 1)
                                       (:stop defaults)))
         (tp-val    (cascade-distance (:tp-reckoner exit-obs)
                                       composed
                                       (nth broker-accums 2)
                                       (:tp defaults)))
         (runner-val (cascade-distance (:runner-reckoner exit-obs)
                                        composed
                                        (nth broker-accums 3)
                                        (:runner-trail defaults)))
         ;; Minimum experience across all four reckoners
         (min-exp (min (experience (:trail-reckoner exit-obs))
                       (min (experience (:stop-reckoner exit-obs))
                            (min (experience (:tp-reckoner exit-obs))
                                 (experience (:runner-reckoner exit-obs)))))))
    (list (make-distances trail-val stop-val tp-val runner-val) min-exp)))

;; ── cascade-distance (internal) ────────────────────────────────────
;; The three-level cascade for one distance.

(define (cascade-distance [reck : Reckoner]
                          [composed : Vector]
                          [accum : ScalarAccumulator]
                          [default : f64])
  : f64
  (if (> (experience reck) 0.0)
    ;; Contextual — for THIS thought
    (let ((pred (predict reck composed)))
      (match pred
        ((Continuous value _) value)
        ((Discrete _ _) default)))
    ;; Fall through to global per-pair
    (if (> (:count accum) 0)
      (extract-scalar accum 100 (list 0.001 0.10))
      ;; Crutch — the starting value
      default)))

;; ── observe-distances ──────────────────────────────────────────────
;; The four reckoners learn from the hindsight-optimal distances.
;; composed: the COMPOSED thought (market + exit facts) — same vector
;; the exit observer produced via evaluate-and-compose.

(define (observe-distances [exit-obs : ExitObserver]
                           [composed : Vector]
                           [optimal : Distances]
                           [weight : f64])
  (observe (:trail-reckoner exit-obs)  composed (:trail optimal)       weight)
  (observe (:stop-reckoner exit-obs)   composed (:stop optimal)        weight)
  (observe (:tp-reckoner exit-obs)     composed (:tp optimal)          weight)
  (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight))

;; ── experienced? ───────────────────────────────────────────────────
;; True if ALL FOUR reckoners have experience > 0.0.

(define (experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs)) 0.0)
       (> (experience (:tp-reckoner exit-obs)) 0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))
