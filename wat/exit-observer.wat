; exit-observer.wat — estimates exit distances. Learned.
;
; Depends on: reckoner (:continuous x4), ExitLens, Distances,
;             ScalarAccumulator, ThoughtAST, ThoughtEncoder.
;
; Four continuous reckoners — one per distance (trail, stop, tp,
; runner-trail). No noise-subspace, no curve, no engram gating —
; intentionally simpler than MarketObserver. The exit observer's
; quality is measured through the BROKER's curve, not its own.
;
; Composes market thoughts with its own judgment facts.
; The cascade: contextual (reckoner) -> global (scalar accumulator) -> crutch.

(require primitives)
(require enums)               ; Prediction, reckoner-config, ExitLens
(require distances)           ; Distances
(require scalar-accumulator)  ; ScalarAccumulator, extract-scalar
(require thought-encoder)     ; ThoughtAST, ThoughtEncoder, encode

;; ── Struct ──────────────────────────────────────────────────────────────

(struct exit-observer
  [lens : ExitLens]                    ; which judgment vocabulary
  [trail-reckoner : Reckoner]          ; :continuous — trailing stop distance
  [stop-reckoner : Reckoner]           ; :continuous — safety stop distance
  [tp-reckoner : Reckoner]             ; :continuous — take-profit distance
  [runner-reckoner : Reckoner]         ; :continuous — runner trailing stop distance (wider)
  [default-distances : Distances])     ; the crutches (all four), returned when empty

;; ── Constructor ─────────────────────────────────────────────────────────

(define (make-exit-observer [lens : ExitLens]
                            [dims : usize]
                            [recalib-interval : usize]
                            [default-trail : f64]
                            [default-stop : f64]
                            [default-tp : f64]
                            [default-runner-trail : f64])
  : ExitObserver
  (make-exit-observer
    lens
    (make-reckoner (Continuous dims recalib-interval default-trail))
    (make-reckoner (Continuous dims recalib-interval default-stop))
    (make-reckoner (Continuous dims recalib-interval default-tp))
    (make-reckoner (Continuous dims recalib-interval default-runner-trail))
    (make-distances default-trail default-stop default-tp default-runner-trail)))

;; ── encode-exit-facts — lens -> vocab modules -> fact ASTs ──────────────
;;
;; Pure: candle -> judgment fact ASTs for this lens.

(define (encode-exit-facts [exit-obs : ExitObserver]
                           [candle : Candle])
  : Vec<ThoughtAST>
  (match (:lens exit-obs)
    (:volatility (encode-exit-volatility-facts candle))
    (:structure  (encode-exit-structure-facts candle))
    (:timing     (encode-exit-timing-facts candle))
    (:generalist (append (encode-exit-volatility-facts candle)
                         (encode-exit-structure-facts candle)
                         (encode-exit-timing-facts candle)))))

;; ── evaluate-and-compose — two operations, honestly named ───────────────
;;
;; 1. EVALUATE: encode exit-fact-asts into Vectors via ctx's ThoughtEncoder
;; 2. COMPOSE: bundle the evaluated exit vectors with the market thought
;;
;; Returns: (composed-vector, misses)

(define (evaluate-and-compose [exit-obs : ExitObserver]
                              [market-thought : Vector]
                              [exit-fact-asts : Vec<ThoughtAST>]
                              [ctx : Ctx])
  : (Vector, Vec<(ThoughtAST, Vector)>)
  (let* ((pairs (map (lambda (ast) (encode (:thought-encoder ctx) ast))
                     exit-fact-asts))
         (exit-vectors (map first pairs))
         (all-misses (apply append (map second pairs)))
         ;; Bundle market thought with all evaluated exit vectors
         (composed (apply bundle (cons market-thought exit-vectors))))
    (list composed all-misses)))

;; ── recommended-distances — the cascade ─────────────────────────────────
;;
;; Per magic number:
;;   if experienced? reckoner -> contextual (for THIS thought)
;;   else if has-data? broker-accum -> global per-pair (any thought)
;;   else -> crutch (the default distance)
;;
;; Returns: (Distances, f64 experience)

(define (recommended-distances [exit-obs : ExitObserver]
                               [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>])
  : (Distances, f64)
  ;; broker-accums convention: 0=trail, 1=stop, 2=tp, 3=runner-trail
  (let* ((trail
           (cascade-distance (:trail-reckoner exit-obs)
                             composed
                             (nth broker-accums 0)
                             (:trail (:default-distances exit-obs))))

         (stop
           (cascade-distance (:stop-reckoner exit-obs)
                             composed
                             (nth broker-accums 1)
                             (:stop (:default-distances exit-obs))))

         (tp
           (cascade-distance (:tp-reckoner exit-obs)
                             composed
                             (nth broker-accums 2)
                             (:tp (:default-distances exit-obs))))

         (runner-trail
           (cascade-distance (:runner-reckoner exit-obs)
                             composed
                             (nth broker-accums 3)
                             (:runner-trail (:default-distances exit-obs))))

         ;; Experience — the minimum across all four reckoners.
         (exp (min (experience (:trail-reckoner exit-obs))
                   (experience (:stop-reckoner exit-obs))
                   (experience (:tp-reckoner exit-obs))
                   (experience (:runner-reckoner exit-obs)))))

    (list (make-distances trail stop tp runner-trail)
          exp)))

;; ── cascade-distance — one magic number's cascade ───────────────────────

(define (cascade-distance [reckoner : Reckoner]
                          [composed : Vector]
                          [accum : ScalarAccumulator]
                          [default-distance : f64])
  : f64
  (if (> (experience reckoner) 0.0)
      ;; Contextual — for THIS thought
      (let ((pred (predict reckoner composed)))
        (match pred
          ((Continuous value exp) value)))
      ;; Global per-pair — any thought
      (if (> (:count accum) 0)
          (extract-scalar accum 100 (list 0.001 0.10))
          ;; Crutch — the starting value
          default-distance)))

;; ── observe-distances — learn from reality ──────────────────────────────

(define (observe-distances [exit-obs : ExitObserver]
                           [composed : Vector]
                           [optimal : Distances]
                           [weight : f64])
  (observe (:trail-reckoner exit-obs)  composed (:trail optimal)        weight)
  (observe (:stop-reckoner exit-obs)   composed (:stop optimal)         weight)
  (observe (:tp-reckoner exit-obs)     composed (:tp optimal)           weight)
  (observe (:runner-reckoner exit-obs) composed (:runner-trail optimal) weight))

;; ── experienced? — are ALL four reckoners past ignorance? ───────────────

(define (experienced? [exit-obs : ExitObserver])
  : bool
  (and (> (experience (:trail-reckoner exit-obs))  0.0)
       (> (experience (:stop-reckoner exit-obs))   0.0)
       (> (experience (:tp-reckoner exit-obs))     0.0)
       (> (experience (:runner-reckoner exit-obs)) 0.0)))
