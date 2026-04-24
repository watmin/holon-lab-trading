;; wat/encoding/scaled-linear.wat — Phase 3.3 (2026-04-22).
;;
;; Port of archived/pre-wat-native/src/encoding/scale_tracker.rs's
;; `scaled_linear` convenience — updates the named tracker, reads
;; the learned scale, returns a Bind(Atom(name), Thermometer(value,
;; -scale, scale)) fact.
;;
;; The archive used `Linear { value, scale }` — rejected in wat
;; (058-008) as redundant with Thermometer under a 3-arity
;; signature. Equivalent semantics land as `Thermometer(value,
;; -scale, scale)`: symmetric bounds around zero, width 2·scale.
;;
;; The Rust `&mut HashMap` idiom doesn't translate. Values-up:
;; caller threads the returned `(fact, updated-scales)` tuple
;; through subsequent calls.
;;
;; Value is rounded to 2 decimals before entering the fact so
;; repeated observations of nearly-equal values produce identical
;; cache keys (archive convention for hot-path encoding).

;; Self-load deps per arc 027's types-self-load pattern.
;; scaled-linear uses round-to-2 (round.wat) + ScaleTracker
;; (scale-tracker.wat). Prior omission was a latent bug; any caller
;; that didn't already have round.wat loaded saw UnknownFunction
;; at runtime. Fixed in arc 005.
(:wat::load-file! "./round.wat")
(:wat::load-file! "./scale-tracker.wat")

;; :trading::encoding::ScaleEmission — arc 004. Typealias for
;; scaled-linear's return shape: a holon paired with the updated
;; Scales. Values-up carries the tuple forward through subsequent
;; encoding calls. Named via /gaze — "an emission that updated
;; the scales" — the tuple IS the dual product of fact-emission
;; and scale-threading.
(:wat::core::typealias
  :trading::encoding::ScaleEmission
  :(wat::holon::HolonAST,trading::encoding::Scales))

;; :trading::encoding::VocabEmission — arc 006. The bulk-form
;; sibling of ScaleEmission: what a full vocab function returns.
;; Multiple holons + the Scales after all scaled-linear threading.
;; Named when arc 006 (divergence) became the second caller to
;; emit the shape (arc 005's oscillators was the first).
;;
;; Relationship:
;;   ScaleEmission  = one scaled-linear call's output
;;   VocabEmission  = one vocab function's output (composes many
;;                    ScaleEmissions into one per-candle emission)
(:wat::core::typealias
  :trading::encoding::VocabEmission
  :(wat::holon::Holons,trading::encoding::Scales))

(:wat::core::define
  (:trading::encoding::scaled-linear
    (name :String)
    (value :f64)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::ScaleEmission)
  (:wat::core::let*
    (((prev :trading::encoding::ScaleTracker)
      (:wat::core::match (:wat::core::get scales name)
                         -> :trading::encoding::ScaleTracker
        ((Some t) t)
        (:None    (:trading::encoding::ScaleTracker::fresh))))
     ((updated-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update prev value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale updated-tracker))
     ((neg-scale :f64)
      (:wat::core::f64::- 0.0 scale))
     ((rounded-value :f64)
      (:trading::encoding::round-to-2 value))
     ((fact :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom name)
        (:wat::holon::Thermometer rounded-value neg-scale scale)))
     ((updated-scales :trading::encoding::Scales)
      (:wat::core::assoc scales name updated-tracker)))
    (:wat::core::tuple fact updated-scales)))
