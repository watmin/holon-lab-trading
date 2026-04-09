;; exit-observer.wat — ExitObserver struct + interface
;; Depends on: enums, distances, thought-encoder, scalar-accumulator, ctx

(require primitives)
(require enums)
(require distances)
(require thought-encoder)
(require scalar-accumulator)
(require ctx)

;; Vocabulary imports — lens determines which modules fire
(require vocab/exit/volatility)
(require vocab/exit/structure)
(require vocab/exit/timing)

(struct exit-observer
  [lens : ExitLens]
  [trail-reckoner : Reckoner]
  [stop-reckoner : Reckoner]
  [tp-reckoner : Reckoner]
  [runner-reckoner : Reckoner]
  [default-distances : Distances])

(define (make-exit-observer [lens : ExitLens] [dims : usize]
                            [recalib-interval : usize]
                            [default-trail : f64] [default-stop : f64]
                            [default-tp : f64] [default-runner-trail : f64])
  : ExitObserver
  (exit-observer
    lens
    (make-reckoner "trail" dims recalib-interval (Continuous default-trail))
    (make-reckoner "stop" dims recalib-interval (Continuous default-stop))
    (make-reckoner "tp" dims recalib-interval (Continuous default-tp))
    (make-reckoner "runner-trail" dims recalib-interval (Continuous default-runner-trail))
    (make-distances default-trail default-stop default-tp default-runner-trail)))

;; Collect vocabulary ASTs based on this observer's lens.
(define (encode-exit-facts [exit-obs : ExitObserver] [candle : Candle])
  : Vec<ThoughtAST>
  (match (:lens exit-obs)
    (:volatility
      (encode-exit-volatility-facts candle))
    (:structure
      (encode-exit-structure-facts candle))
    (:timing
      (encode-exit-timing-facts candle))
    (:generalist
      (append (encode-exit-volatility-facts candle)
              (encode-exit-structure-facts candle)
              (encode-exit-timing-facts candle)))))

;; Evaluate exit ASTs and compose with market thought.
;; Two operations, honestly named:
;;   1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
;;   2. COMPOSE: bundle the evaluated exit vectors with the market thought
(define (evaluate-and-compose [exit-obs : ExitObserver]
                              [market-thought : Vector]
                              [exit-fact-asts : Vec<ThoughtAST>]
                              [ctx : Ctx])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let ((all-asts (append exit-fact-asts (list (Bundle '()))))  ; placeholder
        ;; Encode exit ASTs
        (bundle-ast (Bundle exit-fact-asts))
        ((exit-vec exit-misses) (encode (:thought-encoder ctx) bundle-ast))
        ;; Compose: bundle market thought with exit facts
        (composed (bundle market-thought exit-vec)))
    (list composed exit-misses)))

;; Is this exit observer experienced? True if ALL FOUR reckoners have experience.
(define (experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs)) 0.0)
       (> (experience (:tp-reckoner exit-obs)) 0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))

;; Recommend distances for a given composed thought.
;; The cascade per distance: contextual (reckoner) -> global (accumulator) -> crutch.
;; broker-accums: the broker's scalar accumulators (4 — trail, stop, tp, runner-trail).
(define (recommended-distances [exit-obs : ExitObserver]
                               [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>])
  : (Distances, f64)  ; distances + experience
  (let ((cascade (lambda (reckoner accum default-val)
          ;; Contextual first
          (if (> (experience reckoner) 0.0)
            (match (predict reckoner composed)
              ((Continuous value exp) value)
              ((Discrete scores conv) default-val))
            ;; Global per-pair second
            (if (> (:count accum) 0)
              (extract-scalar accum 50 0.001 0.1)
              ;; Crutch
              default-val))))

        (trail-val (cascade (:trail-reckoner exit-obs)
                            (nth broker-accums 0)
                            (:trail (:default-distances exit-obs))))
        (stop-val (cascade (:stop-reckoner exit-obs)
                           (nth broker-accums 1)
                           (:stop (:default-distances exit-obs))))
        (tp-val (cascade (:tp-reckoner exit-obs)
                         (nth broker-accums 2)
                         (:tp (:default-distances exit-obs))))
        (runner-val (cascade (:runner-reckoner exit-obs)
                             (nth broker-accums 3)
                             (:runner-trail (:default-distances exit-obs))))
        ;; Minimum experience across all four
        (exp-val (min (experience (:trail-reckoner exit-obs))
                      (min (experience (:stop-reckoner exit-obs))
                           (min (experience (:tp-reckoner exit-obs))
                                (experience (:runner-reckoner exit-obs)))))))
    (list (make-distances trail-val stop-val tp-val runner-val) exp-val)))

;; Learn from a resolved outcome. All four reckoners learn from one resolution.
;; composed: the COMPOSED thought (market + exit facts).
;; optimal: the hindsight-optimal distances from resolution.
(define (observe-distances [exit-obs : ExitObserver]
                           [composed : Vector]
                           [optimal : Distances]
                           [weight : f64])
  (observe (:trail-reckoner exit-obs) composed (:trail optimal) weight)
  (observe (:stop-reckoner exit-obs) composed (:stop optimal) weight)
  (observe (:tp-reckoner exit-obs) composed (:tp optimal) weight)
  (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight))
