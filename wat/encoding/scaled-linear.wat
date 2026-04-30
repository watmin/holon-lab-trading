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
;; Value is **geometrically bucketed** before entering the fact —
;; arc 012's rule replaces round-to-2 at this site. Bucket width is
;; `scale × noise-floor`, the atom's natural substrate-discrimination
;; resolution. Cache keys now correspond to noise-floor shells:
;; values within one bucket encode identically (true cache hit),
;; values across buckets encode distinctly (respects substrate's
;; actual discrimination capacity).
;;
;; The pre-arc-012 round-to-2 had two failure modes: over-splitting
;; for large-scale atoms (distinct cache keys for substrate-
;; equivalent values) and under-splitting for small-scale atoms
;; (one key spanning multiple distinguishable shells). Geometric
;; bucketing fixes both by deriving the quantization from the
;; atom's scale.

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
    (name :wat::core::String)
    (value :wat::core::f64)
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
     ((scale :wat::core::f64)
      (:trading::encoding::ScaleTracker::scale updated-tracker))
     ((neg-scale :wat::core::f64)
      (:wat::core::- 0.0 scale))
     ((bucketed-value :wat::core::f64)
      (:trading::encoding::ScaleTracker::bucket value scale))
     ((fact :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom name)
        (:wat::holon::Thermometer bucketed-value neg-scale scale)))
     ((updated-scales :trading::encoding::Scales)
      (:wat::core::assoc scales name updated-tracker)))
    (:wat::core::tuple fact updated-scales)))
