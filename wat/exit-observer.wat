;; exit-observer.wat — ExitObserver struct + interface
;; Depends on: enums.wat, distances.wat, scalar-accumulator.wat, thought-encoder.wat, ctx.wat

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require thought-encoder)
(require ctx)

;; ── Exit vocabulary dispatch ───────────────────────────────────────
(require vocab/exit/volatility)
(require vocab/exit/structure)
(require vocab/exit/timing)

;; ── ExitObserver ───────────────────────────────────────────────────
;; Estimates exit distance. Four continuous reckoners — one per distance.
;; No noise-subspace, no curve, no engram gating.

(struct exit-observer
  [lens : ExitLens]
  [trail-reckoner : Reckoner]
  [stop-reckoner : Reckoner]
  [tp-reckoner : Reckoner]
  [runner-reckoner : Reckoner]
  [default-distances : Distances])

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
    (make-reckoner (format "trail-{}" lens) dims recalib-interval
      (Continuous default-trail))
    (make-reckoner (format "stop-{}" lens) dims recalib-interval
      (Continuous default-stop))
    (make-reckoner (format "tp-{}" lens) dims recalib-interval
      (Continuous default-tp))
    (make-reckoner (format "runner-{}" lens) dims recalib-interval
      (Continuous default-runner-trail))
    (make-distances default-trail default-stop default-tp default-runner-trail)))

;; ── encode-exit-facts — pure: candle → judgment fact ASTs ──────────

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

;; ── evaluate-and-compose ───────────────────────────────────────────
;; 1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
;; 2. COMPOSE: bundle the evaluated exit vectors with the market thought

(define (evaluate-and-compose [exit-obs : ExitObserver]
                              [market-thought : Vector]
                              [exit-fact-asts : Vec<ThoughtAST>]
                              [c : Ctx])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let (;; Wrap exit facts in a Bundle
        (exit-bundle-ast (Bundle exit-fact-asts))
        ;; Encode the exit facts
        ((exit-vec exit-misses) (encode (:thought-encoder c) exit-bundle-ast))
        ;; Compose: bundle market thought with exit facts
        (composed (bundle market-thought exit-vec)))
    (list composed exit-misses)))

;; ── recommended-distances ──────────────────────────────────────────
;; The cascade: contextual (reckoner) → global per-pair (ScalarAccumulator) → crutch

(define (recommended-distances [exit-obs : ExitObserver]
                               [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>])
  : (Distances, f64)
  (let ((cascade-fn (lambda (reckoner accum default-val)
          (if (> (experience reckoner) 0.0)
            ;; Contextual — reckoner has experience
            (let ((pred (predict reckoner composed)))
              (match pred
                ((Continuous val exp) val)
                ((Discrete scores conv) default-val)))
            ;; Fall through to global or crutch
            (if (> (:count accum) 0)
              (extract-scalar accum 50 (list 0.002 0.10))
              default-val))))
        (trail-val (cascade-fn (:trail-reckoner exit-obs)
                     (nth broker-accums 0)
                     (:trail (:default-distances exit-obs))))
        (stop-val (cascade-fn (:stop-reckoner exit-obs)
                    (nth broker-accums 1)
                    (:stop (:default-distances exit-obs))))
        (tp-val (cascade-fn (:tp-reckoner exit-obs)
                  (nth broker-accums 2)
                  (:tp (:default-distances exit-obs))))
        (runner-val (cascade-fn (:runner-reckoner exit-obs)
                      (nth broker-accums 3)
                      (:runner-trail (:default-distances exit-obs))))
        ;; Experience = min of all four reckoners
        (exp (min (experience (:trail-reckoner exit-obs))
                  (min (experience (:stop-reckoner exit-obs))
                       (min (experience (:tp-reckoner exit-obs))
                            (experience (:runner-reckoner exit-obs)))))))
    (list (make-distances trail-val stop-val tp-val runner-val) exp)))

;; ── observe-distances — learn from resolved outcomes ───────────────

(define (observe-distances [exit-obs : ExitObserver]
                           [composed : Vector]
                           [optimal : Distances]
                           [weight : f64])
  (observe (:trail-reckoner exit-obs) composed (:trail optimal) weight)
  (observe (:stop-reckoner exit-obs) composed (:stop optimal) weight)
  (observe (:tp-reckoner exit-obs) composed (:tp optimal) weight)
  (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight))

;; ── experienced? — are all four reckoners experienced? ─────────────

(define (exit-experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs)) 0.0)
       (> (experience (:tp-reckoner exit-obs)) 0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))
