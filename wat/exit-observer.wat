;; ── exit-observer.wat ───────────────────────────────────────────────
;;
;; Estimates exit distances. Learned. Two continuous reckoners — one per
;; distance (trail, stop). No noise-subspace, no curve, no engram gating —
;; intentionally simpler than MarketObserver. The exit observer's quality
;; is measured through the BROKER's curve, not its own.
;; Depends on: Reckoner :continuous, Distances, ExitLens (enums),
;;             ScalarAccumulator, IncrementalBundle.

(require primitives)
(require enums)
(require distances)
(require scalar-accumulator)
(require thought-encoder)

;; ── Struct ──────────────────────────────────────────────────────────

(struct exit-observer
  [lens : ExitLens]                    ; which judgment vocabulary
  [trail-reckoner : Reckoner]          ; :continuous — trailing stop distance
  [stop-reckoner : Reckoner]           ; :continuous — safety stop distance
  [default-distances : Distances]      ; the crutches (both), returned when empty
  [incremental : IncrementalBundle])   ; optimization cache for exit facts, not cognition

;; ── Interface ───────────────────────────────────────────────────────

(define (make-exit-observer [lens : ExitLens]
                            [dims : usize]
                            [recalib-interval : usize]
                            [default-trail : f64]
                            [default-stop : f64])
  : ExitObserver
  (exit-observer
    lens
    (reckoner "trail" dims recalib-interval (Continuous default-trail))
    (reckoner "stop"  dims recalib-interval (Continuous default-stop))
    (make-distances default-trail default-stop)
    (make-incremental-bundle dims)))

(define (recommended-distances [exit-obs : ExitObserver]
                               [composed : Vector]
                               [broker-accums : Vec<ScalarAccumulator>]
                               [scalar-encoder : ScalarEncoder])
  : (Distances f64)
  ;; Returns: Distances + experience (f64 — how much the exit observer knows).
  ;; The cascade, per distance:
  ;;   experienced? reckoner → predict (contextual for THIS thought)
  ;;   has-data? broker-accum → extract-scalar (global per-pair)
  ;;   default-distance (crutch — the starting value)
  (let ((trail-exp (experience (:trail-reckoner exit-obs)))
        (stop-exp  (experience (:stop-reckoner exit-obs)))
        (trail-accum (nth broker-accums 0))
        (stop-accum  (nth broker-accums 1))
        ;; Trail distance cascade
        (trail (if (> trail-exp 0.0)
                   (query (:trail-reckoner exit-obs) composed)
                   (if (> (:count trail-accum) 0)
                       (extract trail-accum 100 '(0.001 0.10) scalar-encoder)
                       (:trail (:default-distances exit-obs)))))
        ;; Stop distance cascade
        (stop  (if (> stop-exp 0.0)
                   (query (:stop-reckoner exit-obs) composed)
                   (if (> (:count stop-accum) 0)
                       (extract stop-accum 100 '(0.001 0.10) scalar-encoder)
                       (:stop (:default-distances exit-obs)))))
        (total-exp (min trail-exp stop-exp)))
    (list (make-distances trail stop) total-exp)))

(define (observe-distances [exit-obs : ExitObserver]
                           [composed : Vector]
                           [optimal : Distances]
                           [weight : f64])
  ;; composed: the COMPOSED thought (market + exit facts), not the raw
  ;; market thought. The exit observer learns from the same vector it
  ;; produced via composition. This is what makes the learning contextual.
  ;; optimal: the hindsight-optimal distances from resolution.
  ;; Both reckoners learn from one resolution.
  (observe (:trail-reckoner exit-obs) composed (:trail optimal) weight)
  (observe (:stop-reckoner exit-obs)  composed (:stop optimal)  weight))

(define (experienced? [exit-obs : ExitObserver])
  : bool
  ;; True if both reckoners have accumulated enough observations to
  ;; produce meaningful predictions. If either is ignorant, the exit
  ;; observer is inexperienced — the cascade falls through.
  (and (> (experience (:trail-reckoner exit-obs)) 0.0)
       (> (experience (:stop-reckoner exit-obs))  0.0)))
