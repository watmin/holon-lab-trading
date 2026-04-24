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

(:wat::config::set-dims! 10000)
(:wat::config::set-capacity-mode! :error)

;; Phase 1 — types
(:wat::load-file! "types/enums.wat")
(:wat::load-file! "types/newtypes.wat")
(:wat::load-file! "types/ohlcv.wat")
(:wat::load-file! "types/distances.wat")
(:wat::load-file! "types/pivot.wat")
(:wat::load-file! "types/candle.wat")

;; Phase 3 — encoding helpers
(:wat::load-file! "encoding/round.wat")
(:wat::load-file! "encoding/scale-tracker.wat")
(:wat::load-file! "encoding/scaled-linear.wat")
(:wat::load-file! "encoding/rhythm.wat")

;; Phase 2 — vocab
;;   arc 001 — shared/time
;;   arc 002 — shared/helpers (extracted), exit/time
;;   arc 005 — market/oscillators
;;   arc 006 — market/divergence
;;   arc 007 — market/fibonacci
;;   arc 008 — market/persistence (first cross-sub-struct vocab)
(:wat::load-file! "vocab/shared/helpers.wat")
(:wat::load-file! "vocab/shared/time.wat")
(:wat::load-file! "vocab/exit/time.wat")
(:wat::load-file! "vocab/market/oscillators.wat")
(:wat::load-file! "vocab/market/divergence.wat")
(:wat::load-file! "vocab/market/fibonacci.wat")
(:wat::load-file! "vocab/market/persistence.wat")

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::io::IOWriter/println stdout "holon-lab-trading scaffold is alive"))
