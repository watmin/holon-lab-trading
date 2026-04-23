;; wat/encoding/scaled_linear.wat — Phase 3.3 (2026-04-22).
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

(:wat::core::define
  (:trading::encoding::scaled-linear
    (name :String)
    (value :f64)
    (scales :HashMap<String,trading::encoding::ScaleTracker>)
    -> :(wat::holon::HolonAST,HashMap<String,trading::encoding::ScaleTracker>))
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
     ((updated-scales :HashMap<String,trading::encoding::ScaleTracker>)
      (:wat::core::assoc scales name updated-tracker)))
    (:wat::core::tuple fact updated-scales)))
