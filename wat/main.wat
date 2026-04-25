;; wat/main.wat — holon-lab-trading's entry file.
;;
;; Phase 0 scaffold (2026-04-22). Commits startup config + defines
;; `:user::main` with a hello-world body to prove the wiring end-to-end
;; (the two Rust files + Cargo + wat-rs all compose cleanly). Later
;; phases add `(:wat::load-file!)` calls for the lab's tree under
;; `:trading::*` — types, vocab, encoding, learning, domain,
;; orchestration.
;;
;; See `docs/rewrite-backlog.md` for the leaves-to-root build order.


;; Phase 0 — Rust interop (shims/parquet candle stream)
(:wat::load-file! "io/CandleStream.wat")

;; Phase 1 — types
(:wat::load-file! "types/enums.wat")
(:wat::load-file! "types/newtypes.wat")
(:wat::load-file! "types/ohlcv.wat")
(:wat::load-file! "types/distances.wat")
(:wat::load-file! "types/pivot.wat")
(:wat::load-file! "types/candle.wat")
(:wat::load-file! "types/portfolio.wat")
(:wat::load-file! "types/paper-entry.wat")

;; Phase 3 — encoding helpers
(:wat::load-file! "encoding/round.wat")
(:wat::load-file! "encoding/scale-tracker.wat")
(:wat::load-file! "encoding/scaled-linear.wat")
(:wat::load-file! "encoding/rhythm.wat")
(:wat::load-file! "encoding/atr.wat")
(:wat::load-file! "encoding/atr-window.wat")
(:wat::load-file! "encoding/phase-state.wat")

;; arc 026 — IndicatorBank port (in flight; slice-by-slice).
(:wat::load-file! "encoding/indicator-bank/primitives.wat")
(:wat::load-file! "encoding/indicator-bank/oscillators.wat")
(:wat::load-file! "encoding/indicator-bank/trend.wat")
(:wat::load-file! "encoding/indicator-bank/volatility.wat")
(:wat::load-file! "encoding/indicator-bank/volume.wat")
(:wat::load-file! "encoding/indicator-bank/rate.wat")

;; arc 025 — paper lifecycle simulator (yardstick).
(:wat::load-file! "sim/types.wat")
(:wat::load-file! "sim/labels.wat")

;; Phase 2 — vocab
;;   arc 001 — shared/time
;;   arc 002 — shared/helpers (extracted), exit/time
;;   arc 005 — market/oscillators
;;   arc 006 — market/divergence
;;   arc 007 — market/fibonacci
;;   arc 008 — market/persistence (first cross-sub-struct vocab)
;;   arc 009 — market/stochastic
;;   arc 010 — market/regime
;;   arc 011 — market/timeframe (first Ohlcv read in a vocab)
;;   arc 013 — market/momentum (K=4 sub-structs, first plain-Log caller)
;;   arc 014 — market/flow (K=3, log-bound Thermometer for missing exp)
;;   arc 015 — market/ichimoku (K=3) + substrate uplift sweep (wat-rs arc 046)
;;   arc 016 — market/keltner (K=2, third plain-Log caller)
;;   arc 017 — market/price-action (K=2, biggest Log surface, first f64::min)
;;   arc 018 — market/standard (window-based, last market vocab)
;;   arc 021 — exit/regime (thin delegation to market/regime)
;;   arc 022 — broker/portfolio (first broker vocab)
;;   arc 023 — exit/trade-atoms (PaperEntry + 13 atoms; exit sub-tree complete)
(:wat::load-file! "vocab/shared/helpers.wat")
(:wat::load-file! "vocab/shared/time.wat")
(:wat::load-file! "vocab/exit/time.wat")
(:wat::load-file! "vocab/market/oscillators.wat")
(:wat::load-file! "vocab/market/divergence.wat")
(:wat::load-file! "vocab/market/fibonacci.wat")
(:wat::load-file! "vocab/market/persistence.wat")
(:wat::load-file! "vocab/market/stochastic.wat")
(:wat::load-file! "vocab/market/regime.wat")
(:wat::load-file! "vocab/market/timeframe.wat")
(:wat::load-file! "vocab/market/momentum.wat")
(:wat::load-file! "vocab/market/flow.wat")
(:wat::load-file! "vocab/market/ichimoku.wat")
(:wat::load-file! "vocab/market/keltner.wat")
(:wat::load-file! "vocab/market/price-action.wat")
(:wat::load-file! "vocab/market/standard.wat")
(:wat::load-file! "vocab/exit/phase.wat")
(:wat::load-file! "vocab/exit/regime.wat")
(:wat::load-file! "vocab/broker/portfolio.wat")
(:wat::load-file! "vocab/exit/trade-atoms.wat")

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::io::IOWriter/println stdout "holon-lab-trading scaffold is alive"))
