;; wat/types/enums.wat — Phase 1.1 (2026-04-22).
;;
;; Port of archived/pre-wat-native/src/types/enums.rs. Eight sum
;; types. Every other phase depends on these, so they ship first.
;;
;; Naming: Rust `PascalCase` variant names → lowercase-kebab wat
;; keywords for unit variants and bare symbols for tagged variants
;; (matches the substrate's existing enum-decl shape in
;; wat-rs/src/types.rs).

;; Trading action — on Proposal and Trade.
(:wat::core::enum :trading::types::Side :buy :sell)

;; Price movement — used in propagation.
(:wat::core::enum :trading::types::Direction :up :down)

;; Accountability — used everywhere.
(:wat::core::enum :trading::types::Outcome :grace :violence)

;; Position lifecycle.
(:wat::core::enum :trading::types::TradePhase
  :active
  :runner
  :settled-violence
  :settled-grace)

;; What a reckoner returns. The consumer decides what "best"
;; means. Discrete carries per-label scores plus a conviction;
;; Continuous carries a value plus an experience signal.
(:wat::core::enum :trading::types::Prediction
  (discrete
    (scores :Vec<(String,f64)>)
    (conviction :f64))
  (continuous
    (value :f64)
    (experience :f64)))

;; Scalar encoding — how continuous values get projected into
;; vectors. Log is unit (no parameters); Linear + Circular carry
;; their scale / period.
(:wat::core::enum :trading::types::ScalarEncoding
  :log
  (linear (scale :f64))
  (circular (period :f64)))

;; Market observer lens — which vocabulary modules an observer
;; attends to. Three schools (Dow / Pring / Wyckoff), 11 lenses
;; total. Proposals 041 + 042.
(:wat::core::enum :trading::types::MarketLens
  :dow-trend
  :dow-volume
  :dow-cycle
  :dow-generalist
  :pring-impulse
  :pring-confirmation
  :pring-regime
  :pring-generalist
  :wyckoff-effort
  :wyckoff-persistence
  :wyckoff-position)

;; Regime observer lens — trade-state vocabulary the regime
;; observer uses. Proposal 040: two lenses based on trade atoms,
;; not market data.
(:wat::core::enum :trading::types::RegimeLens :core :full)
