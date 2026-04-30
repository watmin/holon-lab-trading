;; wat/vocab/shared/helpers.wat — shared vocab helpers.
;;
;; File-public helpers reusable across every vocab module. Extracted
;; from wat/vocab/shared/time.wat during lab arc 002 when the second
;; caller (exit/time.wat) surfaced the same pattern — fulfilling the
;; deferred "extract when a second caller appears" note from lab arc
;; 001's INSCRIPTION.
;;
;; Namespace: `:trading::vocab::shared::*` (one segment above time),
;; reachable from every vocab sub-tree that loads this file. Cross-
;; subtree `(load!)` is legal per arc 027 slice 3's widened loader
;; scope.

(:wat::load-file! "../../types/candle.wat")

;; ─── circ — integer-quantized circular encoding ────────────────────
;;
;; Round the value to the nearest integer, then Circular-encode it
;; against the component's period. Used by every vocab module that
;; emits circular holons (time, exit-time, any future calendar
;; vocabulary).
;;
;; Rounding rationale: per proposal 057's RESOLUTION, round_to at
;; emission is cache-key quantization, not signal precision. Per
;; 033: quantization tightens the cache without narrowing the
;; algebra's view.
(:wat::core::define
  (:trading::vocab::shared::circ
    (value :wat::core::f64)
    (period :wat::core::f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Circular
    (:wat::core::f64::round value 0)
    period))

;; ─── named-bind — Bind(Atom(name), child) pair ─────────────────────
;;
;; Readability helper — emission sites read cleaner than inline
;; Bind + Atom pairs. Single emission path for name-tagged holons
;; across every vocab module.
(:wat::core::define
  (:trading::vocab::shared::named-bind
    (name :wat::core::String)
    (child :wat::holon::HolonAST)
    -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom name)
    child))

;; ─── basic numeric ops live in the substrate ───────────────────────
;;
;; `f64::max`, `f64::min`, `f64::abs`, `f64::clamp`, and `math::exp`
;; ship at `:wat::core::*` and `:wat::std::math::*` per wat-rs
;; arc 046. Lab arc 015 surfaced the gap (it was about to ship
;; `clamp` and `f64-max` here as userland helpers); the framing
;; question caught the reach. Use the substrate forms directly at
;; the callsite rather than wrapping them in lab-userland.
