;; exit-observer.wat — ExitObserver struct + interface
;; Depends on: reckoner, distances, enums, scalar-accumulator, thought-encoder, ctx

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require thought-encoder)
(require ctx)
(require vocab/exit/volatility)
(require vocab/exit/structure)
(require vocab/exit/timing)

(struct exit-observer
  [lens : ExitLens]
  [trail-reckoner : Reckoner]          ; :continuous — trailing stop distance
  [stop-reckoner : Reckoner]           ; :continuous — safety stop distance
  [tp-reckoner : Reckoner]             ; :continuous — take-profit distance
  [runner-reckoner : Reckoner]         ; :continuous — runner trailing stop distance
  [default-distances : Distances])     ; the crutches, returned when empty

(define (make-exit-observer [lens : ExitLens]
                            [dims : usize]
                            [recalib-interval : usize]
                            [default-trail : f64]
                            [default-stop : f64]
                            [default-tp : f64]
                            [default-runner-trail : f64])
  : ExitObserver
  (let ((name-prefix (format "exit-{}" lens)))
    (exit-observer
      lens
      (make-reckoner (format "{}-trail" name-prefix) dims recalib-interval
        (Continuous default-trail))
      (make-reckoner (format "{}-stop" name-prefix) dims recalib-interval
        (Continuous default-stop))
      (make-reckoner (format "{}-tp" name-prefix) dims recalib-interval
        (Continuous default-tp))
      (make-reckoner (format "{}-runner" name-prefix) dims recalib-interval
        (Continuous default-runner-trail))
      (make-distances default-trail default-stop default-tp default-runner-trail))))

;; Collect exit vocabulary facts for this lens
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

;; Evaluate exit ASTs and compose with market thought
;; Two operations: evaluate ASTs, then bundle with market thought
(define (evaluate-and-compose [exit-obs : ExitObserver]
                               [market-thought : Vector]
                               [exit-fact-asts : Vec<ThoughtAST>]
                               [c : Ctx])
  : (Vector Vec<(ThoughtAST, Vector)>)
  (let ((bundle-ast (Bundle (cons (Atom "__market-thought__") exit-fact-asts)))
        ;; We need to encode the exit facts and bundle with market thought
        ;; Encode each exit AST separately, then bundle all with market thought
        (pairs (map (lambda (ast) (encode (:thought-encoder c) ast)) exit-fact-asts))
        (exit-vecs (map first pairs))
        (all-misses (apply append (map second pairs)))
        ;; Compose: bundle market thought with all exit vectors
        (composed (apply bundle (cons market-thought exit-vecs))))
    (list composed all-misses)))

;; Is the exit observer experienced? All four reckoners must have experience.
(define (exit-experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs)) 0.0)
       (> (experience (:tp-reckoner exit-obs)) 0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))

;; Extract a single distance via the cascade:
;; contextual (reckoner) → global per-pair (scalar accumulator) → default (crutch)
(define (cascade-distance [reckoner : Reckoner]
                          [composed : Vector]
                          [accum : ScalarAccumulator]
                          [default-val : f64])
  : f64
  (if (> (experience reckoner) 0.0)
    ;; Contextual — for THIS thought
    (let ((pred (predict reckoner composed)))
      (match pred
        ((Continuous value exp) value)
        (_ default-val)))
    (if (> (:count accum) 0)
      ;; Global per-pair — any thought
      (extract-scalar accum 50 (list 0.002 0.10))
      ;; Crutch
      default-val)))

;; Recommend distances for a composed thought
;; Returns (Distances, experience)
(define (recommended-distances [exit-obs : ExitObserver]
                                [composed : Vector]
                                [broker-accums : Vec<ScalarAccumulator>])
  : (Distances f64)
  (let ((dists (:default-distances exit-obs))
        (trail-val (cascade-distance (:trail-reckoner exit-obs) composed
                     (nth broker-accums 0) (:trail dists)))
        (stop-val (cascade-distance (:stop-reckoner exit-obs) composed
                    (nth broker-accums 1) (:stop dists)))
        (tp-val (cascade-distance (:tp-reckoner exit-obs) composed
                  (nth broker-accums 2) (:tp dists)))
        (runner-val (cascade-distance (:runner-reckoner exit-obs) composed
                      (nth broker-accums 3) (:runner-trail dists)))
        (exp-val (min (experience (:trail-reckoner exit-obs))
                      (min (experience (:stop-reckoner exit-obs))
                           (min (experience (:tp-reckoner exit-obs))
                                (experience (:runner-reckoner exit-obs)))))))
    (list (make-distances trail-val stop-val tp-val runner-val) exp-val)))

;; Observe optimal distances from a resolution
(define (observe-distances [exit-obs : ExitObserver]
                            [composed : Vector]
                            [optimal : Distances]
                            [weight : f64])
  : ExitObserver
  (begin
    (observe (:trail-reckoner exit-obs) composed (:trail optimal) weight)
    (observe (:stop-reckoner exit-obs) composed (:stop optimal) weight)
    (observe (:tp-reckoner exit-obs) composed (:tp optimal) weight)
    (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight)
    exit-obs))
