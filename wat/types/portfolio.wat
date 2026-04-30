;; wat/types/portfolio.wat — Phase 1.8 (lab arc 022).
;;
;; Port of archived/pre-wat-native/src/vocab/broker/portfolio.rs's
;; PortfolioSnapshot struct. Five-f64 per-candle snapshot of the
;; broker's own portfolio state. Pushed onto a window per candle;
;; sampled into rhythm ASTs by `vocab/broker/portfolio.wat`.
;;
;; Type ships alongside its first caller (the broker/portfolio
;; vocab in arc 022). Future broker arcs that need PortfolioSnapshot
;; load this file directly.
;;
;; Plural typealias `:trading::types::PortfolioSnapshots` mirrors
;; arc 020's `PhaseRecords` + `Candles` precedent — the natural
;; collection name reads cleanly at every callsite.

(:wat::core::struct :trading::types::PortfolioSnapshot
  (avg-age         :wat::core::f64)
  (avg-tp          :wat::core::f64)
  (avg-unrealized  :wat::core::f64)
  (grace-rate      :wat::core::f64)
  (active-count    :wat::core::f64))

(:wat::core::typealias
  :trading::types::PortfolioSnapshots
  :Vec<trading::types::PortfolioSnapshot>)
