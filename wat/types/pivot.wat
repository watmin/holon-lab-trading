;; wat/types/pivot.wat — Phase 1.5 (2026-04-22, reordered from
;; rewrite-backlog's original 1.7).
;;
;; Port of archived/pre-wat-native/src/types/pivot.rs — Proposal
;; 049's phase-labeling types. Candle (Phase 1.6) references these
;; as field types, so pivot ships BEFORE candle in the honest
;; dependency order.
;;
;; This slice ships ONLY the three value types — PhaseLabel,
;; PhaseDirection, PhaseRecord. The `PhaseState` streaming state
;; machine and its `step` / `close_phase` / `begin_phase` logic
;; live on IndicatorBank and ship in Phase 5 with the domain
;; machinery that drives them.

;; What phase the market is in at this candle.
;; Variants PascalCase per arc 048 (host-language Rust convention).
(:wat::core::enum :trading::types::PhaseLabel :Valley :Peak :Transition)

;; Direction of movement within a phase.
(:wat::core::enum :trading::types::PhaseDirection :Up :Down :None)

;; A completed phase — appended to history when a phase closes.
;; Rust `usize` candle indices → wat `:i64`.
(:wat::core::struct :trading::types::PhaseRecord
  (label         :trading::types::PhaseLabel)
  (direction     :trading::types::PhaseDirection)
  (start-candle  :i64)
  (end-candle    :i64)
  (duration      :i64)
  (close-min     :f64)
  (close-max     :f64)
  (close-avg     :f64)
  (close-open    :f64)
  (close-final   :f64)
  (volume-avg    :f64))
