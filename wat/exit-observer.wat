;; exit-observer.wat — ExitObserver struct + interface
;; Depends on: enums (ExitLens, prediction), distances, thought-encoder, ctx,
;;             scalar-accumulator

(require primitives)
(require enums)
(require distances)
(require thought-encoder)
(require ctx)
(require scalar-accumulator)
(require candle)
(require vocab/exit/volatility)
(require vocab/exit/structure)
(require vocab/exit/timing)

;; ── ExitObserver ──────────────────────────────────────────────────────
;; Estimates exit distances. Four continuous reckoners — one per distance.
;; No noise-subspace, no curve, no engram gating — intentionally simpler.
;; Quality measured through the BROKER's curve, not its own.
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
    (distances default-trail default-stop default-tp default-runner-trail)))

;; ── lens-to-exit-facts — dispatch vocabulary modules by lens ──────────
(define (encode-exit-facts [exit-obs : ExitObserver]
                           [c : Candle])
  : Vec<ThoughtAST>
  (match (:lens exit-obs)
    (:volatility
      (encode-exit-volatility-facts c))
    (:structure
      (encode-exit-structure-facts c))
    (:timing
      (encode-exit-timing-facts c))
    (:generalist
      (append
        (encode-exit-volatility-facts c)
        (encode-exit-structure-facts c)
        (encode-exit-timing-facts c)))))

;; ── evaluate-and-compose — encode exit ASTs, bundle with market thought
;; Two operations, honestly named:
;; 1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
;; 2. COMPOSE: bundle the evaluated exit vectors with the market thought
(define (evaluate-and-compose [exit-obs : ExitObserver]
                              [market-thought : Vector]
                              [exit-fact-asts : Vec<ThoughtAST>]
                              [ctx : Ctx])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let (;; Build a Bundle AST from exit facts + a reference to market thought
        ;; The market thought is already a vector — we bundle it directly
        ;; with the evaluated exit facts
        (pairs (map (lambda (ast) (encode (:thought-encoder ctx) ast))
                    exit-fact-asts))
        (exit-vectors (map first pairs))
        (all-misses (apply append (map second pairs)))
        ;; Compose: bundle market thought with all exit vectors
        (composed (apply bundle (cons market-thought exit-vectors))))
    (list composed all-misses)))

;; ── extract-distance — the cascade per magic number ───────────────────
;; experienced? → contextual (reckoner) → global per-pair (scalar) → crutch
(define (extract-one-distance [reckoner : Reckoner]
                              [composed : Vector]
                              [accum : ScalarAccumulator]
                              [default : f64])
  : f64
  (if (> (experience reckoner) 0.0)
    ;; Contextual — for THIS thought
    (match (predict reckoner composed)
      ((Continuous value _) value)
      (_ default))
    ;; Global per-pair or crutch
    (if (> (:count accum) 0)
      (let ((extract-steps 50)
            (extract-range (list 0.002 0.10)))
        (extract-scalar accum extract-steps extract-range))
      default)))

;; ── recommended-distances — one call, four answers ────────────────────
;; Each distance cascades independently.
;; Returns: Distances + experience (f64).
(define (recommended-distances [exit-obs : ExitObserver]
                               [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>])
  : (Distances, f64)
  (let ((defaults (:default-distances exit-obs))
        (trail-val (extract-one-distance
                     (:trail-reckoner exit-obs) composed
                     (nth broker-accums 0) (:trail defaults)))
        (stop-val (extract-one-distance
                    (:stop-reckoner exit-obs) composed
                    (nth broker-accums 1) (:stop defaults)))
        (tp-val (extract-one-distance
                  (:tp-reckoner exit-obs) composed
                  (nth broker-accums 2) (:tp defaults)))
        (runner-val (extract-one-distance
                      (:runner-reckoner exit-obs) composed
                      (nth broker-accums 3) (:runner-trail defaults)))
        ;; Experience = min across all four reckoners
        (exp-val (min (experience (:trail-reckoner exit-obs))
                      (min (experience (:stop-reckoner exit-obs))
                           (min (experience (:tp-reckoner exit-obs))
                                (experience (:runner-reckoner exit-obs)))))))
    (list (distances trail-val stop-val tp-val runner-val) exp-val)))

;; ── observe-distances — learn from reality ────────────────────────────
;; composed: the composed thought (market + exit facts).
;; optimal: Distances from hindsight.
;; weight: how much value was at stake.
(define (observe-distances [exit-obs : ExitObserver]
                           [composed : Vector]
                           [optimal : Distances]
                           [weight : f64])
  (observe (:trail-reckoner exit-obs) composed (:trail optimal) weight)
  (observe (:stop-reckoner exit-obs) composed (:stop optimal) weight)
  (observe (:tp-reckoner exit-obs) composed (:tp optimal) weight)
  (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight))

;; ── experienced? — all four reckoners have enough data ────────────────
(define (experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs)) 0.0)
       (> (experience (:tp-reckoner exit-obs)) 0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))
