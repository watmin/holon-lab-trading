;; wat/encoding/round.wat — Phase 3.1 (2026-04-22); extended arc 011.
;;
;; Thin wrappers over arc 019's `:wat::core::f64::round` primitive
;; at the digit counts vocab actually uses:
;;
;;   round-to-2 — 2-decimal rounding. The archive's `round_to(v, 2)`
;;                default for cache-key stability across most atoms.
;;   round-to-4 — 4-decimal rounding. Used by market/timeframe for
;;                return-fraction atoms (tf-*-ret) and the
;;                alignment atom (tf-5m-1h-align).
;;
;; Both named helpers per stdlib-as-blueprint: every shipped digit
;; count has its own wrapper. If a third digit count surfaces (or
;; the pattern accumulates callers with domain-specific precision),
;; generalize to `round-to n v` and retire the specific wrappers.

(:wat::core::define
  (:trading::encoding::round-to-2
    (v :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::f64::round v 2))

(:wat::core::define
  (:trading::encoding::round-to-4
    (v :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::f64::round v 4))
