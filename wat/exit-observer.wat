;; exit-observer.wat — ExitObserver struct + interface
;; Depends on: enums (ExitLens), reckoner, distances, scalar-accumulator,
;;             thought-encoder (ThoughtAST), ctx, candle
;; Estimates exit distances. Four continuous reckoners — one per distance.
;; No noise-subspace, no curve, no engram gating — intentionally simpler.

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require thought-encoder)
(require ctx)
(require candle)
(require vocab/exit/volatility)
(require vocab/exit/structure)
(require vocab/exit/timing)

(struct exit-observer
  [lens : ExitLens]                    ; which judgment vocabulary
  [trail-reckoner : Reckoner]          ; :continuous — trailing stop distance
  [stop-reckoner : Reckoner]           ; :continuous — safety stop distance
  [tp-reckoner : Reckoner]             ; :continuous — take-profit distance
  [runner-reckoner : Reckoner]         ; :continuous — runner trailing stop distance
  [default-distances : Distances])     ; the crutches, returned when empty

(define (make-exit-observer [lens : ExitLens] [dims : usize]
                            [recalib-interval : usize]
                            [default-trail : f64] [default-stop : f64]
                            [default-tp : f64] [default-runner-trail : f64])
  : ExitObserver
  (exit-observer
    lens
    (make-reckoner (Continuous dims recalib-interval default-trail))
    (make-reckoner (Continuous dims recalib-interval default-stop))
    (make-reckoner (Continuous dims recalib-interval default-tp))
    (make-reckoner (Continuous dims recalib-interval default-runner-trail))
    (make-distances default-trail default-stop default-tp default-runner-trail)))

;; Collect exit vocab ASTs for this lens.
(define (encode-exit-facts [exit-obs : ExitObserver] [c : Candle])
  : Vec<ThoughtAST>
  (match (:lens exit-obs)
    (:volatility
      (encode-exit-volatility-facts c))
    (:structure
      (encode-exit-structure-facts c))
    (:timing
      (encode-exit-timing-facts c))
    (:generalist
      (append (encode-exit-volatility-facts c)
              (encode-exit-structure-facts c)
              (encode-exit-timing-facts c)))))

;; Evaluate exit ASTs and compose with market thought.
;; Two operations, honestly named:
;; 1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
;; 2. COMPOSE: bundle the evaluated exit vectors with the market thought
(define (evaluate-and-compose [exit-obs : ExitObserver]
                              [market-thought : Vector]
                              [exit-fact-asts : Vec<ThoughtAST>]
                              [c : Ctx])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  ;; Wrap market thought + exit facts into one bundle AST
  ;; The exit facts are ASTs, the market thought is already a vector.
  ;; Encode the exit ASTs, collect misses, then bundle with market thought.
  (let ((pairs (map (lambda (ast) (encode (:thought-encoder c) ast))
                    exit-fact-asts))
        (exit-vecs (map first pairs))
        (all-misses (apply append (map second pairs)))
        ;; Compose: bundle market thought with all exit vectors
        (composed (apply bundle (cons market-thought exit-vecs))))
    (list composed all-misses)))

;; Extract a distance from a single reckoner, with cascade.
;; contextual (reckoner) → global per-pair (ScalarAccumulator) → crutch
(define (cascade-distance [reckoner : Reckoner] [composed : Vector]
                          [accum : ScalarAccumulator] [default-val : f64])
  : f64
  (if (> (experience reckoner) 0.0)
    ;; Contextual — for THIS thought
    (match (predict reckoner composed)
      ((Continuous val _) val)
      ((Discrete _ _) default-val))  ; shouldn't happen
    (if (> (:count accum) 0)
      ;; Global per-pair — any thought
      (extract-scalar accum 50 (list 0.005 0.10))
      ;; Crutch — the starting value
      default-val)))

;; Recommended distances — the cascade, per magic number.
;; Returns: (Distances, experience).
(define (recommended-distances [exit-obs : ExitObserver] [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>])
  : (Distances, f64)
  (let ((trail-val   (cascade-distance (:trail-reckoner exit-obs) composed
                       (nth broker-accums 0) (:trail (:default-distances exit-obs))))
        (stop-val    (cascade-distance (:stop-reckoner exit-obs) composed
                       (nth broker-accums 1) (:stop (:default-distances exit-obs))))
        (tp-val      (cascade-distance (:tp-reckoner exit-obs) composed
                       (nth broker-accums 2) (:tp (:default-distances exit-obs))))
        (runner-val  (cascade-distance (:runner-reckoner exit-obs) composed
                       (nth broker-accums 3) (:runner-trail (:default-distances exit-obs))))
        (exp-val     (min (experience (:trail-reckoner exit-obs))
                          (min (experience (:stop-reckoner exit-obs))
                               (min (experience (:tp-reckoner exit-obs))
                                    (experience (:runner-reckoner exit-obs)))))))
    (list (make-distances trail-val stop-val tp-val runner-val) exp-val)))

;; Observe distances — the exit observer learns from resolved outcomes.
;; composed: the COMPOSED thought (market + exit facts).
;; optimal: hindsight-optimal distances.
(define (observe-distances [exit-obs : ExitObserver] [composed : Vector]
                           [optimal : Distances] [weight : f64])
  (observe (:trail-reckoner exit-obs) composed (:trail optimal) weight)
  (observe (:stop-reckoner exit-obs) composed (:stop optimal) weight)
  (observe (:tp-reckoner exit-obs) composed (:tp optimal) weight)
  (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight))

;; Experienced? — true if ALL FOUR reckoners have experience > 0.0.
(define (experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs)) 0.0)
       (> (experience (:tp-reckoner exit-obs)) 0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))
