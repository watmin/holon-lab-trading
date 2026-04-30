;; wat/types/ohlcv.wat — Phase 1.3 (2026-04-22).
;;
;; Port of archived/pre-wat-native/src/types/ohlcv.rs. `Asset`
;; identifies a token (USDC, WBTC, ...). `Ohlcv` is the enterprise's
;; only raw input — one period of market data. Everything else the
;; lab consumes (Candle's enriched 90+ fields, indicator rhythms,
;; observer holons) derives from this.
;;
;; Rust field names `source_asset` → wat `source-asset` (kebab-case
;; convention). Struct declarations auto-register `<path>/new`
;; constructor + `<path>/<field>` accessors per arc 019.

(:wat::core::struct :trading::types::Asset
  (name :wat::core::String))

(:wat::core::struct :trading::types::Ohlcv
  (source-asset :trading::types::Asset)
  (target-asset :trading::types::Asset)
  (ts           :wat::core::String)
  (open         :wat::core::f64)
  (high         :wat::core::f64)
  (low          :wat::core::f64)
  (close        :wat::core::f64)
  (volume       :wat::core::f64))
