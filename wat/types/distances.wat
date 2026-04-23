;; wat/types/distances.wat — Phase 1.4 (2026-04-22).
;;
;; Port of archived/pre-wat-native/src/types/distances.rs. Two
;; representations of exit thresholds:
;; - Distances (percentages, scale-free — carried on proposals)
;; - Levels (absolute price levels — stored on a Trade)
;;
;; The conversion function `Distances::to_levels(price, side) ->
;; Levels` from the archive isn't ported here. It's a pure
;; utility that depends on Side matching + Price unwrap/wrap; it
;; ships with domain/simulation or treasury in Phase 5 where its
;; callers live.

(:wat::core::struct :trading::types::Distances
  (trail :f64)
  (stop  :f64))

(:wat::core::struct :trading::types::Levels
  (trail-stop  :trading::types::Price)
  (safety-stop :trading::types::Price))
