;; wat/encoding/round.wat — Phase 3.1 (2026-04-22).
;;
;; Thin wrapper over arc 019's `:wat::core::f64::round` primitive
;; fixing the digit count at 2 — the archive's `round_to(v, 2)`
;; convention for cache-key stability throughout vocab. If other
;; digit counts surface, generalize or inline the primitive call
;; at the callsite.

(:wat::core::define
  (:trading::encoding::round-to-2
    (v :f64)
    -> :f64)
  (:wat::core::f64::round v 2))
