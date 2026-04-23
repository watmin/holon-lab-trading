;; wat/types/newtypes.wat — Phase 1.2 (2026-04-22).
;;
;; Port of archived/pre-wat-native/src/types/newtypes.rs. Three
;; nominal wrappers — TradeId identifies a trade in treasury
;; bookkeeping; Price and Amount distinguish a price-per-unit from
;; a capital quantity.
;;
;; Rust `struct TradeId(pub usize)` → wat
;; `(:wat::core::newtype :name :i64)` (wat's integer primitive is
;; i64; TradeId is an opaque identifier so platform-independence
;; costs nothing). The Rust arithmetic impls (Price + Price,
;; Price * f64, etc.) don't translate to wat operator overloading;
;; domain-level functions (e.g., `add-prices`) will ship when
;; consumers need them.

(:wat::core::newtype :trading::types::TradeId :i64)
(:wat::core::newtype :trading::types::Price :f64)
(:wat::core::newtype :trading::types::Amount :f64)
