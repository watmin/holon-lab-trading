;; wat/types/enums.wat — Phase 1.1 (2026-04-22; arc 048 PascalCase
;; migration 2026-04-24).
;;
;; Port of archived/pre-wat-native/src/types/enums.rs. Eight sum
;; types. Every other phase depends on these, so they ship first.
;;
;; Naming: PascalCase variants — embodies host-language Rust
;; convention. wat-rs arc 048 ships user-enum value support; this
;; arc renames the variants from lowercase-kebab to PascalCase as
;; the first lab consumer of constructible user enums.

;; Trading action — on Proposal and Trade.
(:wat::core::enum :trading::types::Side :Buy :Sell)

;; Price movement — used in propagation.
(:wat::core::enum :trading::types::Direction :Up :Down)

;; Accountability — used everywhere.
(:wat::core::enum :trading::types::Outcome :Grace :Violence)

;; Position lifecycle.
(:wat::core::enum :trading::types::TradePhase
  :Active
  :Runner
  :SettledViolence
  :SettledGrace)

;; What a reckoner returns. The consumer decides what "best"
;; means. Discrete carries per-label scores plus a conviction;
;; Continuous carries a value plus an experience signal.
(:wat::core::enum :trading::types::Prediction
  (Discrete
    (scores :Vec<(String,f64)>)
    (conviction :wat::core::f64))
  (Continuous
    (value :wat::core::f64)
    (experience :wat::core::f64)))

;; Scalar encoding — how continuous values get projected into
;; vectors. Log is unit (no parameters); Linear + Circular carry
;; their scale / period.
(:wat::core::enum :trading::types::ScalarEncoding
  :Log
  (Linear (scale :wat::core::f64))
  (Circular (period :wat::core::f64)))

;; Market observer lens — which vocabulary modules an observer
;; attends to. Three schools (Dow / Pring / Wyckoff), 11 lenses
;; total. Proposals 041 + 042.
(:wat::core::enum :trading::types::MarketLens
  :DowTrend
  :DowVolume
  :DowCycle
  :DowGeneralist
  :PringImpulse
  :PringConfirmation
  :PringRegime
  :PringGeneralist
  :WyckoffEffort
  :WyckoffPersistence
  :WyckoffPosition)

;; Regime observer lens — trade-state vocabulary the regime
;; observer uses. Proposal 040: two lenses based on trade atoms,
;; not market data.
(:wat::core::enum :trading::types::RegimeLens :Core :Full)
