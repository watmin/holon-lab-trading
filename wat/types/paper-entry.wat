;; wat/types/paper-entry.wat — Phase 1.9 (lab arc 023).
;;
;; Port of archived/pre-wat-native/src/trades/paper_entry.rs (370L)
;; — value type only. Tick logic, constructor sugar, and is_grace?
;; / is_violence? / is_runner? helpers ship later with broker
;; mechanics in Phase 5; this file ships the 15-field struct that
;; vocab/exit/trade-atoms reads.
;;
;; Field-type deltas from archive:
;;
;; - paper-id, age, entry-candle: archive uses `usize`; wat uses
;;   `:i64` per pivot.wat's existing convention (PhaseRecord's
;;   candle indices are `:i64`).
;;
;; - composed-thought, market-thought, position-thought: archive
;;   uses `holon::kernel::vector::Vector`; wat uses
;;   `:wat::holon::HolonAST`. The substrate's L1/L2 cache makes
;;   vector materialization implicit; storing the AST is the
;;   wat-native form. Confirmed by the experiment under
;;   `docs/arc/2026/04/023-exit-trade-atoms-vocab/holon-as-field.wat`
;;   (2026-04-24): HolonAST round-trips through a struct field
;;   correctly under coincident? at d=10000.
;;
;; - entry-price, trail-level, stop-level: archive uses Price
;;   (newtype f64); wat uses `:trading::types::Price` — now
;;   constructible via wat-rs arc 049's newtype value semantics
;;   (`(:Price/new f64)` constructor + `:Price/0` accessor).
;;
;; - distances, prediction: existing already-ported types
;;   (Distances, Direction).
;;
;; - extreme, signaled, resolved, price-history: f64 / bool /
;;   Vec<f64>, no change.

(:wat::load-file! "./enums.wat")
(:wat::load-file! "./newtypes.wat")
(:wat::load-file! "./distances.wat")

(:wat::core::struct :trading::types::PaperEntry
  (paper-id          :i64)
  (composed-thought  :wat::holon::HolonAST)
  (market-thought    :wat::holon::HolonAST)
  (position-thought  :wat::holon::HolonAST)
  (prediction        :trading::types::Direction)
  (entry-price       :trading::types::Price)
  (distances         :trading::types::Distances)
  (extreme           :f64)
  (trail-level       :trading::types::Price)
  (stop-level        :trading::types::Price)
  (signaled          :bool)
  (resolved          :bool)
  (age               :i64)
  (entry-candle      :i64)
  (price-history     :Vec<f64>))
